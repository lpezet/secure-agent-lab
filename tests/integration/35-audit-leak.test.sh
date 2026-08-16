#!/usr/bin/env bash
# No credential value reaches the audit trail.
#
# The trail is a plaintext file that observer serves over HTTP to anyone who
# can reach :9000, so a secret written into it has left the boundary the rest
# of this stack exists to hold. 00-config-lint.test.sh guards the two ways we
# know of to put one there (a raw request path, an exception message), but it
# guards them by name: it greps for the mistakes already made. This suite
# takes the other approach — taint every input a secret could arrive on, drive
# real traffic, then scan the whole trail for the taints. It does not need to
# know how a leak would be spelled, only that the value must not come out the
# far end.
#
# That is what makes it hold when a vendor moves its credential. If an API
# starts returning a token in a response body and an addon logs the body, no
# static check fires — RESPONSE_TAINT below does.
#
# Two failure modes are designed against specifically:
#   - A vacuous pass. "No taint in the trail" is also what you get from a
#     trail that was never written (audit.py no-ops when AUDIT_LOG is unset,
#     and swallows OSError if the mount is not writable). The first suite
#     proves the trail is live before any absence is asserted.
#   - A scan that cannot detect anything. The last suite runs the same scan
#     against a deliberately vulnerable addon and requires it to FAIL to find
#     the trail clean.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-proxy"
build_image "$IMG" stack/proxy || exit 1

# One taint per channel a secret can ride in on. Distinct strings so a failure
# names the channel, and none of them match the credential shapes
# 00-config-lint greps for, so committing this file is safe.
INJECTED_TAINT="TAINT-BROKER-ISSUED-CREDENTIAL"
URLPATH_TAINT="TAINT-IN-URL-PATH-SEGMENT"
QUERY_TAINT="TAINT-IN-QUERY-STRING"
HEADER_TAINT="TAINT-IN-REQUEST-HEADER"
RESPONSE_TAINT="TAINT-IN-RESPONSE-BODY"
# Deliberately expected to appear. See the "endpoint field is a bounded
# prefix" suite: the addons keep the leading segments of the path on purpose,
# and this taint is how that bound is pinned to a number.
PREFIX_TAINT="TAINT-IN-STRUCTURAL-PREFIX"

# Echo server. Answers to every vendor host the addons match, plus
# api.telegram.org for the positive control. Its body carries RESPONSE_TAINT
# so an addon that logs response content is caught the same way as one that
# logs a request.
ECHO_CONF="$RUN_ID-echo.conf"
cat > "/tmp/$ECHO_CONF" <<EOF
server {
  listen 8080;
  location / {
    default_type text/plain;
    return 200 "ok token=$RESPONSE_TAINT\n";
  }
}
EOF

BROKER_CONF="$RUN_ID-broker.conf"
cat > "/tmp/$BROKER_CONF" <<EOF
server {
  listen 8080;
  default_type application/json;
  location = /github/token      { return 200 '{"token":"$INJECTED_TAINT"}'; }
  location = /anthropic/cred    { return 200 '{"type":"api_key","value":"$INJECTED_TAINT"}'; }
  location = /cloudflare/token  { return 200 '{"token":"$INJECTED_TAINT"}'; }
  location / { return 404 '{"error":"no such provider route"}'; }
}
EOF

net_up
curl_up

BK="$RUN_ID-brokerstub"
docker run -d --name "$BK" --network "$NET" --network-alias broker \
  -v "/tmp/$BROKER_CONF:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
track_container "$BK"

EC="$RUN_ID-echo"
docker run -d --name "$EC" --network "$NET" \
  --network-alias api.github.com --network-alias api.anthropic.com \
  --network-alias api.cloudflare.com --network-alias api.telegram.org \
  --network-alias attacker-host \
  -v "/tmp/$ECHO_CONF:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
track_container "$EC"

wait_http "$BK:8080/github/token" 200 "broker stub"

