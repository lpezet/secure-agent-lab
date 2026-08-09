#!/usr/bin/env bash
# End-to-end tier: the whole stack, real credentials, real vendor APIs.
#
#   tests/run.sh e2e            # via the facade
#   tests/e2e/run.sh            # or directly
#   tests/e2e/run.sh 20         # only suites starting with 20
#   KEEP_STACK=1 tests/e2e/run.sh   # leave the stack up afterwards to poke at
#
# Skips (exit 0) rather than fails when the credentials are not configured, so
# this is safe to wire into a pipeline that does not have them. Run it with no
# setup once and it will tell you exactly what is missing.
#
# This tier spends real API quota and pushes to a real repository. See README.
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
COMPOSE=(docker compose -f "$E2E_DIR/compose.yaml")

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; N=''
fi

# ----------------------------------------------------------------- subcommands
#
# `setup <name>` runs a one-time provisioning script instead of the suites.
# Dispatched here rather than implemented here: run.sh is about running tests,
# and gcloud logic in it would make that less true with every provider added.
if [ "${1:-}" = "setup" ]; then
  shift
  name="${1:-}"; shift 2>/dev/null || true
  [ -n "$name" ] || { echo "usage: run.sh setup <provider> [--yes|--teardown]" >&2; exit 2; }
  script="$E2E_DIR/setup/$name.sh"
  [ -f "$script" ] || { echo "no setup script for '$name' (looked for $script)" >&2; exit 2; }
  exec bash "$script" "$@"
fi

# ------------------------------------------------------------------ preflight

