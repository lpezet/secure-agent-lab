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

if [ -z "${GCP_SERVICE_ACCOUNT:-}" ] || [ -z "${GCP_PROJECT:-}" ]; then
  suite "gcp"
  skip "GCP_PROJECT / GCP_SERVICE_ACCOUNT not set in tests/e2e/.env" "see README → GCP"
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
# The whole point of impersonation, confirmed by the vendor rather than by us.
#
# Nothing here ever puts the token in a shell variable. cred-gateway hands it
# to the lab, the lab spends it, and only the parsed answer comes back — so a
# failing assertion cannot dump a live credential into the terminal or a CI
# log, which is a property no amount of check_no_secret would give.
served=$(lab_sh 'curl -s -o /dev/null -w "%{http_code}" "$GCP_TOKEN_URL"')
check "cred-gateway serves /gcp/token" "200" "$served"

# tokeninfo takes the token in the query string, so this runs inside the lab.
# Fields only: `azp` is the principal, `scope` is what it may do.
info=$(lab_sh '
  t=$(curl -s "$GCP_TOKEN_URL" | sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p")
  curl -s "https://oauth2.googleapis.com/tokeninfo?access_token=$t" \
    | tr -d " \n" | grep -oE "\"(azp|aud|scope|error[^\"]*)\":\"[^\"]*\"" || echo "NO-FIELDS"
')
check_contains "Google recognises the token" "$info" "azp"
check_contains "and scopes it to cloud-platform" "$info" "cloud-platform"

# A service-account token reports its principal as a NUMERIC id. `email`
# appears only on user tokens carrying the email scope, so asserting on the
# address would fail against a perfectly good token — which is exactly what it
# did before this was measured.
if [ -n "${GCP_SA_UNIQUE_ID:-}" ]; then
  check_contains "the principal is the configured service account" \
    "$info" "$GCP_SA_UNIQUE_ID"
else
  skip "identity check" "GCP_SA_UNIQUE_ID not set — re-run: tests/e2e/run.sh setup gcp --yes"
fi

suite "the proxied path authenticates without the lab holding a credential"
# The client sends the inert placeholder and the addon swaps it in flight.
# Asserting "not 401" rather than "200" keeps this true whatever roles the
# service account was given — an unauthenticated call would be 401, so
# anything else proves a real credential was attached.
# The project the service account lives in — it exists by construction, so
# there is nothing extra to configure. Which answer comes back depends on the
# SA's roles and does not matter: 403 means Google authenticated it and denied
# it, 200 means it was allowed, and only an unauthenticated call gets 401.
code=$(lab_sh "
  curl -s -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer proxy-injected' \
    'https://cloudresourcemanager.googleapis.com/v1/projects/$GCP_PROJECT'
")
check_ne "an injected call is not rejected as unauthenticated" "401" "$code"
check_ne "and did not fail to connect" "000" "$code"

# What comes back separates authentication from authorization, and the second
# is the property worth having. The operator CAN read this project — it is
# where they just created the service account — so if the broker had handed
# over the operator's own token this would be a 200. A 403 is the impersonated
# identity being told no, which is the narrowing working.
#
# Not asserted as 403, because it depends on roles the deployment chose: a
# service account granted viewer legitimately returns 200. `setup gcp` creates
# one with none, so that is the usual case, and it is worth naming either way.
case "$code" in
  403) ok "403: authorization is bounded by the SA's roles, not the operator's" ;;
  200) ok "200: the SA has been granted read on $GCP_PROJECT" ;;
  *)   ok "HTTP $code: authenticated (any non-401 proves the injection)" ;;
esac

suite "the token exchange is answered locally, with an inert value"
# A client library's credential chain ends here. If this ever returns a real
# token, the lab is holding a live GCP credential on the proxied path — the
# design decision recorded in #41, asserted rather than assumed.
body=$(lab_sh 'curl -s -X POST "https://sts.googleapis.com/v1/token" -d "grant_type=x"')
check_contains "the exchange is answered" "$body" "access_token"
check_contains "with the inert placeholder" "$body" "proxy-injected"
check_no_secret "and never a real token" "$body" "${SECRET_PATTERNS[@]}"

suite "the audit trail describes the authority, never the credential"
# The trail, not stdout. These asserted on `docker compose logs broker` until
# #51 wired an audit-logs volume into this tier, which worked but checked the
# wrong surface: stdout is not what observer serves, and the two carry
# deliberately different detail.
trail=$(audit_trail broker)
check "an issue was recorded for gcp" "1" "$(audit_has "$trail" provider gcp)"
check "naming the service account it issued for" "1" \
  "$(audit_has "$trail" service_account "$GCP_SERVICE_ACCOUNT")"
check_contains "and when it expires" "$trail" '"expires_at"'
# Which credential shape produced it — two deployments issuing the same
# authority by different means have different failure modes.
check "recording the credential shape" "1" "$(audit_has "$trail" source impersonation)"
check_no_secret "no credential shape reached the trail" "$trail" "${SECRET_PATTERNS[@]}"

finish
