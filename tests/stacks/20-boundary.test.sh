#!/usr/bin/env bash
# Bring each shipped deployment shape up, from its own compose file, and check
# the boundary holds.
#
# What this reaches that nothing else does: the images are built from the tag
# the deployment PINS, by compose, wired by that deployment's own file. The
# integration tier proves the same properties against hand-built containers on
# a hand-made network — which is the right way to test an addon and says
# nothing about whether a repin landed.
#
# The assertions are the credential-free subset of the checks each example's
# README already documents, so this proves those READMEs true rather than
# inventing a second set.
#
# NO credentials. The broker comes up with an empty /secrets and serves 404 on
# every credential route; the boundary does not depend on any of them existing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker

# `lab` is deliberately never started. Its image is a slow local build, and its
# setup.sh fetches a GitHub App identity — it is SUPPOSED to fail without
# credentials. The three services that carry the boundary all declare
# healthchecks, so `--wait` is a real gate rather than a sleep.
SERVICES=(broker proxy cred-gateway)

WORK=$(mktemp -d)
PROJECTS=()
teardown() {
  for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do
    [ "${KEEP_STACK:-0}" = "1" ] && continue
    (cd "$p" && docker compose down -v --remove-orphans >/dev/null 2>&1)
  done
  rm -rf "$WORK"
  cleanup
}
# INT and TERM as well as EXIT: an interrupted run that skips teardown leaves
# two networks per shape behind, and Docker's default address pools are finite.
# Enough abandoned runs and the NEXT one fails with "all predefined address
# pools have been fully subnetted" — which looks like a broken stack and is
# not. Six leaked networks per run gets there faster than you would think.
trap teardown EXIT INT TERM

# A kill -9 cannot be trapped, so also sweep anything this suite left behind
# previously. Scoped to our own prefix and never to the current run, so it can
# never touch a stack the developer has up.
sweep_stale() {
  local mine="$RUN_ID" c n
  for c in $(docker ps -aq --filter "name=^sattest-" 2>/dev/null); do
    n=$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null)
    case "$n" in *"$mine"*) continue ;; esac
    docker rm -f "$c" >/dev/null 2>&1
  done
  for n in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep '^sattest-' || true); do
    case "$n" in *"$mine"*) continue ;; esac
    docker network rm "$n" >/dev/null 2>&1
  done
}
sweep_stale

# up <name> <dir> — copy a shape into scratch, start it, print the project dir.
# Returns non-zero if it never became healthy.
up() {
  # Two statements, not one: word expansion happens before `local` runs, so
  # `local name=$1 dir=$WORK/$name` reads an unset `name` under `set -u`.
  local name="$1" src="$2"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  cp "$src/compose.yaml" "$dir/"
  cp "$src/.env.example" "$dir/.env" 2>/dev/null || printf '' > "$dir/.env"
  # The three mount points, plus the allowlist data file, because the boundary
  # is partly made of what they contain — an unmounted cred-gateway/ would 403
  # everything and look like a passing test for the wrong reason.
  #
  # Named explicitly rather than copying the directory: an example also holds a
  # gitignored workspace/ of root-owned runtime state, and lab/, which is the
  # one image this suite deliberately never builds.
  local item
  for item in broker proxy cred-gateway allowlist; do
    [ -e "$src/$item" ] && cp -r "$src/$item" "$dir/"
  done
  # A project name per shape, so two of these never collide with each other or
  # with a real stack the developer has running.
  printf 'COMPOSE_PROJECT_NAME=%s\n' "$RUN_ID-$name" >> "$dir/.env"
  PROJECTS+=("$dir")
  # stderr, not stdout: this function's stdout is the project directory.
  printf '  building and starting %s (from its pinned tag — minutes on a cold cache)\n' "$name" >&2
  if ! (cd "$dir" && docker compose up -d --wait "${SERVICES[@]}" >/dev/null 2>&1); then
    return 1
  fi
  printf '%s' "$dir"
}

# The network name compose gives a project is <project>_<network>. Derive it
# rather than parsing, so a rename of the network key is caught by the tests
# failing to connect rather than by a silent skip.
lab_net() { printf '%s_lab' "$1"; }

# probe <project> <curl args...> — status code from the lab network.
probe() {
  local proj="$1"; shift
  docker run --rm --network "$(lab_net "$proj")" curlimages/curl:latest \
    -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null
}

