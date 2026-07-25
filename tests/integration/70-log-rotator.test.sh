#!/usr/bin/env bash
# log-rotator: validates the shipped logrotate config and the permission
# self-heal the other services depend on (broker's `node` and proxy's
# `mitmproxy` are different non-root uids writing into one shared directory).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-log-rotator"
build_image "$IMG" stack/log-rotator || exit 1

suite "logrotate config"
out=$(docker run --rm "$IMG" logrotate -d /etc/logrotate.d/audit-logs 2>&1)
check_contains "dry-run parses the shipped config" "$out" "/var/log/audit/broker.jsonl"
check_not_contains "dry-run reports no config errors" "$out" "error"

suite "runs as root"
# Deliberate exception to every other service in this stack — see CLAUDE.md.
# Needed so it can chmod a directory regardless of which non-root uid
# (broker's `node`, proxy's `mitmproxy`) wrote into it, and copytruncate
# files it does not own.
net_up
LR="$RUN_ID-log-rotator"
AUDIT="/tmp/$RUN_ID-lr-audit"
mkdir -p "$AUDIT"
# Simulate the worst case: a directory left root-owned, mode 0755, by
# whichever service's image happened to trigger the volume's first mount —
# the scenario the entrypoint's chmod exists to correct.
chmod 755 "$AUDIT"

docker run -d --name "$LR" --network "$NET" -v "$AUDIT:/var/log/audit" "$IMG" >/dev/null
track_container "$LR"
sleep 1

check "container user is root" "root" "$(docker exec "$LR" whoami 2>/dev/null)"

suite "entrypoint fixes shared-volume permissions on start"
check "audit-logs directory is world-writable after entrypoint runs" "1777" \
  "$(docker exec "$LR" stat -c %a /var/log/audit 2>/dev/null)"

suite "crond is running"
check "crond process present" "0" "$(docker exec "$LR" sh -c 'pgrep crond >/dev/null'; echo $?)"

rm -rf "$AUDIT"
finish
