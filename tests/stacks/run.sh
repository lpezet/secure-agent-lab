#!/usr/bin/env bash
# Stacks tier: the deployment shapes this repo ships, exercised rather than read.
#
#   tests/run.sh stacks          # everything
#   tests/run.sh stacks 10       # only suites starting with 10
#   KEEP_STACK=1 …               # leave containers up afterwards to poke at
#
# Free — no credentials, no quota, nothing published. Not fast: the boundary
# band builds this repo's images from a pinned tag, which is minutes on a cold
# cache. That is the only reason it is not in the bare `tests/run.sh` default.
#
# Exit code is non-zero if any suite fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; B=''; N=''
fi

files=()
if [ $# -gt 0 ]; then
  for pat in "$@"; do
    for f in "$TESTS_DIR/$pat"*.test.sh; do [ -f "$f" ] && files+=("$f"); done
  done
else
  for f in "$TESTS_DIR"/*.test.sh; do [ -f "$f" ] && files+=("$f"); done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "no test files matched" >&2
  exit 2
fi

if ! docker version >/dev/null 2>&1; then
  echo "${R}docker is unavailable.${N} Every suite in this tier needs it." >&2
  echo "On WSL: Docker Desktop → Settings → Resources → WSL Integration." >&2
fi

failed=()
started=$SECONDS

for f in "${files[@]}"; do
  name="$(basename "$f" .test.sh)"
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
