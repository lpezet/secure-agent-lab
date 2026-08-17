#!/usr/bin/env bash
# lab entrypoint: runs each installed provider's lab_setup fragment from
# /etc/agent-setup.d, then hands off to the container's command.
#
# The real lab image is FROM mcr.microsoft.com/devcontainers/typescript-node:22
# — 1.8GB, and this tier is meant to be about a minute. So the entrypoint is
# exercised here in the same container shape (COPY + ENTRYPOINT + CMD, a
# read-only mount at /etc/agent-setup.d) on a small base. The script under test
# is the real stack/lab/entrypoint.sh, byte for byte; what this does not cover
# is stack/lab/Dockerfile actually wiring it up, which 00-config-lint asserts
# statically instead.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker

CTX="/tmp/$RUN_ID-labctx"
mkdir -p "$CTX"
cp stack/lab/entrypoint.sh "$CTX/entrypoint.sh"
# The last block of stack/lab/Dockerfile, on a base that is already local.
cat > "$CTX/Dockerfile" <<'EOF'
FROM bash:5
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /etc/agent-setup.d
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
EOF

IMG="sat-test-lab-entrypoint"
FORCE_BUILD=1 build_image "$IMG" "$CTX" || exit 1

D="/tmp/$RUN_ID-setupd"
mkdir -p "$D"

# run [docker args...] — output and exit code of one container run, command
# replaced by a marker so the handoff is observable.
run_lab() {
  docker run --rm "$@" "$IMG" echo COMMAND-RAN 2>&1
}

suite "nothing mounted over the baked-in directory"
# The Dockerfile mkdir -p's /etc/agent-setup.d, the same "valid unmounted"
# treatment cred-gateway gives /var/log/audit — so in the real image the
# directory always exists and this is the empty case, not the missing one. A
# deployment that never mounts anything still starts.
out=$(run_lab); rc=$?
check "starts and runs the command" "0" "$rc"
check_contains "says it has nothing to run" "$out" "no provider fragments to run"
check_contains "hands off to the command" "$out" "COMMAND-RAN"

suite "the directory genuinely absent"
# Unreachable in the image, and kept for running the script outside one —
# AGENT_SETUP_DIR is what the tests above the container use.
out=$(docker run --rm -e AGENT_SETUP_DIR=/nonexistent "$IMG" echo COMMAND-RAN 2>&1); rc=$?
check "starts and runs the command" "0" "$rc"
check_contains "says the directory is not there" "$out" "no /nonexistent"

suite "an empty fragment directory"
# The bug this catches: `printf '%s\n' dir/*.sh` under nullglob still emits one
# empty line, so an empty directory reads as a single fragment named "" and the
# container refuses to start. A deployment with no lab_setup provider installed
# is the common case, so this is the path most stacks take.
rm -f "$D"/*.sh
out=$(run_lab -v "$D:/etc/agent-setup.d:ro"); rc=$?
check "starts and runs the command" "0" "$rc"
check_contains "says the directory is empty" "$out" "is empty"
check_contains "hands off to the command" "$out" "COMMAND-RAN"

suite "fragments run, in filename order, whatever their mode"
printf '#!/bin/bash\necho FRAGMENT-B\n' > "$D/020_b.sh"
printf '#!/bin/bash\necho FRAGMENT-A\n' > "$D/010_a.sh"
# 644 deliberately: bank/gcp/lab/setup.sh ships non-executable, and a mount can
# flatten the bit anyway. The entrypoint invokes `bash` explicitly so an install
# does not turn on whether someone remembered chmod +x.
chmod 644 "$D/010_a.sh" "$D/020_b.sh"
out=$(run_lab -v "$D:/etc/agent-setup.d:ro"); rc=$?
check "starts and runs the command" "0" "$rc"
check_contains "the 644 fragment ran" "$out" "FRAGMENT-A"
check_contains "the second fragment ran" "$out" "FRAGMENT-B"
order=$(printf '%s\n' "$out" | grep -oE 'FRAGMENT-[AB]' | tr -d '\n')
check "ran in filename order" "FRAGMENT-AFRAGMENT-B" "$order"
check_contains "hands off after the fragments" "$out" "COMMAND-RAN"

suite "a failing fragment stops the container"
# Half-configured is the failure the mechanism exists to prevent: a provider
# installed, its credential wiring absent, and nothing saying so.
printf '#!/bin/bash\nexit 3\n' > "$D/030_fail.sh"
out=$(run_lab -v "$D:/etc/agent-setup.d:ro"); rc=$?
check_ne "exits non-zero" "0" "$rc"
check_contains "names the fragment that failed" "$out" "FAILED: 030_fail.sh"
check_not_contains "never reaches the command" "$out" "COMMAND-RAN"
rm -f "$D/030_fail.sh"

suite "the fragment directory is mounted read-only"
# A fragment can already do anything the lab can do. What it must not do is
# persist a change back into the deployment it was installed from.
printf '#!/bin/bash\ntouch /etc/agent-setup.d/999_written.sh 2>/dev/null && echo WROTE || echo READONLY\n' \
  > "$D/040_write.sh"
out=$(run_lab -v "$D:/etc/agent-setup.d:ro")
check_contains "a fragment cannot write into it" "$out" "READONLY"
check "nothing was created on the host" "0" "$(ls "$D"/999_written.sh 2>/dev/null | wc -l)"
rm -f "$D/040_write.sh"

rm -rf "$D" "$CTX"
docker image rm -f "$IMG" >/dev/null 2>&1
finish
