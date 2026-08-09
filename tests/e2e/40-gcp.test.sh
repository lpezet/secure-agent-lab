#!/usr/bin/env bash
# GCP, against a real service account.
#
# The claim this suite exists to test is the one that decides blast radius:
# **the agent's authority is exactly the impersonated service account's IAM
# roles.** Nothing else in the tier can check that, because it needs Google to
# say whose token it is looking at.
#
# Skips when GCP is not configured. It is optional within an optional tier —
# the rest of e2e must keep running for someone who has a GitHub App but no
# Google project. See README for the four gcloud commands that set it up.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

if [ -z "${GCP_SERVICE_ACCOUNT:-}" ]; then
  suite "gcp"
  skip "GCP_SERVICE_ACCOUNT is not set in tests/e2e/.env" "see README → GCP"
  finish
fi
if [ ! -f "$AGENT_CREDS_DIR/gcp-adc.json" ]; then
  suite "gcp"
  skip "no gcp-adc.json in $AGENT_CREDS_DIR" "see README → GCP"
  finish
fi

# A live access token. Never echoed: check_no_secret is the assertion for
# anything derived from it, and the token itself only ever moves between
# containers or into a variable that is matched, not printed. Appended to the
# shapes e2e-lib.sh already knows rather than replacing them, so the GCP shapes
# are checked here and everywhere else keeps its own.
SECRET_PATTERNS+=(
  'ya29\.[A-Za-z0-9_.-]{20,}'   # OAuth2 access token
  '1//[A-Za-z0-9_-]{20,}'       # OAuth2 refresh token
)

suite "the broker mints for the configured service account, not the operator"
# The whole point of impersonation. Google's tokeninfo reports the principal a
# token belongs to, so this is the vendor confirming that the identity handed
# out is the service account rather than the human whose refresh token the
# broker holds.
tok=$(lab_sh 'curl -s "$GCP_TOKEN_URL"')
check_contains "cred-gateway serves /gcp/token" "$tok" "token"
check_no_secret "the token is not echoed by this suite" "$tok" "${SECRET_PATTERNS[@]}"

# tokeninfo takes the token in the query string, so this runs inside the lab
# and only its parsed answer comes back out.
info=$(lab_sh '
  t=$(curl -s "$GCP_TOKEN_URL" | sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p")
  curl -s "https://oauth2.googleapis.com/tokeninfo?access_token=$t"
')
check_contains "Google recognises the token" "$info" "email"
check_contains "and it belongs to the configured service account" \
  "$info" "$GCP_SERVICE_ACCOUNT"
check_not_contains "it is not a gserviceaccount-shaped lie about a user" \
  "$info" "accounts.google.com"

suite "the proxied path authenticates without the lab holding a credential"
# The client sends the inert placeholder and the addon swaps it in flight.
# Asserting "not 401" rather than "200" keeps this true whatever roles the
# service account was given — an unauthenticated call would be 401, so
# anything else proves a real credential was attached.
code=$(lab_sh '
  curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer proxy-injected" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${GCP_TEST_PROJECT:-nonexistent-project}"
')
check_ne "an injected call is not rejected as unauthenticated" "401" "$code"
check_ne "and did not fail to connect" "000" "$code"

suite "the token exchange is answered locally, with an inert value"
# A client library's credential chain ends here. If this ever returns a real
# token, the lab is holding a live GCP credential on the proxied path — the
# design decision recorded in #41, asserted rather than assumed.
body=$(lab_sh 'curl -s -X POST "https://sts.googleapis.com/v1/token" -d "grant_type=x"')
check_contains "the exchange is answered" "$body" "access_token"
check_contains "with the inert placeholder" "$body" "proxy-injected"
check_no_secret "and never a real token" "$body" "${SECRET_PATTERNS[@]}"

suite "the audit trail describes the authority, never the credential"
trail=$(svc_logs broker)
check_contains "the broker recorded an issue for gcp" "$trail" "gcp"
check_contains "naming the service account it issued for" "$trail" "$GCP_SERVICE_ACCOUNT"
check_no_secret "no credential shape reached the log" "$trail" "${SECRET_PATTERNS[@]}"

finish
