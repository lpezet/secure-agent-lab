"""Inject a static key for one provider's hosts, and log what was called.

TODO: replace every `acme` in this directory — including the filenames — with
your provider's name, then work through the TODOs. The installer assigns the
NNN_ prefix when it lands in a deployment; do not add one here.

The static-key shape: the broker holds a long-lived secret, this attaches it to
requests leaving the lab, and the lab never holds it. If your provider can mint
something short-lived and scoped instead, prefer that — CONCEPT.md's exposure
rule is about exactly this difference.
"""
import requests
from cachetools import TTLCache
from mitmproxy import ctx, http

import audit
import hostmatch

BROKER_URL = "http://broker:8080"

# TODO: the hosts this provider authenticates to. They must agree EXACTLY with
# `hosts` in provider.json, both directions: a host declared there and not
# matched here means the credential is silently never injected, and a host
# matched here but not declared there is an injection the egress allowlist was
# never seeded for.
HOSTS = ("api.acme.invalid",)

_cache = TTLCache(maxsize=1, ttl=300)


def _get_cred() -> str:
    """Return the credential from the broker, cached for five minutes."""
    if "cred" not in _cache:
        r = requests.get(f"{BROKER_URL}/acme/cred", timeout=5)
        r.raise_for_status()
        _cache["cred"] = r.json()["value"]
    return _cache["cred"]


def _endpoint(flow: http.HTTPFlow) -> str:
    """A loggable identifier for what was called, never the raw path.

    The query string is split off FIRST and only the leading path segments are
    kept. Both halves matter: flow.request.path includes the query, so an
    ?access_token= would land in the audit trail that observer serves over
    HTTP — and keeping two segments bounds the cardinality.

    TODO: if your provider carries its credential IN the path — Telegram's
    /bot<TOKEN>/<method> is the example that has actually shipped — drop the
    segments that hold it. Which slice is safe is provider-specific, which is
    why there is no shared helper for it.
    """
    parts = [p for p in flow.request.path.split("?", 1)[0].split("/") if p][:2]
    return "/" + "/".join(parts)


def request(flow: http.HTTPFlow) -> None:
    # Do not act on a request an earlier addon has already refused. mitmproxy
    # calls every addon's request hook regardless, so without this an addon
    # after a denial still runs: overwriting the refusal message, or — worse —
    # fetching a credential from the broker and logging cred_injected for a
    # request that never leaves. Deliberately dependency-free, because
    # deployments vendor this file at pins that may predate any shared helper.
    if flow.response is not None:
        return

    # flow.request.host is the real destination. Do NOT use pretty_host: it
    # prefers the client-supplied Host header, so the lab container could point
    # a request at its own server, spoof the header, and have the real
    # credential injected into a request that never goes to the vendor.
    #
    # hostmatch normalises case, a trailing root dot and a :port before
    # comparing. A plain `==` against a lowercase name is what let
    # http://BROKER:8080/… through the internal-host block until 1.9.2.
    if not hostmatch.matches(flow.request.host, HOSTS):
        return

    # Stripped BEFORE the credential is fetched, not after. _get_cred() raises
    # when the broker is unreachable, so fetching first means the strip never
    # runs and the agent's own header goes to the vendor untouched — the
    # opposite of what the strip is for.
    #
    # TODO: name every header your provider authenticates with.
    for header in ("Authorization", "X-Api-Key"):
        if header in flow.request.headers:
            del flow.request.headers[header]

    # TODO: attach it the way this provider expects.
    flow.request.headers["Authorization"] = f"Bearer {_get_cred()}"

    ctx.log.info(f"acme: injected credential for {flow.request.method} {_endpoint(flow)}")
    audit.log_event(
        "cred_injected",
        provider="acme",
        method=flow.request.method,
        endpoint=_endpoint(flow),
    )
