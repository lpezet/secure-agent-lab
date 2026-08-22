"""Domain allowlist for proxy egress control.

Reads /etc/agent-allowlist (bind-mounted from the host) to restrict which
external destinations the proxy will forward to. One entry per line; lines
starting with # and blank lines are ignored.

Entry format:
  domain [METHODS]

  domain       Exact hostname, or a wildcard. Matching is hostmatch.find():
               *.example.com covers a.example.com and a.b.example.com, but not
               example.com itself and not evilexample.com. An entry that is
               neither — `*`, `a.*.com` — is ignored with a warning at startup.
  METHODS      Optional comma-separated HTTP methods to permit for this domain.
               Omitting METHODS defaults to GET,HEAD,OPTIONS (safe reads only).
               Use * to explicitly allow all methods.

Examples:
  api.example.com                   # GET, HEAD, OPTIONS only (default)
  api.example.com GET,POST          # GET and POST only
  upload.example.com PUT,POST       # write-only endpoint
  *.cdn.example.com *               # all methods for any subdomain

CONNECT is always permitted for allowlisted domains — it is the mechanism HTTPS
uses to establish the tunnel; the actual method is checked on the inner request.

If the file is absent or unreadable, all destinations are permitted and a
warning is logged at startup. After editing the file, restart the proxy to
pick up changes: docker compose up -d --force-recreate proxy

Internal host blocking (broker, cred-gateway) is handled by policy.py, which
runs before this addon.

Both outcomes are written to the audit trail — `allowed` and `blocked`, each
carrying the host and the method and nothing else. Recording only denials
would leave a deployment able to say what its agent was stopped from doing and
never what it did, which is the half that says the deployment is working. See
_log_allowed for why the path is not among the fields, and why CONNECT is not
among the events.
"""
import os
from typing import Dict, Optional, Set

from mitmproxy import ctx, http

import audit
import hostmatch

_ALLOWLIST_PATH = "/etc/agent-allowlist"
_DEFAULT_METHODS = {"GET", "HEAD", "OPTIONS"}

# None means permissive mode (no file found).
# When active, maps entry → allowed methods (None = all methods). Exact and
# wildcard entries live in one dict because hostmatch.find() tells them apart
# and hands back the entry that matched, which is the key to this dict.
_entries: Optional[Dict[str, Optional[Set[str]]]] = None


def _parse_methods(token: str) -> Optional[Set[str]]:
    """Return None for '*' (all methods), otherwise a set of uppercase method names."""
    if token == "*":
        return None
    return {m.strip().upper() for m in token.split(",") if m.strip()}


def _load() -> None:
    global _entries
    if not os.path.isfile(_ALLOWLIST_PATH):
        ctx.log.warn(
            f"allowlist: {_ALLOWLIST_PATH} not found or is not a file — "
            "all destinations permitted (permissive mode)"
        )
        _entries = None
        return
    entries: Dict[str, Optional[Set[str]]] = {}
    with open(_ALLOWLIST_PATH) as fh:
        for line in fh:
            # Strip trailing comments before parsing. Without this,
            # `api.example.com  # read only` parses "# read only" as the method
            # list and silently blocks every method on that domain — fail-closed
            # but baffling to debug.
            line = line.split("#", 1)[0].strip() if not line.lstrip().startswith("#") else ""
            if not line:
                continue
            parts = line.lower().split(None, 1)
            domain = parts[0]
            methods = _parse_methods(parts[1]) if len(parts) > 1 else set(_DEFAULT_METHODS)
            entries[domain] = methods

    # An entry hostmatch cannot interpret — `*`, `*.`, `a.*.com` — matches
    # nothing, which denies rather than permits. Safe, but silence is a poor
    # way to learn about a typo, so say which lines are inert.
    skipped = hostmatch.invalid(entries)
    for bad in skipped:
        ctx.log.warn(f"allowlist: ignoring uninterpretable entry {bad!r} — it will match nothing")
    ignored = f" ({len(skipped)} ignored)" if skipped else ""
    ctx.log.info(f"allowlist: loaded {len(entries) - len(skipped)} entries{ignored}")
    _entries = entries