# run_proxy <name> <addon-dir> → starts a proxy writing its trail to
# /tmp/<name>-audit/proxy.jsonl on the host. 0777 because the addons run as
# the image's mitmproxy uid, which is not the uid running this script; a
# failure here is silent by design in audit.py, so the caller must verify the
# trail is non-empty rather than trusting the mount.
run_proxy() {
  local name="$RUN_ID-$1" dir="$2"
  local audit_dir="/tmp/$RUN_ID-$1-audit"
  mkdir -p "$audit_dir"
  chmod 777 "$audit_dir"
  docker run -d --name "$name" --network "$NET" \
    -v "$REPO_ROOT/$dir:/addons:ro" -v "$audit_dir:/var/log/audit" \
    -e BROKER_URL=http://broker:8080 \
    -e AUDIT_LOG=/var/log/audit/proxy.jsonl \
    -e PYTHONUNBUFFERED=1 "$IMG" >/dev/null
  track_container "$name"
  local i
  for i in $(seq 1 60); do
    [ "$(http_code "http://attacker-host:8080/x" --proxy "http://$name:8080")" = "200" ] && return 0
    sleep 0.5
  done
  return 1
}

trail() { cat "/tmp/$RUN_ID-$1-audit/proxy.jsonl" 2>/dev/null; }

# ------------------------------------------------- the shipped addons

# dev-container carries all four (claude-code has no cloudflare addon), so
# this exercises every addon the project ships in one proxy.
if ! run_proxy shipped examples/dev-container/.devcontainer/proxy; then
  ko "proxy did not start" "$(docker logs "$RUN_ID-shipped" 2>&1 | tail -20)"
  finish
fi
P="--proxy http://$RUN_ID-shipped:8080"
H="-H X-Test-Secret:$HEADER_TAINT"

# Every taint on every matched host: a credential in a path segment, one in
# the query string, one in a header, one in the response, and the injected
# credential the addon fetches from the broker.
#
# URLPATH_TAINT sits one segment deeper than each addon's parse keeps —
# segment 3 for Anthropic (`[:2]`), segment 4 for Cloudflare (`[:3]`) — which
# is where these APIs put variable content: a message id, an account id.
# PREFIX_TAINT sits *inside* the kept prefix, and is asserted present further
# down rather than absent.
http_body "http://api.github.com:8080/repos/$PREFIX_TAINT/$URLPATH_TAINT?token=$QUERY_TAINT" $H $P >/dev/null
http_body "http://api.anthropic.com:8080/v1/$PREFIX_TAINT/$URLPATH_TAINT?token=$QUERY_TAINT" $H $P >/dev/null
http_body "http://api.cloudflare.com:8080/client/v4/$PREFIX_TAINT/$URLPATH_TAINT?token=$QUERY_TAINT" $H $P >/dev/null
# Blocked paths log too, and a block handler sees exactly the attacker's URL.
http_body "http://api.anthropic.com:8080/v1/organizations/api_keys?token=$QUERY_TAINT" $H $P >/dev/null
http_body "http://broker:8080/github/token?token=$QUERY_TAINT" $H $P >/dev/null
sleep 1

suite "the trail is live (guards against a vacuous pass below)"
t=$(trail shipped)
if [ -z "$t" ]; then
  ko "proxy wrote no audit trail" "AUDIT_LOG unset, or /var/log/audit not writable by the mitmproxy uid — every absence check below would pass for the wrong reason"
  finish
fi
ok "trail is non-empty ($(printf '%s' "$t" | wc -l) events)"
check_contains "an injection was recorded" "$t" '"event":"token_injected"'
check_contains "a block was recorded" "$t" '"event":"blocked"'

suite "no taint reaches the trail"
check_not_contains "broker-issued credential is not logged" "$t" "$INJECTED_TAINT"
check_not_contains "URL path segment is not logged" "$t" "$URLPATH_TAINT"
check_not_contains "query string is not logged" "$t" "$QUERY_TAINT"
check_not_contains "request header is not logged" "$t" "$HEADER_TAINT"
check_not_contains "response body is not logged" "$t" "$RESPONSE_TAINT"

suite "the endpoint field is a bounded prefix, and the bound is a vendor bet"
# The one place path content reaches the trail on purpose. 020_anthropic and
# 030_cloudflare log a parsed endpoint — the first 2 and 3 segments — because
# those segments are structural for those APIs: /v1/<method>,
# /client/v4/<resource>. Nothing is redacted there; it is safe only because
# the vendor does not put variable content that shallow.
#
# That is a bet on someone else's URL design, so it is pinned rather than
# assumed. If an addon's slice is widened, or a vendor starts putting an id
# or a token in a segment inside the bound, PREFIX_TAINT moves from "expected
# here" to a leak and these flip. Read a failure as "re-check what that
# vendor puts in that segment", not as a broken test.
check_contains "anthropic keeps segment 2 (/v1/<method>)" "$t" "\"endpoint\":\"/v1/$PREFIX_TAINT\""
check_contains "cloudflare keeps segment 3 (/client/v4/<resource>)" "$t" \
  "\"endpoint\":\"/client/v4/$PREFIX_TAINT\""
gh_line=$(printf '%s\n' "$t" | grep '"provider":"github"' | head -1)
check_not_contains "github logs no path at all" "$gh_line" "endpoint"

# ------------------------------------------- positive control

suite "the scan detects a leak when there is one"
# Without this, everything above is a test that cannot fail: it would report
# the same five passes against a scanner that matched nothing at all.
# tests/fixtures/leaky-addon/900_leaky.py is the Telegram snippet this
# project shipped in PLAYBOOK.md from 1.2.0 to 1.4.1.
if ! run_proxy leaky tests/fixtures/leaky-addon; then
  ko "leaky-addon proxy did not start" "$(docker logs "$RUN_ID-leaky" 2>&1 | tail -20)"
  finish
fi
http_body "http://api.telegram.org:8080/bot$URLPATH_TAINT/sendMessage?text=$QUERY_TAINT" \
  --proxy "http://$RUN_ID-leaky:8080" >/dev/null
sleep 1

lt=$(trail leaky)
if [ -z "$lt" ]; then
  ko "leaky addon wrote no trail" "cannot demonstrate the scan works"
else
  check_contains "raw path leaks the credential in the path" "$lt" "$URLPATH_TAINT"
  check_contains "raw path leaks the query string too" "$lt" "$QUERY_TAINT"

  # The subtlety the split("/") version turns on, asserted per line: the
  # token is in segment 1 so it never appears, and the parse looks careful.
  # Only the query string comes through — attached to segment 2.
  split_line=$(printf '%s\n' "$lt" | grep '"event":"naive_split"' || true)
  check_not_contains "split(\"/\") keeps the path-segment token out" "$split_line" "$URLPATH_TAINT"
  check_contains "...but carries the query string into the trail" "$split_line" "$QUERY_TAINT"
fi

rm -f "/tmp/$ECHO_CONF" "/tmp/$BROKER_CONF"
rm -rf "/tmp/$RUN_ID"-*-audit

finish
