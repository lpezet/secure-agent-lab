#!/usr/bin/env bash
# Helpers for the e2e tier. Source this instead of ../lib.sh — it pulls lib.sh
# in and adds the bits specific to driving a running compose stack.
#
# The stack is already up by the time a suite runs (tests/e2e/run.sh brings it
# up and tears it down), so suites here create no docker resources of their own
# and lib.sh's EXIT trap has nothing to clean.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose -f "$E2E_DIR/compose.yaml")

# Credential shapes, for check_no_secret. Matching the shape rather than the
# value means a suite never has to hold the secret it is asserting about.
SECRET_PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'gh[psuor]_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'v1\.[0-9a-f]{40,}'          # GitHub App installation token
)

# lab <cmd...> — run a command in the lab container. Non-interactive, stderr
# folded in, never fails the calling shell: assertions decide what a failure is.
lab() { "${COMPOSE[@]}" exec -T lab "$@" 2>&1; }

# lab_sh <script> — same, through bash -c.
lab_sh() { "${COMPOSE[@]}" exec -T lab bash -c "$1" 2>&1; }

# lab_code <url> [curl-args...] — HTTP status of a request made from lab.
lab_code() {
  local url="$1"; shift
  "${COMPOSE[@]}" exec -T lab curl -s -o /dev/null -w '%{http_code}' \
    --max-time 30 "$@" "$url" 2>/dev/null
}

# lab_body <url> [curl-args...] — response body of a request made from lab.
lab_body() {
  local url="$1"; shift
  "${COMPOSE[@]}" exec -T lab curl -s --max-time 30 "$@" "$url" 2>/dev/null
}

# svc_logs <service> — recent logs, for failure detail.
svc_logs() { "${COMPOSE[@]}" logs --tail 30 "$1" 2>&1; }

# audit_trail [service] — every line in the shared audit trail, or one file's.
#
# Read through log-rotator: it is the only service running as root with the
# volume read-write, so it can read whatever broker (node), proxy (mitmproxy)
# and cred-gateway (nginx) each wrote, regardless of which uid owns the file.
# Reading through any of the writers would work until it did not.
audit_trail() {
  local f="${1:-}"
  if [ -n "$f" ]; then
    "${COMPOSE[@]}" exec -T log-rotator sh -c "cat /var/log/audit/$f.jsonl 2>/dev/null" 2>/dev/null
  else
    "${COMPOSE[@]}" exec -T log-rotator sh -c 'cat /var/log/audit/*.jsonl 2>/dev/null' 2>/dev/null
  fi
}

# audit_has <trail> <field> <value> — 1 if the trail contains that pair.
#
# Whitespace-tolerant on purpose. The two writers disagree: audit.js emits
# `"service":"broker"` and audit.py emits `"service": "proxy"`, because
# JSON.stringify is compact and json.dumps is not. Both are valid JSON and
# observer parses per line, so nothing is broken — but a string match written
# for one silently misses the other, which is a trap worth not laying twice.
audit_has() {
  printf '%s\n' "$1" | grep -qE "\"$2\"[[:space:]]*:[[:space:]]*\"$3\"" && echo 1 || echo 0
}

# audit_field <json-line-stream> <field> — values of a field, one per line.
# Deliberately not jq: the tier already avoids it, and this only ever reads
# structural fields out of lines the stack wrote.
audit_field() {
  printf '%s\n' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | sed -E "s/.*:[[:space:]]*\"(.*)\"$/\1/"
}
