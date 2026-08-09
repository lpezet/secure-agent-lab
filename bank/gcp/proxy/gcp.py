"""Inject a short-lived GCP access token for *.googleapis.com calls.

Two behaviours, and the split between them is the whole design.

**Token endpoints are answered with an inert value.** A Google client library
will not call an API until its credential chain has produced a token, and with
the lab's inert ADC file that chain ends in a POST to sts.googleapis.com. This
addon answers that POST itself, with `proxy-injected` — the same dummy the lab
already hands `gcloud` in CLOUDSDK_AUTH_ACCESS_TOKEN and `gh` in GH_TOKEN. The
client is satisfied, and holds nothing.

**API calls get the real token, attached in flight.** The client sends its
inert bearer, this addon strips it and injects a token minted by the broker for
the impersonated service account.

Answering the exchange with the *real* token would work too, and is simpler.
The inert value is preferred only because it keeps the credential off the
proxied path entirely: an injected token exists solely on requests already
bound for googleapis.com, while a token the client holds can go anywhere
egress permits. A modest difference, and free here.

**It is not a claim that the lab cannot obtain a token.** `/gcp/token` IS
exposed through cred-gateway, for tooling this addon cannot mediate — the same
bargain as /github/credential. The authority that route hands over is exactly
the impersonated service account's IAM roles, which is the deployment's choice
to make narrow. Do not read the inert value here as an isolation guarantee; it
is a smaller blast radius on one path, not a property of the whole design.
"""
import os

import requests
from mitmproxy import http, ctx
from cachetools import TTLCache

import audit
import hostmatch

_cache = TTLCache(maxsize=4, ttl=300)
BROKER_URL = "http://broker:8080"

# Which service account this deployment issues for. Read once at load from the
# proxy's own environment: deployment configuration, never request data.
SERVICE_ACCOUNT = os.environ.get("GCP_SERVICE_ACCOUNT", "")

# The whole API surface is a family, not a fixed pair — storage., compute.,
# bigquery., run., pubsub. and so on. The wildcard is legitimate here because
# the entire suffix is single-tenant: Google holds every name beneath
# googleapis.com. That is the test #39's rule states, and the reason
# *.workers.dev would not qualify.
API_HOSTS = ["*.googleapis.com"]

# Where a client goes to turn a credential into a token. Answered locally, so
# no exchange ever reaches Google and no real token is ever minted for these.
TOKEN_HOSTS = ["sts.googleapis.com", "oauth2.googleapis.com"]
# Exact paths, never a prefix. `/tokeninfo` starts with `/token` and is an
# ordinary API that reports what a token is — answering it with the inert
# placeholder would make it describe the wrong credential, and quietly.
TOKEN_PATHS = ("/v1/token", "/token", "/v1/introspect")

INERT_TOKEN = "proxy-injected"


def _get_token() -> str:
    if "token" not in _cache:
        params = {"service_account": SERVICE_ACCOUNT} if SERVICE_ACCOUNT else {}
        r = requests.get(f"{BROKER_URL}/gcp/token", params=params, timeout=10)
        r.raise_for_status()
        _cache["token"] = r.json()["token"]
    return _cache["token"]


def _endpoint(flow: http.HTTPFlow) -> str:
    """A loggable identifier for what was called, never the raw path.

    flow.request.path carries the query string, and Google API paths carry
    project and bucket ids. Keeping the first three segments names the API
    surface without writing ids — or, for a provider that puts a credential in
    the URL, a live secret — into a trail observer serves over HTTP.
    """
    parts = [p for p in flow.request.path.split("?", 1)[0].split("/") if p][:3]
    return "/" + "/".join(parts)


def request(flow: http.HTTPFlow) -> None:
    # flow.request.host is the real destination. Do NOT use pretty_host: it
    # prefers the client-supplied Host header, so the lab container could point
    # a request at its own server, spoof the header, and collect the real
    # credential. hostmatch takes a host string and cannot tell where it came
    # from, so this line is the control, not the helper.
    host = flow.request.host

    path = flow.request.path.split("?", 1)[0]

    # Only the token-exchange paths are answered. The rest of sts. and oauth2.
    # are ordinary APIs living under the same names, so they fall through to
    # injection below rather than being short-circuited — an early return here
    # would silently leave those calls unauthenticated.
    if hostmatch.matches(host, TOKEN_HOSTS) and path in TOKEN_PATHS:
        # Answered, not forwarded. Nothing goes to Google and the client
        # receives a value that is worthless anywhere else.
        flow.response = http.Response.make(
            200,
            b'{"access_token":"' + INERT_TOKEN.encode() + b'",'
            b'"expires_in":3600,"token_type":"Bearer","scope":'
            b'"https://www.googleapis.com/auth/cloud-platform"}',
            {"Content-Type": "application/json"},
        )
        ctx.log.info(f"gcp: answered token exchange at {host}{path} with an inert token")
        audit.log_event("token_exchange_answered", provider="gcp", host=host, endpoint=path)
        return

    if not hostmatch.matches(host, API_HOSTS):
        return

    # Strip first, as its own statement. _get_token() raises when the broker is
    # unreachable, so a single assignment that both strips and injects strips
    # nothing on failure and forwards the client's own Authorization header to
    # Google untouched — the opposite of what the strip is for. See 1.4.3.
    if "Authorization" in flow.request.headers:
        del flow.request.headers["Authorization"]

    flow.request.headers["Authorization"] = f"Bearer {_get_token()}"
    ctx.log.info(f"gcp: {flow.request.method} {host}{_endpoint(flow)}")
    audit.log_event(
        "token_injected", provider="gcp", host=host,
        method=flow.request.method, endpoint=_endpoint(flow),
    )


def response(flow: http.HTTPFlow) -> None:
    # A 401 means the cached token is no longer good — drop it so the next
    # request mints a fresh one rather than replaying a dead credential for the
    # rest of the TTL. Same as 010_github.py.
    if flow.response and flow.response.status_code == 401 and hostmatch.matches(
        flow.request.host, API_HOSTS
    ):
        _cache.pop("token", None)
