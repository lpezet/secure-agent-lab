#!/usr/bin/env bash
# --secrets-dir: is the credential's principal a machine, or the operator?
#
# The mitigation is only as strong as its setup. Dropping a personal access
# token into the secrets directory leaves value isolation intact — the agent
# still never reads it — and destroys authority isolation, because the agent
# now acts as the human across everything that human can reach. Only the second
# depends on what is in that directory, and it is the one that sets blast
# radius.
#
# THE ASSERTION THIS SUITE EXISTS FOR is the last one: that no credential value
# ever reaches stdout. This is the only check in the project that reads real
# secrets, so a leak here would be worse than the misconfiguration it looks
# for. The fixtures are deliberately credential-shaped — a real RSA key, a
# real-looking PAT, a refresh token — so that assertion has something to catch.
#
# No docker. Every fixture is built here and deleted on exit.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

INV_SH="$REPO_ROOT/scripts/check-invariants.sh"
DEPLOY="$REPO_ROOT/examples/dev-container/.devcontainer"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"; cleanup' EXIT

# Built at runtime, never committed: a credential-shaped literal in a tracked
# file would trip 00-config-lint's repo-wide sweep, and the honest fix is not
# to put one in the repo.
FAKE_PAT="ghp_$(printf 'a%.0s' $(seq 30))"
FAKE_REFRESH="1//0g$(printf 'b%.0s' $(seq 30))"
FAKE_ANT="sk-ant-api03-$(printf 'c%.0s' $(seq 40))"

secrets() { printf '%s' "$TMPD/$1"; }

mkdir -p "$(secrets human)" "$(secrets machine)" "$(secrets mixed)"

# --- human principals -------------------------------------------------------
printf '%s' "$FAKE_PAT" > "$(secrets human)/github.token"
cat > "$(secrets human)/gcp-adc.json" <<EOF
{"type":"authorized_user","client_id":"x.apps.googleusercontent.com",
 "client_secret":"s","refresh_token":"$FAKE_REFRESH"}
EOF

# --- machine principals -----------------------------------------------------
openssl genrsa -out "$(secrets machine)/github-app.pem" 2048 >/dev/null 2>&1
cat > "$(secrets machine)/gcp-adc.json" <<'EOF'
{"type":"impersonated_service_account",
 "service_account_impersonation_url":"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/a@b.iam.gserviceaccount.com:generateAccessToken",
 "source_credentials":{"type":"authorized_user"}}
EOF
cat > "$(secrets machine)/gcp-key.json" <<'EOF'
{"type":"service_account","client_email":"a@b.iam.gserviceaccount.com","private_key_id":"k"}
EOF

# --- a realistic mix --------------------------------------------------------
cp "$(secrets machine)/github-app.pem" "$(secrets mixed)/github-app.pem"
printf '%s' "$FAKE_ANT" > "$(secrets mixed)/anthropic.key"
printf 'not-a-recognisable-shape-at-all' > "$(secrets mixed)/custom.token"

run() { bash "$INV_SH" --secrets-dir "$1" "$DEPLOY" 2>&1; echo "EXIT=$?"; }

suite "a human principal is a failure, and says which file"
out=$(run "$(secrets human)")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "names the rule" "$out" "principal is the human operator"
check_contains "flags the personal access token" "$out" "github.token"
check_contains "flags the bare authorized_user ADC" "$out" "gcp-adc.json"

suite "a machine principal is silent"
# An App key, an impersonated ADC and a service-account key file are all
# machines. #41 made the last of those legitimate; before it, a key file was
# the shape this stack told you to avoid rather than one it accepts.
out=$(run "$(secrets machine)")
check_contains "exits 0" "$out" "EXIT=0"
check_not_contains "no principal finding" "$out" "principal is the human operator"

