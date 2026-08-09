#!/bin/bash
# GCP — lab-side setup fragment.
#
# Sourced by the deployment's setup.sh. Runs INSIDE the lab container, which is
# the untrusted side already: nothing here can do anything the lab could not
# already do. That is the whole reason a bank entry is allowed to ship shell.
#
# It writes an ADC file containing no credential. Google's client libraries
# will not call an API until their credential chain produces a token, and with
# nothing to find the chain raises before opening a socket — there would be no
# request for the proxy to mediate. This file is what makes the chain proceed
# as far as a token exchange, which the proxy addon answers.
#
# `gcloud` needs none of this: CLOUDSDK_AUTH_ACCESS_TOKEN=proxy-injected is the
# top of its credential priority list and is set in the lab environment.
set -euo pipefail

ADC_PATH="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcp/inert-adc.json}"
ADC_DIR="$(dirname "$ADC_PATH")"
TOKEN_SH="$ADC_DIR/inert-token.sh"

echo "[setup:gcp] writing an inert ADC file to $ADC_PATH..."
mkdir -p "$ADC_DIR"

# The executable credential source. It prints a fixed dummy rather than
# fetching anything, so this holds no secret in any sense — it is the same
# inert placeholder as GH_TOKEN=proxy-injected, wearing the shape google-auth
# expects. The expiry is far future so the library never treats it as stale.
cat > "$TOKEN_SH" <<'EOF'
#!/bin/sh
printf '{"version":1,"success":true,"token_type":"urn:ietf:params:oauth:token-type:id_token","id_token":"proxy-injected","expiration_time":4102444800}\n'
EOF
chmod +x "$TOKEN_SH"

# type=external_account so the chain ends at sts.googleapis.com, which the
# addon answers. The audience and token_url are structural: nothing in this
# file is ever sent anywhere, because the exchange never leaves the proxy.
cat > "$ADC_PATH" <<EOF
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/0/locations/global/workloadIdentityPools/inert/providers/inert",
  "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "executable": {
      "command": "$TOKEN_SH",
      "timeout_millis": 5000
    }
  }
}
EOF
chmod 0644 "$ADC_PATH"

# google-auth refuses an executable credential source unless this is set. It is
# already in the lab environment; asserted here so a deployment that dropped it
# fails loudly at setup rather than confusingly on the first API call.
if [ "${GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES:-0}" != "1" ]; then
  echo "[setup:gcp] WARNING: GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES is not 1 —" >&2
  echo "[setup:gcp]          the client libraries will refuse this ADC file." >&2
fi

echo "[setup:gcp] ok"
