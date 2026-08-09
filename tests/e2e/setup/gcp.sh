#!/usr/bin/env bash
# One-time GCP setup for tests/e2e/40-gcp.test.sh.
#
#   tests/e2e/run.sh setup gcp             # plan, confirm, apply
#   tests/e2e/run.sh setup gcp --yes       # no prompt, for reruns
#   tests/e2e/run.sh setup gcp --teardown  # remove what this created
#   tests/e2e/run.sh setup gcp --verify-key-file
#                                          # exercise the key-file path once,
#                                          # against real Google, leaving no key
#
# Reads GCP_PROJECT and GCP_SA from tests/e2e/.env, derives everything else,
# and writes GCP_SERVICE_ACCOUNT back so the suite and the stack read the same
# value nothing had to retype.
#
# Idempotent by construction: every step checks before it acts, so running it
# twice is a no-op and running it after a partial failure resumes. It creates
# real resources in a real project, so it prints the plan and asks first.
#
# NO SERVICE-ACCOUNT KEY IS EVER CREATED. The grant that replaces one is
# roles/iam.serviceAccountTokenCreator on the operator, which is revocable and
# leaves the long-lived secret as a refresh token rather than a file.
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$E2E_DIR/.env"
: "${AGENT_CREDS_DIR:=$HOME/.config/agent-creds-e2e}"
ADC_OUT="$AGENT_CREDS_DIR/gcp-adc.json"

# gcloud writes ADC to $CLOUDSDK_CONFIG/application_default_credentials.json.
# Pointing it at a throwaway directory is what stops this overwriting the
# operator's own ADC — losing that is a genuine annoyance to recover from.
GCLOUD_TMP="${TMPDIR:-/tmp}/sal-e2e-gcloud.$$"

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; N=''
fi

ASSUME_YES=0 TEARDOWN=0 VERIFY_KEY=0
for a in "$@"; do
  case "$a" in
    -y|--yes)   ASSUME_YES=1 ;;
    --teardown) TEARDOWN=1 ;;
    --verify-key-file) VERIFY_KEY=1 ;;
    -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$a" >&2; exit 2 ;;
  esac
done

die()  { printf '%serror%s  %s\n' "$R" "$N" "$1" >&2; exit 2; }
step() { printf '%s→%s %s\n' "$B" "$N" "$1"; }
ok()   { printf '  %sok%s    %s\n' "$G" "$N" "$1"; }
note() { printf '  %snote%s  %s\n' "$Y" "$N" "$1"; }

# ------------------------------------------------------------------- inputs

[ -f "$ENV_FILE" ] || die "no $ENV_FILE — copy .env.example first"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

[ -n "${GCP_PROJECT:-}" ] || die "GCP_PROJECT is empty in tests/e2e/.env"
[ -n "${GCP_SA:-}" ]      || die "GCP_SA is empty in tests/e2e/.env"
command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed"

SA_EMAIL="$GCP_SA@$GCP_PROJECT.iam.gserviceaccount.com"

ACCOUNT=$(gcloud config get-value account 2>/dev/null)
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "(unset)" ] || die "gcloud is not logged in — run: gcloud auth login"

