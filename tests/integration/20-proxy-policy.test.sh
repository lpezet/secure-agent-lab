#!/usr/bin/env bash
# proxy 000_policy.py: the lab container must not be able to tunnel to internal
# services through the proxy. Docker network isolation stops lab routing to the
# broker directly, but not this: the proxy is on both networks, so on the path
# this addon covers it is the only control rather than a second layer. Since
# 1.10.0 the image carries it, so a deployment can no longer omit it — the
# suites at the bottom of this file are what hold that.
#
# Plain HTTP only — testing the HTTPS path would need the generated CA, and the
# policy addon matches on hostname before any TLS decision is made.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-proxy"
build_image "$IMG" stack/proxy || exit 1

# A genuinely empty directory to mount as /addons. 0755 rather than mktemp's
# 0700: the proxy container runs as the mitmproxy uid, which is not the host
# uid on every machine — see the quirk in tests/README.md.
EMPTY_DIR=$(mktemp -d)
chmod 0755 "$EMPTY_DIR"
trap 'rm -rf "$EMPTY_DIR"; cleanup' EXIT

net_up
curl_up
# The stub answers to `broker`, `cred-gateway` (blocked names) and
# `external-api` (a stand-in for a legitimate destination).
stub_broker_up cred-gateway external-api

# proxy_up <label> [extra docker args...] — start a proxy and wait for it to
# serve. Echoes the container name. Several variants are needed now that the
# base addons come from the image rather than the mount: with the mount, with
# no mount at all, and with the internal-host set reconfigured.
proxy_up() {
  local label="$1"; shift
  local name="$RUN_ID-proxy-$label"
  # Readiness is probed through the proxy, so it has to name a host that
  # variant actually permits — the POLICY_INTERNAL_HOSTS case blocks the
  # default one on purpose.
  local ready_host="${READY_HOST:-external-api}"
  docker run -d --name "$name" --network "$NET" \
    -e BROKER_URL=http://broker:8080 -e PYTHONUNBUFFERED=1 \
    "$@" "$IMG" >/dev/null
  track_container "$name"
  # mitmdump takes a moment to import addons; poll through the proxy itself.
  local i
  for i in $(seq 1 60); do
    if [ "$(http_code "http://$ready_host:8080/ping" --proxy "http://$name:8080")" = "200" ]; then
      printf '%s' "$name"; return 0
    fi
    sleep 0.5
  done
  ko "proxy '$label' did not become ready" "$(docker logs "$name" 2>&1 | tail -20)"
  printf '%s' "$name"
  return 1
}

# The deployment-shaped case: /addons mounted, as every deployment written
# before the image carried these addons still does.
PX=$(proxy_up vendored -v "$REPO_ROOT/stack/proxy/addons:/addons:ro") || finish

suite "proxy forwards legitimate destinations"
check "GET external-api through proxy" "200" \
  "$(http_code "http://external-api:8080/ping" --proxy "http://$PX:8080")"
check_contains "response comes from the upstream" \
  "$(http_body "http://external-api:8080/ping" --proxy "http://$PX:8080")" "BROKER-HIT"

suite "proxy blocks internal hostnames (000_policy.py)"
for host in broker cred-gateway; do
  code=$(http_code "http://$host:8080/healthz" --proxy "http://$PX:8080")
  check "CONNECT-less GET to $host is blocked" "403" "$code"
  body=$(http_body "http://$host:8080/healthz" --proxy "http://$PX:8080")
  check_contains "$host block cites the policy addon" "$body" "internal host blocked"
  check_not_contains "$host response never carries upstream content" "$body" "BROKER-HIT"
done

suite "block applies regardless of method or path"
for m in GET POST PUT DELETE; do
  check "$m http://broker:8080/github/token is blocked" "403" \
    "$(http_code "http://broker:8080/github/token" -X "$m" --proxy "http://$PX:8080")"
done

suite "host-header spoofing does not bypass the block"
# REGRESSION: the addon originally matched flow.request.pretty_host, which
# prefers the client-supplied Host header. mitmproxy still connects to
# flow.request.host, so one header turned the proxy into an open door to the
# broker — `-H 'Host: anything'` returned a real /github/token. Both checks
# below failed before the fix.
check "spoofed Host on a broker URL is still blocked" "403" \
  "$(http_code "http://broker:8080/healthz" -H "Host: external-api" --proxy "http://$PX:8080")"
check "spoofed Host cannot reach a credential endpoint" "403" \
  "$(http_code "http://broker:8080/github/token" -H "Host: external-api" --proxy "http://$PX:8080")"
check_not_contains "spoofed request never carries broker content" \
  "$(http_body "http://broker:8080/github/token" -H "Host: external-api" --proxy "http://$PX:8080")" \
  "BROKER-HIT"
check "spoofed Host on cred-gateway is still blocked" "403" \
  "$(http_code "http://cred-gateway:8080/github/credential" -H "Host: external-api" --proxy "http://$PX:8080")"

suite "case does not bypass the block"
# DNS is case-insensitive, so http://BROKER:8080/ resolves to the same
# container. If the addon compares the host case-sensitively, one shifted
# letter is a complete bypass of the internal-host block.
check "GET http://BROKER:8080/github/token is blocked" "403" \
  "$(http_code "http://BROKER:8080/github/token" --proxy "http://$PX:8080")"
check_not_contains "and never carries broker content" \
  "$(http_body "http://BROKER:8080/github/token" --proxy "http://$PX:8080")" "BROKER-HIT"
check "GET http://Cred-Gateway:8080/ is blocked" "403" \
  "$(http_code "http://Cred-Gateway:8080/github/credential" --proxy "http://$PX:8080")"
check "claiming Host: BROKER is denied too" "403" \
  "$(http_code "http://external-api:8080/ping" -H "Host: BROKER" --proxy "http://$PX:8080")"

# The reverse direction fails closed: claiming to be an internal host is denied
# even when the real destination is external. Harmless over-blocking, and it
# keeps the rule easy to reason about.
check "claiming Host: broker is denied even when the target is external" "403" \
  "$(http_code "http://external-api:8080/ping" -H "Host: broker" --proxy "http://$PX:8080")"

# --------------------------------------------------------- baked into the image
#
# The reason this addon moved into the image (#62). A deployment that mounts an
# empty proxy/ directory — a reasonable-looking thing to do when the bank
# supplies addons and you have installed none yet — used to get no policy addon
# at all, and the proxy would forward straight to the broker. cred-gateway is
# not the only path there: the proxy sits on both networks.
suite "an empty /addons still gets the policy addon"
PX_EMPTY=$(proxy_up empty -v "$EMPTY_DIR:/addons:ro") || finish
check "GET http://broker:8080/github/token is blocked" "403" \
  "$(http_code "http://broker:8080/github/token" --proxy "http://$PX_EMPTY:8080")"
check_not_contains "and never carries broker content" \
  "$(http_body "http://broker:8080/github/token" --proxy "http://$PX_EMPTY:8080")" "BROKER-HIT"
check "spoofed Host is blocked here too" "403" \
  "$(http_code "http://broker:8080/github/token" -H "Host: external-api" --proxy "http://$PX_EMPTY:8080")"
check "an uppercased host is blocked here too" "403" \
  "$(http_code "http://BROKER:8080/github/token" --proxy "http://$PX_EMPTY:8080")"
check "legitimate destinations still pass" "200" \
  "$(http_code "http://external-api:8080/ping" --proxy "http://$PX_EMPTY:8080")"

suite "no /addons mount at all behaves the same"
# Not the same as an empty directory: `find` on a missing path errors rather
# than returning nothing, so this is the case that breaks if entrypoint.sh
# forgets to tolerate it.
PX_NONE=$(proxy_up nomount) || finish
check "GET http://broker:8080/github/token is blocked" "403" \
  "$(http_code "http://broker:8080/github/token" --proxy "http://$PX_NONE:8080")"

suite "a vendored copy is skipped, not double-loaded"
# Every deployment predating the bake still ships its own 000_policy.py. The
# image's copy wins — that is the point of baking it — but silently stacking a
# second one would hide which is in force.
logs=$(docker logs "$PX" 2>&1)
check_contains "startup names the shadowed file" "$logs" "ignoring /addons/000_policy.py"
check_contains "and says the image ships it" "$logs" "the image ships 000_policy.py"
loaded=$(printf '%s\n' "$logs" | grep -c 'policy: blocking internal host' || true)
check "the policy addon is loaded exactly once" "1" "$loaded"
check_contains "the mounted allowlist addon is skipped too" "$logs" "ignoring /addons/001_allowlist.py"

suite "POLICY_INTERNAL_HOSTS is deployment config, and it takes effect"
# A stack that renames its services must still be able to name them. Set to a
# host that is NOT broker, so both directions are proven at once: the named one
# starts being blocked, and the default one stops.
PX_CFG=$(READY_HOST=broker proxy_up renamed \
           -e POLICY_INTERNAL_HOSTS="external-api, Cred-Gateway.") || finish
check "the newly named host is blocked" "403" \
  "$(http_code "http://external-api:8080/ping" --proxy "http://$PX_CFG:8080")"
check "case and trailing dot in the config are normalised" "403" \
  "$(http_code "http://cred-gateway:8080/healthz" --proxy "http://$PX_CFG:8080")"
check "a host no longer listed is no longer blocked" "200" \
  "$(http_code "http://broker:8080/healthz" --proxy "http://$PX_CFG:8080")"
check_contains "startup says what it is blocking" \
  "$(docker logs "$PX_CFG" 2>&1)" "cred-gateway, external-api"

finish