suite "the ADC type is read at the top level, not the first one in the file"
# The bug this caught, found against a real ~/.config/gcloud file rather than a
# fixture. An impersonated ADC nests the credential that does the impersonating,
# and gcloud writes keys alphabetically — so `source_credentials.type:
# authorized_user` appears BEFORE the top-level type. Reading the first match
# calls the safest shape this stack supports the operator's own identity, on
# every deployment that uses it.
mkdir -p "$(secrets order)"
cat > "$(secrets order)/gcp-adc.json" <<EOF
{
  "delegates": [],
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/a@b.iam.gserviceaccount.com:generateAccessToken",
  "source_credentials": {
    "client_id": "x.apps.googleusercontent.com",
    "client_secret": "s",
    "refresh_token": "$FAKE_REFRESH",
    "type": "authorized_user"
  },
  "type": "impersonated_service_account"
}
EOF
out=$(run "$(secrets order)")
check_contains "the real gcloud key order is read correctly" "$out" "EXIT=0"
check_not_contains "and not flagged as the operator" "$out" "principal is the human operator"

# A `"type"` inside a string value must not be mistaken for a field either.
mkdir -p "$(secrets instring)"
cat > "$(secrets instring)/gcp-adc.json" <<'EOF'
{"comment":"do not use \"type\": \"authorized_user\" here","type":"service_account","client_email":"a@b"}
EOF
out=$(run "$(secrets instring)")
check_contains "a type inside a string is not a field" "$out" "EXIT=0"

suite "what cannot be vouched for is said, not passed over"
# Anthropic has no machine identity to compare against, and an unrecognised
# shape is not evidence of anything. Both are notes: "I do not recognise this"
# and "this is the human" are different claims and only one is a finding.
out=$(run "$(secrets mixed)")
check_contains "still exits 0" "$out" "EXIT=0"
check_contains "says Anthropic has no machine identity" "$out" "no machine identity"
check_contains "and names that file" "$out" "anthropic.key"
check_contains "says an unknown shape is unverified" "$out" "shape not recognised"
check_contains "and names that one too" "$out" "custom.token"

suite "without the flag, the class is reported as not run"
# The honesty constraint from #26, one level further out: a scan that never
# looked at the credentials must not read as having approved them.
out=$(bash "$INV_SH" "$DEPLOY" 2>&1)
check_contains "says credentials were not checked" "$out" "credentials not checked"
check_contains "and why that matters" "$out" "principal is a machine or you"
check_not_contains "does not claim to have checked them" "$out" "credential file(s) checked in"

suite "with the flag, the count is stated"
out=$(run "$(secrets machine)")
check_contains "reports how many were checked" "$out" "3 credential file(s) checked in"

suite "no credential value ever reaches stdout"
# The one this suite exists for. Every fixture above is credential-shaped, so
# these patterns have something real to match if the checks ever print what
# they read. check_no_secret reports the pattern and a byte offset, never the
# haystack — a failure here must not itself become the leak.
for d in human machine mixed; do
  out=$(run "$(secrets $d)")
  check_no_secret "$d: no credential shape in the output" "$out" \
    'ghp_[A-Za-z0-9]{20,}' \
    'sk-ant-[A-Za-z0-9_-]{20,}' \
    '1//[A-Za-z0-9_-]{20,}' \
    'BEGIN [A-Z ]*PRIVATE KEY' \
    'MII[A-Za-z0-9+/]{40,}'
done

suite "a path outside the directory is not followed"
# --secrets-dir is a boundary, not a starting point. A symlink to somewhere
# else must not drag that file into a scan the operator did not ask for.
mkdir -p "$TMPD/elsewhere"
printf '%s' "$FAKE_PAT" > "$TMPD/elsewhere/stolen.token"
mkdir -p "$TMPD/linked"
ln -s "$TMPD/elsewhere/stolen.token" "$TMPD/linked/link.token"
out=$(run "$TMPD/linked")
check_not_contains "the symlinked file is not reported on" "$out" "stolen.token"
check_not_contains "and not followed under its link name either" "$out" "link.token"

suite "a missing directory is refused, not silently skipped"
out=$(bash "$INV_SH" --secrets-dir "$TMPD/nonexistent" "$DEPLOY" 2>&1; echo "EXIT=$?")
check_contains "exits 2" "$out" "EXIT=2"
check_contains "says why" "$out" "not a directory"

finish
