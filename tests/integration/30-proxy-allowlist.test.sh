#!/usr/bin/env bash
# proxy 001_allowlist.py: egress control. Absent file → permissive (documented
# behaviour, so the stack works before anyone writes an allowlist). Present
# file → default-deny with per-domain method restrictions.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-proxy"
build_image "$IMG" stack/proxy || exit 1

net_up
curl_up
stub_broker_up readonly-api write-api anything-api foo.cdn.test other-api

# start_proxy <outvar> <name> [allowlist-file]
# Sets <outvar> to the container name; returns non-zero if it never came up.
# Must NOT be called in a command substitution: track_container has to run in
# this shell or the EXIT trap never sees the container and it leaks.
start_proxy() {
  local outvar="$1" name="$RUN_ID-$2"; shift 2
  local mount=()
  [ $# -gt 0 ] && mount=(-v "$1:/etc/agent-allowlist:ro")
  printf -v "$outvar" '%s' "$name"
  docker run -d --name "$name" --network "$NET" \
    -v "$REPO_ROOT/stack/proxy/addons:/addons:ro" \
    "${mount[@]}" -e BROKER_URL=http://broker:8080 -e PYTHONUNBUFFERED=1 \
    -e AUDIT_LOG=/tmp/audit.jsonl \
    "$IMG" >/dev/null
  track_container "$name"
  local i code
  for i in $(seq 1 60); do
    code=$(http_code "http://readonly-api:8080/ping" --proxy "http://$name:8080")
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    sleep 0.5
  done
  return 1
}

suite "no allowlist file → permissive (documented default)"
if start_proxy PX permissive; then
  check "unlisted destination allowed" "200" \
    "$(http_code "http://other-api:8080/ping" --proxy "http://$PX:8080")"
  check "POST to unlisted destination allowed" "200" \
    "$(http_code "http://other-api:8080/ping" -X POST --proxy "http://$PX:8080")"

  # Permissive mode must still record what it forwarded. Patched the other way
  # round, the deployment with NO egress policy would be the one whose trail
  # said the least about its egress — and `reason` is what stops a reader
  # mistaking "nothing is enforcing" for "a rule permitted this".
  ptrail=$(docker exec "$PX" cat /tmp/audit.jsonl 2>/dev/null)
  check_contains "forwarding is recorded" "$ptrail" '"event":"allowed"'
  check_contains "and says nothing is enforcing" "$ptrail" '"reason":"permissive"'
else
  ko "permissive proxy did not start" "$(docker logs "$PX" 2>&1 | tail -20)"
fi

suite "allowlist file present → default-deny"
if start_proxy PXA enforcing "$FIXTURES/allowlist"; then
  P="--proxy http://$PXA:8080"

  check "unlisted domain blocked" "403" "$(http_code "http://other-api:8080/ping" $P)"
  check_contains "block cites the allowlist" \
    "$(http_body "http://other-api:8080/ping" $P)" "blocked by allowlist"

  # `readonly-api` carries a trailing `# comment` and no method column, so it
  # must fall back to GET,HEAD,OPTIONS. Before inline comments were stripped,
  # "# trailing comment; defaults to get,head,options" was parsed as the method
  # list and blocked everything — fail-closed, but silent and hard to debug.
  check "trailing comment does not become the method list" "200" \
    "$(http_code "http://readonly-api:8080/ping" $P)"
  check "listed domain, default methods: GET allowed" "200" \
    "$(http_code "http://readonly-api:8080/ping" $P)"
  check "listed domain, default methods: POST blocked" "403" \
    "$(http_code "http://readonly-api:8080/ping" -X POST $P)"
  check "listed domain, default methods: DELETE blocked" "403" \
    "$(http_code "http://readonly-api:8080/ping" -X DELETE $P)"

  # `write-api GET,POST`
  check "explicit methods: GET allowed" "200" \
    "$(http_code "http://write-api:8080/ping" $P)"
  check "explicit methods: POST allowed" "200" \
    "$(http_code "http://write-api:8080/ping" -X POST $P)"
  check "explicit methods: PUT blocked" "403" \
    "$(http_code "http://write-api:8080/ping" -X PUT $P)"

  # `anything-api *`
  for m in GET POST PUT DELETE PATCH; do
    check "wildcard methods: $m allowed" "200" \
      "$(http_code "http://anything-api:8080/ping" -X "$m" $P)"
  done

  # `*.cdn.test GET`
  check "wildcard domain matches subdomain" "200" \
    "$(http_code "http://foo.cdn.test:8080/ping" $P)"
  check "wildcard domain still enforces methods" "403" \
    "$(http_code "http://foo.cdn.test:8080/ping" -X POST $P)"

  # A suffix match must not let `evilcdn.test` through on `*.cdn.test`. Since
  # 1.7.0 the comparison lives in hostmatch.matches() rather than in this
  # addon, which is what makes it worth asserting here as well as in the unit
  # tests: this is the caller proving it passes the patterns through intact.
  check "wildcard does not match a sibling domain" "403" \
    "$(http_code "http://evilcdn.test:8080/ping" $P)"
  # The apex is not a subdomain. Neither host resolves on this network, which
  # does not matter — the addon answers before DNS is consulted.
  check "wildcard does not match the apex" "403" \
    "$(http_code "http://cdn.test:8080/ping" $P)"

  # Internal hosts stay blocked by 000_policy even in permissive method terms.
  check "internal host still blocked when allowlist is active" "403" \
    "$(http_code "http://broker:8080/healthz" $P)"

  # REGRESSION: the addon matched pretty_host, so spoofing the Host header to
  # an allowlisted domain let any destination through — egress control off with
  # one header. It now matches the real destination.
  check "spoofed Host does not smuggle an unlisted destination" "403" \
    "$(http_code "http://other-api:8080/ping" -H "Host: anything-api" $P)"
  check "spoofed Host does not upgrade the permitted method set" "403" \
    "$(http_code "http://readonly-api:8080/ping" -X POST -H "Host: anything-api" $P)"

  # Until now this addon emitted one event type. A trail that can say what the
  # agent was stopped from doing and never what it did is half a trail, and
  # the half it was missing is the one that says a deployment is working.
  etrail=$(docker exec "$PXA" cat /tmp/audit.jsonl 2>/dev/null)
  check_contains "a permitted request is recorded" "$etrail" '"event":"allowed"'
  check_contains "citing the rule that permitted it" "$etrail" '"reason":"allowlist"'
  check_contains "carrying the real destination" "$etrail" '"host":"write-api"'
  check_contains "and the method that was checked" "$etrail" '"method":"POST"'
  check_contains "denials are still recorded" "$etrail" '"event":"blocked"'

  # The whole safety question. Every request above went to /ping, so a path
  # reaching the trail by any route shows up here — this addon is in the base
  # image, sees hosts it knows nothing about, and so cannot compute a safe
  # slice of a path the way a provider's addon can.
  check_not_contains "and never the path" "$etrail" "/ping"

  # The spoofed-Host requests are the sharper case: `allowed` must name where
  # the request really went, or the trail records the attacker's claim as
  # fact. Asserted as "other-api never appears on a permitted line" rather
  # than by matching the spoofed pair — `anything-api POST` is also a
  # legitimate permitted request in this suite, so the naive form would pass
  # for the wrong reason and fail on a real one.
  allowed_lines=$(printf '%s\n' "$etrail" | grep '"event":"allowed"' || true)
  check_not_contains "an unlisted destination is never recorded as permitted" \
    "$allowed_lines" '"host":"other-api"'
else
  ko "enforcing proxy did not start" "$(docker logs "$PXA" 2>&1 | tail -20)"
fi

suite "CONNECT is not recorded as permitted traffic"
# Every HTTPS request reaches this addon twice — the CONNECT that opens the
# tunnel, then the inner request. Logging both doubles the trail's volume to
# say method=CONNECT, which is never the agent's intent and is not what any
# allowlist entry is written against. The inner request is the event.
#
# Asserted against the function rather than through a real tunnel: a genuine
# CONNECT needs TLS and a CA the client trusts, which is the e2e tier's job
# (tests/README.md). The rule is what is worth pinning, and it is one branch.
#
# --entrypoint bypasses the base image's usermod/gosu wrapper, which exists to
# align uids with a mounted cert volume and has nothing to do here.
conn_out=$(docker run --rm --entrypoint python3 \
  -e AUDIT_LOG=/tmp/audit.jsonl "$IMG" -c '
import sys, importlib
sys.path.insert(0, "/opt/agent-proxy/addons")
m = importlib.import_module("001_allowlist")
m._log_allowed("api.example.com", "CONNECT", "allowlist")
m._log_allowed("api.example.com", "GET", "allowlist")
sys.stdout.write(open("/tmp/audit.jsonl").read())
' 2>&1)
check_contains "the inner request is recorded" "$conn_out" '"method":"GET"'
check_not_contains "the tunnel handshake is not" "$conn_out" '"method":"CONNECT"'

# The skip is scoped to _log_allowed and deliberately does not reach the
# denial path: when CONNECT itself is refused there is no inner request to
# stand in for it, so skipping there would lose the event entirely. That
# asymmetry is asserted where it can be — a real refused CONNECT needs TLS,
# so the e2e tier owns it.

finish
