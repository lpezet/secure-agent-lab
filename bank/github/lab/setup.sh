#!/bin/bash
# GitHub — lab-side setup fragment.
#
# Executed by the lab image's entrypoint, from /etc/agent-setup.d, on every
# start. Runs INSIDE the lab container, which is the untrusted side already:
# nothing here can do anything the lab could not already do. That is the whole
# reason a bank entry is allowed to ship shell.
#
# Executed, not sourced — so write files rather than exporting variables, and
# keep it idempotent, because it runs again on every restart.
#
# This file exists so that installing GitHub does not require separately knowing
# to set `credential.useHttpPath false`. If that knowledge lived in the playbook
# instead, a bank entry would not be self-sufficient and an installer would need
# per-provider code of its own.
set -euo pipefail

echo "[setup:github] configuring git credential helper..."
git config --global credential.helper "!f() { curl -s \"\$GIT_CREDENTIAL_URL\"; }; f"

# Not a bug, and not a nicety. Git includes the repository path in the
# credential lookup key when this is true, so the helper is re-invoked per
# path and the cred-gateway sees one request per repo rather than one per
# host. The gateway route is exact-match and path-agnostic; leaving this on
# produces lookups the helper cannot satisfy.
git config --global credential.useHttpPath false

# Stop gh from reaching for SSH, which leaves the HTTPS proxy path entirely and
# so bypasses credential injection. With GH_TOKEN set, gh does not write
# ~/.config/gh/hosts.yml, so this has to be set explicitly.
gh config set --host github.com git_protocol https

echo "[setup:github] ok"
