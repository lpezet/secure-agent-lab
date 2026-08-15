"""Block forwarding of requests to internal service hostnames.

The proxy sits on both the `secure` and `lab` networks, so it can reach
the broker. Without this addon, code inside the lab container could issue
plain HTTP proxy requests (e.g. curl --proxy http://proxy:8080 http://broker:8080/...)
and the proxy would happily forward them. This addon intercepts and rejects
any such request before it is forwarded.

**This file is baked into the proxy image** at /opt/agent-proxy/addons/, and
entrypoint.sh loads it ahead of anything the deployment mounts at /addons. A
control the deployment does not get to choose belongs in the image — the same
reason cred-gateway bakes its nginx.conf instead of mounting it. A deployment
that still vendors a copy gets a warning at startup and the baked copy wins.

Note: this matches by hostname, not IP. Docker network isolation is the
primary control that prevents lab from routing to broker's IP directly —
broker is on `secure` only, which lab has no membership in. On the path this
addon covers, though — a request *through* the proxy, which sits on both
networks — there is no second barrier behind it.
TODO: consider flipping to default-deny (allowlist of known-good external
hosts) as a hardening pass once the set of required destinations is known.
"""
import os

from mitmproxy import http, ctx

import audit

_DEFAULT_INTERNAL_HOSTS = "broker,cred-gateway"


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


def _configured_hosts() -> set:
    """Which hostnames count as internal.

    Deployment configuration on the proxy service, read once at startup from
    POLICY_INTERNAL_HOSTS (comma-separated) so a stack that renames its
    services can still name them. Never request data: nothing the lab container
    sends can widen or narrow this set. That is the same rule that took
    X-Cf-Profile out of 030_cloudflare.py — which credential, or which control,
    applies is the deployment's choice and not the caller's.

    Normalised on the way in, so a deployment writing "Broker" or "broker."
    gets the host it meant rather than an entry that matches nothing.
    """
    raw = os.environ.get("POLICY_INTERNAL_HOSTS") or _DEFAULT_INTERNAL_HOSTS
    return {n for n in (_norm(h) for h in raw.split(",")) if n}


_INTERNAL_HOSTS = _configured_hosts()


def running() -> None:
    # A security control that silently blocks nothing is worth saying out loud
    # once, so a misconfigured POLICY_INTERNAL_HOSTS is visible in the log
    # rather than only in what fails to be blocked.
    if _INTERNAL_HOSTS:
        ctx.log.info(
            "policy: blocking internal host(s): " + ", ".join(sorted(_INTERNAL_HOSTS))
        )
    else:
        ctx.log.warn(
            "policy: NO internal hosts configured — this addon will block nothing"
        )


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