# set_env <key> <value> — idempotent single-key update of tests/e2e/.env.
set_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # A value containing / would break a sed s|| too, so rewrite in awk.
    awk -v k="$key" -v v="$val" -F= '
      $1 == k { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# -------------------------------------------------------------- verify a key
#
# The broker supports a service-account key file as well as impersonation,
# because impersonation's refresh token can be expired by a Workspace session
# policy and an unattended agent cannot re-authenticate. That path is otherwise
# only stub-tested: nothing has ever handed a real Google endpoint an assertion
# signed by a real key.
#
# This exercises it once, end to end, and leaves nothing behind. The key is
# deleted **in GCP** — removing the local file alone leaves it valid and listed
# on the service account, which is the mistake worth automating away.

if [ "$VERIFY_KEY" = 1 ]; then
  [ -n "${GCP_SERVICE_ACCOUNT:-}" ] || die "GCP_SERVICE_ACCOUNT is not set — run setup first"
  SA_EMAIL="$GCP_SERVICE_ACCOUNT"

  printf '\n%sVerify the key-file path%s\n' "$B" "$N"
  printf '  service account  %s\n' "$SA_EMAIL"
  printf '\n  1. create a service-account key (registered in GCP)\n'
  printf '  2. point the stack at it, temporarily, in place of the ADC file\n'
  printf '  3. run tests/e2e/run.sh 40\n'
  printf '  4. restore the ADC file and DELETE THE KEY IN GCP\n'
  printf '\n  %sStep 4 runs from a trap%s, so it happens on failure or Ctrl-C too. The\n' "$Y" "$N"
  printf '  key id is printed before use, so it can be deleted by hand if all else fails.\n\n'
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in [yY]*) ;; *) printf 'aborted\n'; exit 0 ;; esac
  fi

  KEY_TMP="${TMPDIR:-/tmp}/sal-e2e-sa-key.$$.json"
  ADC_BACKUP="$ADC_OUT.before-key-verify.$$"
  KEY_ID=""

  restore_and_revoke() {
    local rc=$?
    printf '\n%s→%s cleaning up\n' "$B" "$N"
    if [ -f "$ADC_BACKUP" ]; then
      mv -f "$ADC_BACKUP" "$ADC_OUT" && ok "ADC file restored"
    fi
    rm -f "$KEY_TMP"
    if [ -n "$KEY_ID" ]; then
      if gcloud iam service-accounts keys delete "$KEY_ID" \
           --iam-account="$SA_EMAIL" --quiet >/dev/null 2>&1; then
        ok "key $KEY_ID deleted in GCP"
      else
        printf '  %sWARNING%s key %s may still exist. Delete it:\n' "$R" "$N" "$KEY_ID" >&2
        printf '    gcloud iam service-accounts keys delete %s --iam-account=%s\n' \
          "$KEY_ID" "$SA_EMAIL" >&2
      fi
    fi
    exit $rc
  }
  trap restore_and_revoke EXIT INT TERM

  step "creating a service-account key"
  gcloud iam service-accounts keys create "$KEY_TMP" --iam-account="$SA_EMAIL" >/dev/null 2>&1 \
    || die "could not create a key — org policy may forbid it (iam.disableServiceAccountKeyCreation)"
  chmod 600 "$KEY_TMP"
  KEY_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' "$KEY_TMP")
  ok "key $KEY_ID created — it will be deleted before this exits"

  step "pointing the stack at it"
  cp "$ADC_OUT" "$ADC_BACKUP"
  cp "$KEY_TMP" "$ADC_OUT"
  chmod 600 "$ADC_OUT"
  ok "ADC file swapped (original saved)"

  step "running the suite against the key file"
  if bash "$E2E_DIR/run.sh" 40; then
    printf '\n%skey-file path verified against real Google%s\n' "$G" "$N"
  else
    printf '\n%sthe suite failed with a key file%s — see above\n' "$R" "$N"
    exit 1
  fi
  exit 0
fi

# ------------------------------------------------------------------ teardown

if [ "$TEARDOWN" = 1 ]; then
  printf '\n%sTeardown plan%s\n' "$B" "$N"
  printf '  delete service account  %s\n' "$SA_EMAIL"
  printf '  delete ADC file         %s\n' "$ADC_OUT"
  printf '  %sleaves alone:%s the project, and your own gcloud login\n\n' "$Y" "$N"
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in [yY]*) ;; *) printf 'aborted\n'; exit 0 ;; esac
  fi
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    gcloud iam service-accounts delete "$SA_EMAIL" --project="$GCP_PROJECT" --quiet \
      && ok "service account deleted" || die "could not delete the service account"
  else
    ok "service account already absent"
  fi
  rm -f "$ADC_OUT" && ok "ADC file removed"
  note "the refresh token inside it stays valid until revoked:"
  printf '        CLOUDSDK_CONFIG=%s gcloud auth application-default revoke\n' "$GCLOUD_TMP"
  exit 0
fi

# ---------------------------------------------------------------------- plan

printf '\n%sPlan%s\n' "$B" "$N"
printf '  project          %s\n' "$GCP_PROJECT"
printf '  service account  %s\n' "$SA_EMAIL"
printf '  impersonated by  %s\n' "$ACCOUNT"
printf '  ADC written to   %s\n' "$ADC_OUT"
printf '\n  Steps, each skipped if already done:\n'
printf '    1. enable iamcredentials.googleapis.com on the project\n'
printf '    2. create the service account, with NO roles\n'
printf '    3. grant %s roles/iam.serviceAccountTokenCreator on it\n' "$ACCOUNT"
printf '    4. run `gcloud auth application-default login --impersonate-service-account`\n'
printf '       (opens a browser; uses a throwaway CLOUDSDK_CONFIG so your own ADC is untouched)\n'
printf '    5. copy the result to the creds dir and set GCP_SERVICE_ACCOUNT in .env\n'
printf '\n  %sNo service-account key is created.%s The long-lived secret ends up being\n' "$Y" "$N"
printf '  your refresh token, which is revocable and visible in Google session management.\n\n'

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in [yY]*) ;; *) printf 'aborted\n'; exit 0 ;; esac
fi

