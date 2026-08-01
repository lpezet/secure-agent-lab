"""Inject GitHub App installation token for api.github.com calls.

IMPORTANT: We intentionally do NOT match github.com (only api.github.com
and uploads.github.com). Git push/pull to github.com uses the credential
helper path via cred-gateway — injecting auth here would conflict with
git's HTTP Basic auth handshake inside the MITMed tunnel.
"""
import requests
from mitmproxy import http, ctx
from cachetools import TTLCache

import audit

_cache = TTLCache(maxsize=1, ttl=300)
BROKER_URL = "http://broker:8080"


def _get_token():
    if "token" not in _cache:
        r = requests.get(f"{BROKER_URL}/github/token", timeout=5)
        r.raise_for_status()
        _cache["token"] = r.json()["token"]
    return _cache["token"]


def request(flow: http.HTTPFlow) -> None:
    # flow.request.host is the real destination. Do NOT use pretty_host here:
    # it prefers the client-supplied Host header, so the lab container could
    # point a request at its own server, spoof the header, and have the real
    # credential injected into a request that never goes to the vendor.
    host = flow.request.host
    if host not in ("api.github.com", "uploads.github.com"):
        return

    # Strip first, as its own statement. _get_token() raises when the broker is
    # unreachable, so a single assignment that both strips and injects strips
    # nothing on failure and forwards the agent's own Authorization header to
    # GitHub untouched — the opposite of what the strip is for. Ordering is the
    # whole fix: the strip is unconditional, and a failed fetch now sends no
    # auth at all rather than the client's.
    if "Authorization" in flow.request.headers:
        del flow.request.headers["Authorization"]

    # Inject the brokered token, replacing the GH_TOKEN=proxy-injected dummy.
    flow.request.headers["Authorization"] = f"token {_get_token()}"
    flow.request.headers["Accept"] = flow.request.headers.get(
        "Accept", "application/vnd.github+json"
    )

    ctx.log.info(f"github: {flow.request.method} {host}{flow.request.path}")
    audit.log_event("token_injected", provider="github", host=host, method=flow.request.method)


def response(flow: http.HTTPFlow) -> None:
    if flow.request.host not in ("api.github.com", "uploads.github.com"):
        return
    if flow.response.status_code == 401:
        _cache.clear()
        ctx.log.warn("github: 401 received, cleared token cache")
        audit.log_event("cache_cleared", provider="github", reason="401")
