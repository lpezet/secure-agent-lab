"""Block forwarding of requests to internal service hostnames.

The proxy sits on both the `secure` and `lab` networks, so it can reach
the broker. Without this addon, code inside the lab container could issue
plain HTTP proxy requests (e.g. curl --proxy http://proxy:8080 http://broker:8080/...)
and the proxy would happily forward them. This addon intercepts and rejects
any such request before it is forwarded.

Note: this matches by hostname, not IP. Docker network isolation is the
primary control that prevents lab from routing to broker's IP directly —
broker is on `secure` only, which lab has no membership in. This addon is
a defence-in-depth layer, not the sole barrier.
TODO: consider flipping to default-deny (allowlist of known-good external
hosts) as a hardening pass once the set of required destinations is known.
"""
from mitmproxy import http, ctx

import audit

_INTERNAL_HOSTS = {"broker", "cred-gateway"}


def _norm(host: str) -> str:
    """Lowercase, strip a :port suffix, strip a trailing root dot.

    DNS is case-insensitive and treats a trailing root dot as the same name, so
    comparing a raw host against a lowercase set made

        curl --proxy http://proxy:8080 http://BROKER:8080/github/token

    a complete bypass of this block — 200, with the broker's response body. One
    shifted letter, reaching the same container.

    Deliberately dependency-free rather than reusing the shared hostmatch
    module, whose normalize() this mirrors. Deployments vendor this file, and a
    deployment's image may be built from a tag older than the 1.7.0 that added
    that module — an addon importing something its image does not carry fails
    to load, taking every destination down with it rather than just this check.
    """
    h = (host or "").strip().lower()
    if h.startswith("["):
        # Bracketed IPv6, with or without a port: [::1] / [::1]:8080
        end = h.find("]")
        h = h[1:end] if end != -1 else ""
    elif h.count(":") == 1:
        # One colon is host:port. A bare IPv6 literal has several, and
        # splitting it would silently truncate the address.
        h = h.split(":", 1)[0]
    return h.rstrip(".")


def _destination(flow: http.HTTPFlow) -> str:
    """Host this request will actually be sent to.

    NEVER use flow.request.pretty_host for a security decision. It prefers the
    client-supplied Host header, which the lab container fully controls, while
    mitmproxy connects to flow.request.host (from the absolute-form URI, the
    CONNECT authority, or the TLS SNI). Matching on pretty_host let

        curl --proxy http://proxy:8080 -H 'Host: example.com' \
             http://broker:8080/github/token

    sail past this addon and return a real installation token.
    """
    return flow.request.host


def request(flow: http.HTTPFlow) -> None:
    # Checked against both the real destination and the claimed one: the first
    # is the bypass above, the second stops a request being *labelled* internal
    # from reaching anything. Either match denies — fail closed.
    host = _destination(flow)
    if _norm(host) in _INTERNAL_HOSTS or _norm(flow.request.pretty_host) in _INTERNAL_HOSTS:
        flow.response = http.Response.make(
            403,
            b'{"error":"internal host blocked by proxy policy"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.warn(
            f"policy: BLOCKED request to internal host {host} "
            f"(Host header: {flow.request.pretty_host})"
        )
        audit.log_event("blocked", reason="internal_host", host=host)