trap 'rm -rf "$GCLOUD_TMP"' EXIT

# --------------------------------------------------------------------- apply

step "checking project access"
gcloud projects describe "$GCP_PROJECT" >/dev/null 2>&1 \
  || die "cannot access project $GCP_PROJECT as $ACCOUNT"
ok "$GCP_PROJECT reachable"

step "checking the IAM Credentials API"
# Impersonation calls iamcredentials.googleapis.com. Without it enabled the
# broker's generateAccessToken fails with a 403 that reads like a permissions
# problem, which is a bad afternoon.
if gcloud services list --enabled --project="$GCP_PROJECT" \
     --filter="config.name=iamcredentials.googleapis.com" --format="value(config.name)" \
     2>/dev/null | grep -q iamcredentials; then
  ok "already enabled"
else
  gcloud services enable iamcredentials.googleapis.com --project="$GCP_PROJECT" \
    && ok "enabled" || die "could not enable iamcredentials.googleapis.com"
fi

step "checking the service account"
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  ok "$SA_EMAIL already exists"
else
  gcloud iam service-accounts create "$GCP_SA" --project="$GCP_PROJECT" \
    --display-name="secure-agent-lab e2e (no permissions)" \
    && ok "created" || die "could not create the service account"
fi

step "checking the impersonation grant"
if gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project="$GCP_PROJECT" \
     --format=json 2>/dev/null \
   | grep -q "roles/iam.serviceAccountTokenCreator" ; then
  ok "roles/iam.serviceAccountTokenCreator already bound"
else
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$GCP_PROJECT" \
    --member="user:$ACCOUNT" \
    --role="roles/iam.serviceAccountTokenCreator" >/dev/null \
    && ok "granted to $ACCOUNT" || die "could not grant the impersonation role"
  note "IAM changes can take a minute to propagate; a first run may 403"
fi

step "producing the ADC file"
if [ -f "$ADC_OUT" ] \
   && grep -q '"impersonated_service_account"' "$ADC_OUT" 2>/dev/null \
   && grep -q "$SA_EMAIL" "$ADC_OUT" 2>/dev/null; then
  ok "$ADC_OUT already impersonates $SA_EMAIL"
else
  mkdir -p "$GCLOUD_TMP" "$AGENT_CREDS_DIR"
  printf '  a browser window will open\n'
  CLOUDSDK_CONFIG="$GCLOUD_TMP" gcloud auth application-default login \
    --impersonate-service-account="$SA_EMAIL" \
    || die "application-default login did not complete"
  src="$GCLOUD_TMP/application_default_credentials.json"
  [ -f "$src" ] || die "expected $src, which gcloud did not write"
  cp "$src" "$ADC_OUT"
  chmod 600 "$ADC_OUT"
  ok "written to $ADC_OUT"
fi

step "verifying what was produced"
# Shape, not contents. A file with a private_key in it means impersonation did
# not happen and a key landed on disk after all — the one outcome this whole
# design exists to avoid, so it is a hard failure rather than a note.
grep -q '"impersonated_service_account"' "$ADC_OUT" \
  || die "$ADC_OUT is not an impersonated_service_account — refusing to continue"
if grep -q '"private_key"' "$ADC_OUT"; then
  die "$ADC_OUT contains a private key. Delete it and re-run; something impersonated nothing."
fi
grep -q "$SA_EMAIL" "$ADC_OUT" || die "$ADC_OUT does not name $SA_EMAIL"
ok "impersonated_service_account, no key material, names $SA_EMAIL"

step "wiring tests/e2e/.env"
set_env GCP_SERVICE_ACCOUNT "$SA_EMAIL"
ok "GCP_SERVICE_ACCOUNT=$SA_EMAIL"

# Google's tokeninfo reports a service account by NUMERIC id, not by email —
# `email` appears only for user tokens carrying the email scope. So the suite
# needs the unique id to be able to say "this token belongs to that service
# account" rather than merely "some service account".
UNIQUE_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT" \
              --format="value(uniqueId)" 2>/dev/null)
if [ -n "$UNIQUE_ID" ]; then
  set_env GCP_SA_UNIQUE_ID "$UNIQUE_ID"
  ok "GCP_SA_UNIQUE_ID=$UNIQUE_ID"
else
  note "could not read the service account's uniqueId — 40-gcp will skip the identity check"
fi

printf '\n%sdone%s — run it with:\n' "$G" "$N"
printf '  tests/e2e/run.sh 40\n\n'
printf 'To remove everything this created:\n'
printf '  tests/e2e/run.sh setup gcp --teardown\n'