# probe_body <project> <curl args...>
probe_body() {
  local proj="$1"; shift
  docker run --rm --network "$(lab_net "$proj")" curlimages/curl:latest \
    -s --max-time 5 "$@" 2>/dev/null
}

check_shape() { # check_shape <label> <src-dir>
  local label="$1" src="$2" dir proj
  suite "$label — the stack comes up from its own compose file"

  if ! dir=$(up "$label" "$src"); then
    ko "$label — services did not become healthy" \
       "$(cd "$WORK/$label" 2>/dev/null && docker compose logs --tail 25 2>&1 | tail -25)"
    return
  fi
  proj="$RUN_ID-$label"
  ok "$label — broker, proxy and cred-gateway are healthy"

  suite "$label — the broker is unroutable from the lab network"
  # Not firewalled off: it is on `secure` only, so the name does not resolve
  # and there is no path to the address. Every other control is defence in
  # depth behind this one. curl exits 6 (no host) and reports 000.
  check "direct GET to the broker fails" "000" \
    "$(probe "$proj" "http://broker:8080/healthz")"

  suite "$label — the proxy refuses to forward to an internal host"
  # From the IMAGE since v1.10.0, with no 000_policy.py in the deployment at
  # all. That is what #62 changed and what an empty proxy/ used to lose.
  check "GET broker through the proxy is blocked" "403" \
    "$(probe "$proj" --proxy "http://proxy:8080" "http://broker:8080/github/token")"
  # The BODY, not just the code. Without the policy addon the request reaches
  # the broker and comes back 500 for want of credentials — not 403, and with a
  # body holding no token, so a check written only against those would pass
  # while the block was gone. Assert the refusal came from the PROXY.
  #
  # Either proxy refusal counts. Both addons deny an internal host and
  # 001_allowlist.py runs second, so on a shape whose allowlist is enforcing —
  # the template, which ships the file with no entries — its message overwrites
  # the policy addon's. The block is not weaker for that: the allowlist only
  # sets a response when it denies, so when it permits a host the policy 403
  # stands. What changes is which reason the audit trail records.
  refusal=$(probe_body "$proj" --proxy "http://proxy:8080" "http://broker:8080/github/token")
  case "$refusal" in
    *"internal host blocked"*)         ok "$label — refused by the policy addon" ;;
    *"blocked by allowlist policy"*)   ok "$label — refused by the allowlist addon (enforcing, denies broker too)" ;;
    *) ko "$label — the refusal did not come from the proxy" "$refusal" ;;
  esac
  # The two bypasses that shipped and were fixed: a spoofed Host header (1.6.0)
  # and an uppercased hostname (1.9.2).
  check "a spoofed Host does not bypass it" "403" \
    "$(probe "$proj" --proxy "http://proxy:8080" -H "Host: example.com" "http://broker:8080/github/token")"
  check "an uppercased hostname does not bypass it" "403" \
    "$(probe "$proj" --proxy "http://proxy:8080" "http://BROKER:8080/github/token")"

  suite "$label — cred-gateway exposes exactly what it declares"
  check "a raw-credential route is denied" "403" \
    "$(probe "$proj" "http://cred-gateway/anthropic/cred")"
  check "so is the raw GitHub token route" "403" \
    "$(probe "$proj" "http://cred-gateway/github/token")"
  # What is exposed depends on what the shape installed, and both directions
  # are worth asserting.
  #
  # A shape that vendors github.conf must serve that route — whatever the
  # broker answers with no credentials configured, a 403 would mean the
  # whitelist snippet stopped being mounted.
  #
  # A shape that vendors nothing must expose nothing. That is the template with
  # no bank entry installed, and it is the correct degenerate case rather than
  # a gap: cred-gateway's default-deny is baked into the image, so a deployment
  # gets it without opting in.
  if [ -f "$src/cred-gateway/github.conf" ]; then
    check_ne "the credential-helper route it vendors is not denied" "403" \
      "$(probe "$proj" "http://cred-gateway/github/credential")"
  else
    check "with no snippet vendored, nothing is exposed" "403" \
      "$(probe "$proj" "http://cred-gateway/github/credential")"
  fi
}

check_shape "template" "template/deployment"
check_shape "claude-code" "examples/claude-code"
check_shape "dev-container" "examples/dev-container/.devcontainer"

finish
