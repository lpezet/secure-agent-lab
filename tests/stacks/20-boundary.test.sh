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
teardown() {
  # Derived from $WORK rather than from a list `up` appends to. `up` prints the
  # project directory on stdout, so every caller invokes it as `$(up ...)` — a
  # command substitution, which is a subshell, so an array appended to inside it
  # never reaches this function. That is not a hypothetical: this suite shipped
  # `PROJECTS+=("$dir")` inside `up`, the array was empty here on every run, and
  # `docker compose down -v` never ran once. Nothing under $WORK is anything but
  # a project this suite created, so the filesystem is the more honest list.
  #
  # `--rmi local` because compose tags what it builds `<project>-<service>`, and
  # the project name carries $$ — so the tag is unique per run and can never be
  # reused by the next one. Keeping it therefore buys nothing at all, which is
  # the whole argument: the images looked expensive to rebuild and were not.
  # `docker rmi` drops the tag, not the build cache, so the next run rebuilds
  # from cache and pays nothing: two consecutive full runs measured 93s and 98s,
  # the second starting with every image removed by the first. `local` is scoped
  # to services with no `image:` key — every service in these compose files —
  # and to this project alone.
  if [ "${KEEP_STACK:-0}" != "1" ]; then
    for p in "$WORK"/*/; do
      [ -f "$p/compose.yaml" ] || continue
      (cd "$p" && docker compose down -v --rmi local --remove-orphans >/dev/null 2>&1)
    done
    rm -rf "$WORK"
  else
    # KEEP_STACK is for poking at the running stacks afterwards, which needs
    # their compose files to still exist — `docker compose logs` against a
    # deleted project directory is not a thing. The old code skipped the
    # teardown and deleted $WORK anyway.
    printf '  KEEP_STACK=1 — stacks left up, project files in %s\n' "$WORK"
  fi
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
  # Volumes too. Containers and networks were swept and volumes were not, so a
  # run that died without teardown leaked its volumes permanently — one machine
  # here had 111 of them from 28 runs. They are small (near-empty audit logs and
  # a CA cert), so this never showed up as disk pressure; it just grew forever.
  # `docker volume rm` refuses a volume still in use, which is the backstop
  # against removing one belonging to a run in progress.
  for v in $(docker volume ls --format '{{.Name}}' 2>/dev/null | grep '^sattest-' || true); do
    case "$v" in *"$mine"*) continue ;; esac
    docker volume rm "$v" >/dev/null 2>&1
  done
  # And the images compose built, for the same kill -9 case. Last, because
  # `docker rmi` refuses an image a container still uses and the containers
  # above have to be gone first.
  #
  # `^sattest-` and NOT `^sat-test-`: one hyphen apart and they are different
  # things. These are run-scoped (`sattest-<pid>-<shape>-<service>`) and grow
  # without bound — 237 had accumulated over 28 run ids. The integration tier's
  # are fixed-name (`sat-test-proxy`), deliberately reused across runs as a
  # build cache, and there are at most a handful. Widening this anchor would
  # silently turn every stacks run into a full rebuild of the other tier.
  for i in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^sattest-' || true); do
    case "$i" in *"$mine"*) continue ;; esac
    docker rmi "$i" >/dev/null 2>&1
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
  # compose refuses to parse a file whose env_file is missing, even for the
  # lab service this suite deliberately never starts.
  cp "$src/lab.env" "$dir/" 2>/dev/null || true
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
  # stderr, not stdout: this function's stdout is the project directory.
  printf '  building and starting %s (from its pinned tag — minutes on a cold cache)\n' "$name" >&2
  # `up -d` then poll, rather than `up -d --wait`. --wait obeys each service's
  # own healthcheck budget, and those are the SHIPPED ones — the broker allows
  # 30s (5s start_period, 5 retries at 5s). That is generous for one stack on
  # an idle machine and tight for the third stack on a loaded CI box, which
  # made this flake. Widening the healthchecks would change the artefact under
  # test to suit the test; polling here does not.
  if ! (cd "$dir" && docker compose up -d "${SERVICES[@]}" >/dev/null 2>&1); then
    return 1
  fi
  local i states
  for i in $(seq 1 90); do   # 180s
    states=$(cd "$dir" && docker compose ps --format '{{.Service}}:{{.Health}}' 2>/dev/null)
    # Every named service reporting healthy, and none reporting otherwise.
    if [ "$(printf '%s\n' "$states" | grep -c ':healthy$')" = "${#SERVICES[@]}" ]; then
      break
    fi
    case "$states" in *:unhealthy*) return 1 ;; esac
    sleep 2
  done
  [ "$(printf '%s\n' "$states" | grep -c ':healthy$')" = "${#SERVICES[@]}" ] || return 1
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

# pinned_tag_missing <src-dir> — true when the shape pins a release tag that
# does not exist on the remote yet.
#
# This is not hypothetical, and it happens every release: the template must
# name the version being cut (00-config-lint fails if it lags), but that tag is
# only created AFTER the release PR merges. So on a release branch the template
# pins a ref nothing can build from, for exactly as long as the PR is open.
#
# Skipped rather than failed, and only for a tag that is genuinely absent — a
# typo, or a pin to something that never existed, still fails the build below.
pinned_tag_missing() {
  local tag
  tag=$(grep -ohE 'secure-agent-lab\.git#v[0-9]+\.[0-9]+\.[0-9]+' "$1/compose.yaml" 2>/dev/null \
        | head -1 | sed 's/.*#//')
  [ -n "$tag" ] || return 1
  # Only trust an ls-remote that actually answered: no network must not read as
  # "no tag", or an offline run would skip everything and call it a pass.
  local out
  out=$(git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null) || return 1
  [ -z "$out" ] && { printf '%s' "$tag"; return 0; }
  return 1
}

check_shape() { # check_shape <label> <src-dir>
  local label="$1" src="$2" dir proj missing
  suite "$label — the stack comes up from its own compose file"

  if missing=$(pinned_tag_missing "$src"); then
    skip "$label — pins $missing, which is not tagged yet" \
         "expected while a release PR is open; the tag is cut after it merges"
    return
  fi

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
  # It must be the POLICY addon that refused, not merely some 403.
  #
  # Until 1.11.2 this accepted either message, because on a shape with an
  # enforcing allowlist 001_allowlist.py ran second and overwrote the policy
  # response (#87). That is fixed, every shape pins past it, and leaving the
  # check permissive would mean a regression of #87 passed here in silence —
  # which is the failure mode this repo keeps finding in itself.
  refusal=$(probe_body "$proj" --proxy "http://proxy:8080" "http://broker:8080/github/token")
  check_contains "$label — refused by the policy addon, specifically" \
    "$refusal" "internal host blocked"

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
