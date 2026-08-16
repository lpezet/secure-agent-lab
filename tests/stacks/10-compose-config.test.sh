#!/usr/bin/env bash
# What compose makes of the shapes this repo ships, without building anything.
#
# 00-config-lint reads these files as text. This asks compose itself what they
# mean — which is a different question, and the one that was going unasked: the
# template's `${OBSERVER_PORT-9000}` and `profiles: ["observer"]` shipped in
# 1.10.2 on a reporter's verified output rather than on anything here.
#
# No image builds, no containers, no network. `docker compose config` parses,
# interpolates and validates, then prints. Seconds.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker

# A scratch copy, because these tests write .env and compose reads it from the
# project directory. Never edit the tracked template in place.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; cleanup' EXIT
cp -r template/deployment/. "$WORK/"

# cfg <env-contents> — write .env and print the resolved compose file.
cfg() {
  printf '%s' "$1" > "$WORK/.env"
  (cd "$WORK" && docker compose config 2>/dev/null)
}

# services <env-contents> — the service list compose would actually run.
services() {
  printf '%s' "$1" > "$WORK/.env"
  (cd "$WORK" && docker compose config --services 2>/dev/null | sort | tr '\n' ' ')
}

# observer_ports <env-contents> — just the observer's resolved ports block.
observer_ports() {
  cfg "$1" | awk '/^  observer:/{f=1} f&&/^    ports:/{p=1;next} p&&/^    [a-z]/{exit} p'
}

# ---------------------------------------------------------------- the default
#
# What someone gets by copying the directory and changing nothing. This is the
# behaviour every other case here is defined against, so it goes first.
suite "the shipped defaults"
DEFAULT_ENV=$(cat "$WORK/.env.example")

check_contains "observer binds loopback" "$(observer_ports "$DEFAULT_ENV")" "host_ip: 127.0.0.1"
check_contains "observer publishes 9000" "$(observer_ports "$DEFAULT_ENV")" 'published: "9000"'
check "every service is enabled" \
  "broker cred-gateway lab log-rotator observer proxy " "$(services "$DEFAULT_ENV")"

# ------------------------------------------------------------------- the port
suite "OBSERVER_PORT chooses between a fixed port and an assigned one"
# `${VAR-default}` rather than `${VAR:-default}`: unset takes the default, and
# EMPTY stays empty so Docker assigns a free port. That distinction is the
# whole feature — two deployments on one machine stop colliding without anyone
# choosing and remembering a number per stack (#79).
empty_port=$(observer_ports "COMPOSE_PROFILES=observer
OBSERVER_PORT=")
check_contains "an empty value still binds loopback" "$empty_port" "host_ip: 127.0.0.1"
check_not_contains "an empty value publishes no fixed port" "$empty_port" "published:"

fixed_port=$(observer_ports "COMPOSE_PROFILES=observer
OBSERVER_PORT=9111")
check_contains "an explicit number is honoured" "$fixed_port" 'published: "9111"'

suite "the loopback binding cannot be escaped through the variable"
# The 127.0.0.1 prefix is literal and comes first, so a value trying to widen
# the binding produces a malformed address rather than a wider one. Compose
# refuses the file — which is a better outcome than the file parsing and the
# port landing somewhere unintended.
printf 'COMPOSE_PROFILES=observer\nOBSERVER_PORT=0.0.0.0:9000\n' > "$WORK/.env"
esc=$( (cd "$WORK" && docker compose config 2>&1 >/dev/null) )
check_contains "compose rejects an address-shaped value" "$esc" "invalid IP address"

# --------------------------------------------------------------- the profile
suite "COMPOSE_PROFILES turns the dashboard off without editing the wiring"
# Compose reads an ABSENT COMPOSE_PROFILES as "no profiles enabled". That is
# why .env.example ships the line and 00-config-lint fails if it stops doing
# so: losing the line silently drops the observer (#80).
off=$(services "OBSERVER_PORT=")
check_not_contains "no profile means no observer" "$off" "observer"
check_contains "and the writers stay regardless" "$off" "log-rotator"
check_contains "as does the broker" "$off" "broker"

on=$(services "COMPOSE_PROFILES=observer")
check_contains "the profile turns it back on" "$on" "observer"

# The service is DECLARED either way — it is disabled, not absent. That is what
# makes this reversible without an editor, and it is what `--profiles` reports.
printf 'OBSERVER_PORT=\n' > "$WORK/.env"
declared=$( (cd "$WORK" && docker compose config --profiles 2>/dev/null) )
check_contains "the profile is still declared when disabled" "$declared" "observer"

# ------------------------------------------------------- every shipped shape
#
# The template is the shape under test above; these are the others. A compose
# file that no longer parses is the failure this catches — a rename, a bad
# interpolation, a key compose stopped accepting.
suite "every deployment shape this repo ships resolves"
for dir in template/deployment examples/claude-code examples/dev-container/.devcontainer; do
  [ -f "$dir/compose.yaml" ] || { skip "$dir — no compose.yaml" ""; continue; }
  # Only the compose file and an .env — `config` resolves build contexts as
  # strings and never reads them. Copying the directory would drag in an
  # example's gitignored workspace/, which holds root-owned runtime state.
  d=$(mktemp -d); cp "$dir/compose.yaml" "$d/"
  # lab.env too: compose refuses to parse a file whose env_file is missing,
  # even for a service this suite never starts.
  cp "$dir/lab.env" "$d/" 2>/dev/null || true
  cp "$dir/.env.example" "$d/.env" 2>/dev/null || printf '' > "$d/.env"
  if out=$( (cd "$d" && docker compose config 2>&1 >/dev/null) ) && [ -z "$out" ]; then
    ok "$dir — resolves"
  else
    ko "$dir — compose refuses it" "$out"
  fi
  rm -rf "$d"
done

finish
