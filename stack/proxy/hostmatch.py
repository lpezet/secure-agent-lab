"""Host matching for proxy addons.

Baked into the image at /opt/agent-proxy and put on PYTHONPATH (see
Dockerfile), so any addon in the bind-mounted /addons directory can
`import hostmatch` regardless of which addon file it lives next to — the same
mechanism as audit.py.

    import hostmatch

    if not hostmatch.matches(flow.request.host, ["api.example.com",
                                                 "*.example.com"]):
        return

Takes a **host string, never a flow**. The caller must have obtained it from
`flow.request.host` — this module cannot tell where a string came from, so it
cannot stop an addon handing it `pretty_host` and reintroducing the spoofing
bug. `inv_pretty_host` in scripts/lib/invariants.sh stays the control for that.

Why this is shared rather than reimplemented per addon: 001_allowlist.py had
the correct algorithm and kept it private, so the next addon needing suffix
matching had to write its own. Host matching reimplemented per addon is
precisely how `pretty_host` ended up in three files at once and stayed there.

Matching rules
--------------
  api.example.com     exact, after normalisation
  *.example.com       label-boundary suffix only:
                        a.example.com     yes
                        a.b.example.com   yes
                        example.com       no  — the apex is not a subdomain
                        evilexample.com   no  — the leading dot is preserved

Normalisation lowercases, drops a trailing root dot (`example.com.`), and
drops a `:port` suffix. Both the host and the patterns go through it, so a
pattern written `*.Example.COM` behaves the same as `*.example.com`.

An uninterpretable pattern is **skipped, not raised on**. A bad line in a
deployment's allowlist must not be able to take the proxy down, and skipping
fails closed: a pattern that matches nothing denies rather than permits. Use
`invalid()` to report them at load time instead of discovering them as silence.

The rule this module does NOT enforce
-------------------------------------
A wildcard is safe for credential injection only when the **entire suffix is
single-tenant** — one party holds every name under it.

    *.googleapis.com    fine. Google holds every name beneath it.
    *.workers.dev       not fine. Anyone can register one, so injecting a
                        credential for that suffix hands it to whoever did.

That is a judgment about who owns a namespace, and this module has no way to
know. `matches()` is deliberately mechanical: it will happily match
`*.workers.dev` because refusing it here would only push an author toward
writing their own matcher again — the exact failure this module exists to
end. The rule is enforced where it can be, statically, by
`inv_injection_wildcard*` in scripts/lib/invariants.sh, and stated in
PLAYBOOK.md for the addon author.
"""
from typing import Iterable, List, Optional

__all__ = ["normalize", "find", "matches", "invalid"]


def normalize(host: str) -> str:
    """Lowercase, strip a :port suffix, strip a trailing root dot.

    Returns "" for anything unusable, which never matches anything.
    """
    h = (host or "").strip().lower()
    if not h:
        return ""
    if h.startswith("["):
        # Bracketed IPv6, with or without a port: [::1] / [::1]:8080
        end = h.find("]")
        if end == -1:
            return ""
        h = h[1:end]
    elif h.count(":") == 1:
        # One colon is host:port. A bare IPv6 literal has several, and
        # splitting it would silently truncate the address to "".
        h = h.split(":", 1)[0]
    # A fully-qualified name may carry the root dot; "example.com." and
    # "example.com" are the same host and must match the same pattern.
    return h.rstrip(".")


def _suffix(pattern: str) -> Optional[str]:
    """".example.com" for a valid "*.example.com", else None.

    None means "not a usable wildcard" and the caller skips the pattern. The
    leading dot is kept deliberately: it is what stops `*.example.com` from
    matching `evilexample.com`.
    """
    if not pattern.startswith("*."):
        return None
    suffix = pattern[1:]          # "*.example.com" -> ".example.com"
    if len(suffix) < 2:           # bare "*." names nothing
        return None
    if "*" in suffix:             # "*.*.com" and friends are not supported
        return None
    return suffix


def _usable(pattern: str) -> bool:
    if not pattern or any(c.isspace() for c in pattern):
        return False
    if "*" not in pattern:
        return True               # exact
    return _suffix(pattern) is not None


def find(host: str, patterns: Iterable[str]) -> Optional[str]:
    """The pattern matching `host`, in its original spelling, or None.

    Returns the pattern rather than a bool so a caller can look up whatever it
    stored against it — 001_allowlist.py keeps a permitted-method set per
    entry, and needs to know *which* entry matched, not merely that one did.

    Exact beats wildcard, and a longer wildcard suffix beats a shorter one, so
    `*.a.example.com` wins over `*.example.com` for `x.a.example.com`
    regardless of the order the patterns arrive in. Ordering a security
    decision by however a config file happened to be written is a bug waiting
    for someone to reorder their lines.
    """
    h = normalize(host)
    if not h:
        return None

    best: Optional[str] = None
    best_len = -1
    for pattern in patterns:
        p = normalize(pattern)
        if not _usable(p):
            continue
        suffix = _suffix(p)
        if suffix is None:
            if h == p:
                return pattern    # exact wins outright
            continue
        # endswith alone would let the apex through when h == suffix[1:], and
        # the length test is what keeps ".example.com" itself from matching.
        if h.endswith(suffix) and len(h) > len(suffix) and len(suffix) > best_len:
            best, best_len = pattern, len(suffix)
    return best


def matches(host: str, patterns: Iterable[str]) -> bool:
    """Whether `host` matches any pattern. The common case."""
    return find(host, patterns) is not None


def invalid(patterns: Iterable[str]) -> List[str]:
    """The patterns `find()` will skip, so a caller can say so at load time.

    A skipped pattern denies rather than permits, so this is a usability
    problem rather than a security one — but silent denial is how a typo turns
    into an afternoon of debugging.
    """
    return [p for p in patterns if not _usable(normalize(p))]