def _is_allowed(host: str, method: str) -> bool:
    # One matcher, shared with every credential-injecting addon, rather than a
    # second implementation of suffix matching living privately in this file.
    # hostmatch.find returns the entry that matched so the per-entry method set
    # below can be looked up; matches() would only say that something did.
    entry = hostmatch.find(host, _entries)
    if entry is None:
        return False
    # CONNECT establishes the HTTPS tunnel; the real method is on the inner request.
    if method == "CONNECT":
        return True
    methods = _entries[entry]
    return methods is None or method.upper() in methods


def _log_allowed(host: str, method: str, reason: str) -> None:
    """Record a request the proxy forwarded — host and method only, never the path.

    THE PATH IS THE WHOLE SAFETY QUESTION, and the answer is no. This addon is
    in the base image and sees hosts it knows nothing about, so it cannot
    compute a safe slice of a path the way a provider's addon can: a vendor
    that carries its credential in the URL (Telegram's /bot<TOKEN>/<method>, an
    ?access_token= on the query) would have that credential written into the
    trail, which observer then serves over HTTP with no auth. The safe slice is
    provider-specific, which is why bank/anthropic/proxy/anthropic.py computes
    its own and why there is no shared helper to reach for here.

    Dropping the path costs less than it sounds. `host` and `method` are the
    two fields `blocked` already carries, so this adds no field that was not
    already being written — the same shape, for the other outcome. Path-level
    detail already exists where it is safe to have it, as a provider addon's
    `cred_injected endpoint=/v1/messages`. What had no record at all until now
    is permitted traffic that carries no credential, which is precisely the
    traffic no provider addon ever sees.

    CONNECT is skipped. Every HTTPS request arrives here twice — the CONNECT
    that opens the tunnel, then the inner request — so logging it would double
    the trail's volume to say `method=CONNECT`, which is never the agent's
    intent and is not what any allowlist entry is written against. The inner
    request is the event. A CONNECT permitted whose inner request is then
    denied still appears, as the `blocked` line: skipping applies to this
    function only, never to a denial.
    """
    if method == "CONNECT":
        return
    audit.log_event("allowed", reason=reason, host=host, method=method)


def running() -> None:
    _load()


def request(flow: http.HTTPFlow) -> None:
    # Do not act on a request an earlier addon has already refused. mitmproxy
    # calls every addon's request hook regardless, so without this an addon
    # after a denial still runs: overwriting the refusal message, or — worse —
    # fetching a credential from the broker and logging cred_injected for a
    # request that never leaves. Deliberately dependency-free, because
    # deployments vendor this file at pins that may predate any shared helper.
    if flow.response is not None:
        return

    # flow.request.host is the real destination. Do NOT use pretty_host here:
    # it prefers the client-supplied Host header, so the lab container could
    # point a request at its own server, spoof the header, and have the real
    # credential injected into a request that never goes to the vendor.
    #
    # hostmatch takes a host string and cannot tell where it came from, so
    # passing pretty_host would reintroduce that bug through a helper that
    # looks like it is handling the problem. It is not; this line is.
    host = flow.request.host.lower()
    method = flow.request.method

    # Permissive mode — no allowlist file, so every destination is forwarded.
    # Logged rather than silently skipped: patched the other way round, the
    # deployment with NO egress policy would be the one with the emptiest
    # trail, which inverts what a trail is for. `reason` is what separates
    # permitted-by-a-rule from permitted-because-nothing-is-enforcing, and a
    # reader who cannot tell those apart has not learned anything from the line.
    if _entries is None:
        _log_allowed(host, method, "permissive")
        return

    if not _is_allowed(host, method):
        flow.response = http.Response.make(
            403,
            b'{"error":"destination blocked by allowlist policy"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.warn(f"allowlist: BLOCKED {method} {host}")
        audit.log_event("blocked", reason="allowlist", host=host, method=method)
        return

    _log_allowed(host, method, "allowlist")