# Which suites were asked for, and therefore which credentials this run needs.
# Selecting first matters: demanding a GitHub App from someone running only
# `tests/run.sh e2e 40` would skip the tier over a credential nothing in it
# touches. Every suite also self-skips when its own inputs are missing, so this
# table degrades to a skip rather than a false pass if it drifts.
files=()
if [ $# -gt 0 ]; then
  for pat in "$@"; do
    for f in "$E2E_DIR/$pat"*.test.sh; do [ -f "$f" ] && files+=("$f"); done
  done
else
  for f in "$E2E_DIR"/*.test.sh; do [ -f "$f" ] && files+=("$f"); done
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "no test files matched" >&2
  exit 2
fi

NEEDS_GITHUB=0 NEEDS_ANTHROPIC=0
for f in "${files[@]}"; do
  case "$(basename "$f")" in
    40-gcp.test.sh)   ;;                                  # neither
    30-git.test.sh)   NEEDS_GITHUB=1 ;;                   # GitHub only
    *)                NEEDS_GITHUB=1; NEEDS_ANTHROPIC=1 ;;
  esac
done


: "${AGENT_CREDS_DIR:=$HOME/.config/agent-creds-e2e}"
export AGENT_CREDS_DIR

skip_tier() {
  printf '\n%se2e skipped%s — %s\n' "$Y" "$N" "$1"
  printf '   setup: %s/README.md\n' "$E2E_DIR"
  exit 0
}

# Refuse to point at the production credential directory. e2e mints tokens,
# pushes commits and burns quota; doing that with the App a real agent depends
# on turns a test bug into a production incident. This is a hard stop, not a
# warning — there is no legitimate reason to aim this tier at those creds.
PROD_CREDS="$HOME/.config/agent-creds"
if [ "$(cd "$AGENT_CREDS_DIR" 2>/dev/null && pwd)" = "$(cd "$PROD_CREDS" 2>/dev/null && pwd)" ] \
   && [ -d "$PROD_CREDS" ]; then
  printf '%srefusing to run%s: AGENT_CREDS_DIR resolves to %s\n' "$R" "$N" "$PROD_CREDS" >&2
  printf 'e2e needs its own GitHub App and its own credential directory.\n' >&2
  exit 2
fi

[ -d "$AGENT_CREDS_DIR" ] || skip_tier "no credential directory at $AGENT_CREDS_DIR"
[ -f "$E2E_DIR/.env" ] || skip_tier "no tests/e2e/.env (copy .env.example and fill it in)"

# shellcheck disable=SC1091
set -a; . "$E2E_DIR/.env"; set +a

if [ "$NEEDS_GITHUB" = 1 ]; then
  [ -f "$AGENT_CREDS_DIR/github-app.pem" ] || skip_tier "no github-app.pem in $AGENT_CREDS_DIR"
  for v in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID; do
    [ -n "${!v:-}" ] || skip_tier "$v is empty in tests/e2e/.env"
  done
fi
if [ "$NEEDS_ANTHROPIC" = 1 ]; then
  if [ ! -f "$AGENT_CREDS_DIR/anthropic.key" ] && [ ! -f "$AGENT_CREDS_DIR/anthropic-auth.token" ]; then
    skip_tier "no anthropic.key or anthropic-auth.token in $AGENT_CREDS_DIR"
  fi
fi
if [ "$NEEDS_GITHUB" = 0 ] || [ "$NEEDS_ANTHROPIC" = 0 ]; then
  # Every provider reads its credential lazily, so the broker is healthy
  # without the ones this run does not use — right up until something asks it
  # for a token, which by construction nothing here does.
  printf '%spartial run%s — needs GitHub: %s, needs Anthropic: %s\n' \
    "$Y" "$N" "$([ "$NEEDS_GITHUB" = 1 ] && echo yes || echo no)" \
    "$([ "$NEEDS_ANTHROPIC" = 1 ] && echo yes || echo no)"
fi

if ! docker version >/dev/null 2>&1; then
  printf '%sdocker is unavailable%s — e2e needs it.\n' "$R" "$N" >&2
  exit 2
fi

# ---------------------------------------------------------------- stack up/down

teardown() {
  local rc=$?
  if [ -n "${KEEP_STACK:-}" ]; then
    printf '\n%sKEEP_STACK set%s — stack left running. Tear down with:\n' "$Y" "$N"
    printf '  docker compose -f %s down -v\n' "$E2E_DIR/compose.yaml"
  else
    printf '\n%s── tearing down ──%s\n' "$B" "$N"
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1
  fi
  exit $rc
}
trap teardown EXIT INT TERM

# ------------------------------------------------------------------- staging
#
# The stack under test is assembled here rather than bind-mounted straight out
# of examples/claude-code, because the GCP entry is not in that example — it is
# pinned to v1.2.0, below the image this entry needs — and docker cannot create
# a mountpoint for a single file inside a directory that is itself a read-only
# bind mount. Mounting bank/gcp/broker/gcp.js at /app/providers/gcp.js fails
# with "read-only file system" for exactly that reason.
#
# Rebuilt from scratch on every run, so it is a copy that cannot drift: change
# examples/claude-code or bank/gcp and the next run picks it up.
STAGE="$E2E_DIR/.stage"
printf '%s── assembling the deployment ──%s\n' "$B" "$N"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{broker,proxy,cred-gateway}
cp "$REPO_ROOT"/examples/claude-code/broker/*.js        "$STAGE/broker/"
cp "$REPO_ROOT"/examples/claude-code/proxy/*.py         "$STAGE/proxy/"
cp "$REPO_ROOT"/examples/claude-code/cred-gateway/*.conf "$STAGE/cred-gateway/"
# GCP comes from the bank. 040_ puts it in the provider band, after the
# example's own addons and well clear of 000_policy.py.
cp "$REPO_ROOT/bank/gcp/broker/gcp.js"        "$STAGE/broker/gcp.js"
cp "$REPO_ROOT/bank/gcp/proxy/gcp.py"         "$STAGE/proxy/040_gcp.py"
cp "$REPO_ROOT/bank/gcp/cred-gateway/gcp.conf" "$STAGE/cred-gateway/gcp.conf"
printf '  %d provider(s), %d addon(s), %d snippet(s)\n' \
  "$(find "$STAGE/broker" -name '*.js' | wc -l)" \
  "$(find "$STAGE/proxy" -name '*.py' | wc -l)" \
  "$(find "$STAGE/cred-gateway" -name '*.conf' | wc -l)"

printf '%s── building ──%s\n' "$B" "$N"
# stack/lab is the real base image; tests/e2e/lab extends it with gh. Building
# it here keeps that a reference rather than a copy.
docker build -q -t sat-e2e-devbase "$REPO_ROOT/stack/lab" >/dev/null || {
  printf '%sfailed to build the lab base image%s\n' "$R" "$N" >&2; exit 2; }
"${COMPOSE[@]}" build >/dev/null || {
  printf '%scompose build failed%s\n' "$R" "$N" >&2; exit 2; }

printf '%s── starting stack ──%s\n' "$B" "$N"
if ! "${COMPOSE[@]}" up -d --wait; then
  printf '%sstack did not come up healthy%s\n' "$R" "$N" >&2
  "${COMPOSE[@]}" ps
  "${COMPOSE[@]}" logs --tail 40 broker proxy cred-gateway
  exit 1
fi

# The devcontainer lifecycle scripts do not run here, so do their two essential
# steps by hand: trust the mitmproxy CA and wire the git credential helper.
# Everything downstream (HTTPS through the proxy, git push) depends on these.
printf '%s── preparing lab container ──%s\n' "$B" "$N"
"${COMPOSE[@]}" exec -T lab bash -euo pipefail -c '
  cp /proxy-certs/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
  update-ca-certificates >/dev/null 2>&1
  git config --global credential.helper "!f() { curl -s \"\$GIT_CREDENTIAL_URL\"; }; f"
  git config --global credential.useHttpPath false
  git config --global --add safe.directory "*"
' || { printf '%sdev container preparation failed%s\n' "$R" "$N" >&2; exit 1; }

# ------------------------------------------------------------------- run suites

# cred-gateway rate-limits the credential routes at 10r/m, burst 5 — a real
# control protecting the broker, and one a normal deployment never approaches.
# Suites run back to back do: 10-boundary spends its budget, and 30-git's
# credential helper then receives nginx's 503 page and reports `invalid
# credential line: <html>`, which looks like a credential-helper bug and is
# not one. Let the bucket refill between suites rather than raising the limit,
# so what runs here stays the configuration that ships.
: "${E2E_SUITE_PAUSE:=20}"

failed=()
started=$SECONDS
first=1
for f in "${files[@]}"; do
  name="$(basename "$f" .test.sh)"
  if [ "$first" = 0 ] && [ "$E2E_SUITE_PAUSE" -gt 0 ]; then
    printf '\n%s   … %ss for cred-gateway'"'"'s rate limiter to refill%s\n' "$Y" "$E2E_SUITE_PAUSE" "$N"
    sleep "$E2E_SUITE_PAUSE"
  fi
  first=0
  printf '\n%s┏━ %s %s\n' "$B" "$name" "$N"
  if bash "$f"; then
    printf '%s┗━ %s ok%s\n' "$G" "$name" "$N"
  else
    rc=$?
    printf '%s┗━ %s FAILED (exit %d)%s\n' "$R" "$name" "$rc" "$N"
    failed+=("$name")
  fi
done

elapsed=$((SECONDS - started))
printf '\n%s────────────────────────────%s\n' "$B" "$N"
printf 'ran %d suite(s) in %ds\n' "${#files[@]}" "$elapsed"

if [ "${#failed[@]}" -gt 0 ]; then
  printf '%sfailed: %s%s\n' "$R" "${failed[*]}" "$N"
  exit 1
fi
printf '%sall suites passed%s\n' "$G" "$N"
