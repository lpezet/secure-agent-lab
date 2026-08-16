#!/usr/bin/env bash
# observer: tails a JSONL directory and serves it live over SSE. Uses a plain
# bind-mounted host directory in place of the real audit-logs named volume, so
# the test can append/truncate files directly with no other service involved.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-observer"
build_image "$IMG" stack/observer || exit 1

net_up
curl_up

AUDIT="/tmp/$RUN_ID-audit"
mkdir -p "$AUDIT"
echo '{"ts":"2026-01-01T00:00:00Z","service":"broker","event":"token_issued","provider":"github"}' >> "$AUDIT/broker.jsonl"

OBS="$RUN_ID-observer"
docker run -d --name "$OBS" --network "$NET" \
  -v "$AUDIT:/var/log/audit:ro" "$IMG" >/dev/null
track_container "$OBS"

if ! wait_http "$OBS:9000/healthz" 200 "observer"; then
  ko "observer did not start" "$(docker logs "$OBS" 2>&1 | tail -20)"
  finish
fi

suite "health and dashboard"
check "GET /healthz" "200" "$(http_code "http://$OBS:9000/healthz")"
check_contains "/healthz body" "$(http_body "http://$OBS:9000/healthz")" '"ok":true'
check "GET / serves the dashboard" "200" "$(http_code "http://$OBS:9000/")"
check_contains "dashboard wires up the SSE client" "$(http_body "http://$OBS:9000/")" "EventSource"
check "unknown route is 404" "404" "$(http_code "http://$OBS:9000/nope")"

suite "observer runs unprivileged"
check "container user is not root" "node" "$(docker exec "$OBS" whoami 2>/dev/null)"

suite "tails existing content"
sleep 1.5   # first poll tick
check_contains "seed line reaches a new SSE client" \
  "$(http_body "http://$OBS:9000/events" --max-time 2 -N)" "token_issued"

suite "tails appended lines"
echo '{"ts":"2026-01-01T00:00:01Z","service":"proxy","event":"blocked","reason":"allowlist"}' >> "$AUDIT/broker.jsonl"
sleep 1.5
body=$(http_body "http://$OBS:9000/events" --max-time 2 -N)
check_contains "backlog still has the seed line" "$body" "token_issued"
check_contains "backlog has the newly appended line" "$body" "allowlist"

suite "a malformed line does not crash the tailer"
echo 'not valid json' >> "$AUDIT/broker.jsonl"
sleep 1.5
check "observer is still healthy after a bad line" "200" "$(http_code "http://$OBS:9000/healthz")"
check_contains "bad line surfaces as its own event" \
  "$(http_body "http://$OBS:9000/events" --max-time 2 -N)" "unparseable_line"

suite "copytruncate rotation is followed, not just appended"
# log-rotator truncates the file in place rather than replacing it (see
# stack/log-rotator/logrotate.conf) — this is what an observer that only ever
# grows its read offset would get wrong.
: > "$AUDIT/broker.jsonl"
echo '{"ts":"2026-01-01T00:00:02Z","service":"broker","event":"credential_issued","provider":"github"}' >> "$AUDIT/broker.jsonl"
sleep 1.5
check_contains "post-rotation line is picked up from offset 0" \
  "$(http_body "http://$OBS:9000/events" --max-time 2 -N)" "credential_issued"

suite "/events responds before anything has been logged"
# A deployment that has not emitted an audit event yet has an empty backlog, so
# the SSE handler writes no body. Node holds headers until the first write, so
# without an explicit flush the client gets NOTHING — no headers, no error, just
# a hang — and the dashboard shows "connecting…" on a stack that is working
# fine. Needs its own container: $AUDIT has had lines in it since line 18.
EMPTY="/tmp/$RUN_ID-audit-empty"
mkdir -p "$EMPTY"
OBS2="$RUN_ID-observer-empty"
docker run -d --name "$OBS2" --network "$NET" \
  -v "$EMPTY:/var/log/audit:ro" "$IMG" >/dev/null
track_container "$OBS2"

if ! wait_http "$OBS2:9000/healthz" 200 "observer (empty trail)"; then
  ko "observer did not start against an empty audit dir" "$(docker logs "$OBS2" 2>&1 | tail -20)"
else
  # --max-time always trips: SSE never closes. What is under test is whether
  # curl saw response headers before the timeout (200) or nothing at all (000).
  check "headers arrive on an empty trail" "200" \
    "$(http_code "http://$OBS2:9000/events" --max-time 3 -N)"
  # And the stream is live, not merely opened: a line appended after the fact
  # still reaches a client that connected while the trail was empty.
  echo '{"ts":"2026-01-01T00:00:03Z","service":"broker","event":"token_issued","provider":"github"}' >> "$EMPTY/broker.jsonl"
  sleep 1.5
  check_contains "a line logged later still streams" \
    "$(http_body "http://$OBS2:9000/events" --max-time 2 -N)" "token_issued"
fi
rm -rf "$EMPTY"

rm -rf "$AUDIT"
finish
