#!/usr/bin/env bash
# The audit trail, produced by real credentials rather than markers.
#
# `35-audit-leak` in the integration tier already proves the trail's *shape*:
# it taints every channel a secret can arrive on and scans for the taints. What
# only this tier can add is that the trail describes **real** issued authority
# correctly — that `permissions` names what a live installation actually
# grants, and that a token which really exists never appears beside it.
#
# Runs last on purpose, so it also sees whatever the earlier suites provoked.
# It provokes its own events first regardless, so `tests/e2e/run.sh 50` on its
# own still has something to assert about.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

# GCP shapes too — this suite reads a trail every provider may have written to.
SECRET_PATTERNS+=(
  'ya29\.[A-Za-z0-9_.-]{20,}'
  '1//[A-Za-z0-9_-]{20,}'
)

suite "the trail exists at all"
# Guards against a vacuous pass. Every absence asserted below is also what an
# empty trail looks like, and this tier wired no trail whatsoever until #51 —
# so prove it is live before trusting anything that reads it.
lab_sh 'curl -s -o /dev/null "$GIT_CREDENTIAL_URL"' >/dev/null
lab_sh 'gh api /rate_limit >/dev/null 2>&1' >/dev/null

trail=$(audit_trail)
check_ne "the shared trail is not empty" "" "$trail"
check "broker wrote to it" "1" "$(audit_has "$trail" service broker)"
check "proxy wrote to it" "1" "$(audit_has "$trail" service proxy)"
check "cred-gateway wrote to it" "1" "$(audit_has "$trail" service cred-gateway)"

suite "the trail names what a real token can do"
# #43's whole point, and the thing that was unavailable here when a real `git
# push` 403'd during #41: the answer to "what can this lab currently do to
# GitHub" should come from reading the trail, not from opening GitHub settings.
broker=$(audit_trail broker)
check "an issue was recorded" "1" "$(audit_has "$broker" event token_issued)"
check_contains "carrying the permissions map" "$broker" '"permissions"'
check_contains "and the repository scope" "$broker" '"repository_selection"'

# `all` or `selected` — the enum, not repository names. Names stay out
# deliberately: observer serves this over HTTP and the enum already answers
# whether the installation is org-wide.
sel=$(audit_field "$broker" repository_selection | sort -u | head -1)
case "$sel" in
  all|selected) ok "repository_selection is a valid enum ($sel)" ;;
  *) ko "repository_selection is not a valid enum" "got: ${sel:-<none>}" ;;
esac
check_not_contains "no repository names in the trail" "$broker" "$E2E_TEST_REPO"

# The credential route is what `git push` travels. Leaving it unaudited would
# make the most-used path the least visible.
check "the credential route reports scope too" "1" "$(audit_has "$broker" event credential_issued)"

# What this cannot do: cross-check against GitHub's own view of the
# installation. That needs the App JWT, which only the broker holds — so this
# asserts the field is present, well-formed and internally consistent, and
# leaves "is it telling the truth" to 45-broker-github-scope, which controls
# both sides.

suite "the proxy records what it injected, and for whom"
proxy=$(audit_trail proxy)
check "an injection was recorded" "1" "$(audit_has "$proxy" event token_injected)"
check "naming the provider" "1" "$(audit_has "$proxy" provider github)"
check_not_contains "and no raw request path" "$proxy" '"path":"/rate_limit?'

suite "cred-gateway records the credential-helper request"
gw=$(audit_trail cred-gateway)
check_contains "a request was recorded" "$gw" '/github/credential'
check_not_contains "but not the healthcheck" "$gw" '/healthz'

suite "no live credential appears anywhere in the trail"
# The assertion this suite exists for. 35-audit-leak proves this against
# planted markers; here the tokens are real, so a regression that starts
# logging a value has something genuine to leak. check_no_secret reports the
# pattern and a byte offset and never the haystack.
trail=$(audit_trail)
check_no_secret "no credential shape in the whole trail" "$trail" "${SECRET_PATTERNS[@]}"

# The App private key and the ADC's refresh token live on the broker side and
# must never reach a file observer serves over HTTP.
check_no_secret "no key material either" "$trail" \
  'BEGIN [A-Z ]*PRIVATE KEY' 'MII[A-Za-z0-9+/]{40,}'

suite "the trail is a file the whole stack can write"
# broker (node), proxy (mitmproxy) and cred-gateway (nginx) are three
# different non-root uids writing one directory. log-rotator's entrypoint
# chmods it on every start, and without that the trail is silently empty for
# whichever uid loses — a failure that looks exactly like "nothing happened".
perms=$("${COMPOSE[@]}" exec -T log-rotator stat -c '%a' /var/log/audit 2>/dev/null | tr -d '\r')
check "the shared directory is world-writable with the sticky bit" "1777" "$perms"

finish
