"""Inject Anthropic credentials (API key or OAuth token), enforce policy, log usage."""
import requests
from mitmproxy import http, ctx
from cachetools import TTLCache

import audit

_cache = TTLCache(maxsize=1, ttl=300)
BROKER_URL = "http://broker:8080"


def _get_cred():
    """Return (type, value) from broker, cached for 5 minutes."""
    if "cred" not in _cache:
        r = requests.get(f"{BROKER_URL}/anthropic/cred", timeout=5)
        r.raise_for_status()
        data = r.json()
        _cache["cred"] = (data["type"], data["value"])
    return _cache["cred"]


def _endpoint(flow: http.HTTPFlow) -> str:
    """A loggable identifier for what was called, never the raw path.

    Two reasons this is parsed rather than passed straight through:
    flow.request.path includes the query string, and this file is one of the
    ones people copy when writing their own addon. A provider that carries its
    credential in the URL — Telegram's /bot<TOKEN>/<method>, or an
    ?access_token= on the query — turns `path=flow.request.path` into a live
    secret written to the audit trail, which observer then serves over HTTP.

    Anthropic authenticates by header, so its path holds no secret; keeping the
    first two segments also bounds the cardinality (/v1/messages rather than
    /v1/messages/batches/<id>). If you adapt this for a provider whose
    credential IS in the path, drop the segments that carry it — the safe
    slice is provider-specific, which is why there is no shared helper for it.
    """
    parts = [p for p in flow.request.path.split("?", 1)[0].split("/") if p][:2]
    return "/" + "/".join(parts)


def request(flow: http.HTTPFlow) -> None:
    # flow.request.host is the real destination. Do NOT use pretty_host here:
    # it prefers the client-supplied Host header, so the lab container could
    # point a request at its own server, spoof the header, and have the real
    # credential injected into a request that never goes to the vendor.
    if flow.request.host != "api.anthropic.com":
        return

    # Policy: block Admin API from agent context
    if flow.request.path.startswith("/v1/organizations"):
        flow.response = http.Response.make(
            403,
            b'{"error":"Admin API blocked by proxy policy"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.warn(f"anthropic: BLOCKED {flow.request.method} {_endpoint(flow)}")
        audit.log_event("blocked", provider="anthropic", reason="admin_api",
                        endpoint=_endpoint(flow))
        return

    # Strip before fetching, not after. _get_cred() raises when the broker is
    # unreachable, so fetching first means the strip never runs and the agent's
    # own x-api-key or Authorization goes to Anthropic untouched — the opposite
    # of what the strip is for.
    for h in ("x-api-key", "Authorization"):
        if h in flow.request.headers:
            del flow.request.headers[h]

    cred_type, cred_value = _get_cred()

    if cred_type == "auth_token":
        flow.request.headers["Authorization"] = f"Bearer {cred_value}"
        ctx.log.info(f"anthropic: injected auth token for {flow.request.method} {_endpoint(flow)}")
    else:
        flow.request.headers["x-api-key"] = cred_value
        flow.request.headers["anthropic-version"] = flow.request.headers.get(
            "anthropic-version", "2023-06-01"
        )
        ctx.log.info(f"anthropic: injected api key for {flow.request.method} {_endpoint(flow)}")

    audit.log_event(
        "cred_injected", provider="anthropic", cred_type=cred_type,
        method=flow.request.method, endpoint=_endpoint(flow),
    )


def responseheaders(flow: http.HTTPFlow) -> None:
    """Use responseheaders, not response, to avoid buffering streamed bodies."""
    if flow.request.host != "api.anthropic.com":
        return
    if "text/event-stream" in flow.response.headers.get("Content-Type", ""):
        flow.response.stream = True

    remaining = flow.response.headers.get("anthropic-ratelimit-tokens-remaining")
    if remaining:
        ctx.log.info(f"anthropic: tokens remaining = {remaining}")
