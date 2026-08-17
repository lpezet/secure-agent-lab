#!/usr/bin/env bash
# Lab entrypoint: run each installed provider's setup fragment, then hand off to
# the container's command.
#
# A bank entry may ship a `lab_setup` fragment — the lab-side half of installing
# a provider. `bank/github/lab/setup.sh` wires the git credential helper and
# forces `gh` onto HTTPS; `bank/gcp/lab/setup.sh` writes the inert ADC file that
# lets a Google client library's credential chain proceed far enough to make a
# request the proxy can answer. Without somewhere to run them, those two entries
# install into a deployment and do not work.
#
# Fragments are EXECUTED, not sourced. Every effect they have is a file they
# write — a dotfile, an ADC document — and none of them export anything, so a
# child process is sufficient. Sourcing would also put each fragment's
# `set -euo pipefail` into this shell and let a stray `exit` in one of them kill
# the entrypoint. And it would buy nothing even for a fragment that wanted it:
# `docker exec` builds its environment from the container's config, not from
# PID 1, so an export here never reaches an agent that shells in. A fragment
# needing to set an agent-visible variable writes /etc/profile.d/, or the entry
# declares `lab_env` in its manifest.
#
# On start, not on create: adding a provider to a running deployment should be
# a file plus a restart, never a rebuild.
set -euo pipefail

SETUP_DIR="${AGENT_SETUP_DIR:-/etc/agent-setup.d}"

if [ -d "$SETUP_DIR" ]; then
  # LC_COLLATE=C so the order is the bytes in the filename rather than whatever
  # collation the image's locale happens to use, and in a subshell so neither
  # that nor nullglob leaks into the fragments. Nothing shipped today depends on
  # ordering — no two fragments interact — but the order a deployment gets
  # should not be a property of its locale.
  # A `for` over the glob rather than `printf '%s\n' "$dir"/*.sh`: with nullglob
  # and no matches that printf still emits one empty line, which mapfile reads
  # as a single empty entry — an empty directory then "runs" a fragment named ""
  # and the container refuses to start.
  mapfile -t fragments < <(
    shopt -s nullglob
    LC_COLLATE=C
    for f in "$SETUP_DIR"/*.sh; do printf '%s\n' "$f"; done
  )

  if [ "${#fragments[@]}" -gt 0 ]; then
    for f in "${fragments[@]}"; do
      echo "[lab-setup] running $(basename "$f")"
      # Explicit `bash`, so a fragment works regardless of its permission bit.
      # The bank ships one fragment 644 and one 755, and a mount can flatten
      # the difference anyway — an install should not turn on whether someone
      # remembered chmod +x.
      if ! bash "$f"; then
        echo "[lab-setup] FAILED: $(basename "$f") exited non-zero" >&2
        echo "[lab-setup] refusing to start — a provider is installed but not configured." >&2
        exit 1
      fi
    done
  else
    echo "[lab-setup] $SETUP_DIR is empty — no provider fragments to run"
  fi
else
  echo "[lab-setup] no $SETUP_DIR — no provider fragments to run"
fi

# Half-configured is the failure this exists to prevent, so nothing above is
# logged past. Anything that gets here has had every fragment succeed.
if [ "$#" -eq 0 ]; then
  echo "[lab-setup] no command given; nothing to exec" >&2
  exit 1
fi
exec "$@"
