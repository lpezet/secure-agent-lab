#!/usr/bin/env bash
# The real bank/gcp/broker/gcp.js against a TLS stub standing in for Google.
#
# Two credential shapes reach a GCP access token, and the broker supports both
# because they fail differently rather than because one is better:
#
#   impersonated_service_account  no key anywhere; the long-lived secret is the
#                                 operator's refresh token, which a Workspace
#                                 session policy can expire out from under an
#                                 unattended agent
#   service_account               a key file, so nothing to re-authenticate;
#                                 but a permanent secret on disk
#
# The key-file path signs an RS256 assertion with the SA's own private key, so
# it is credential code and gets tested rather than reasoned about. Both paths
# talk HTTPS to Google, so this stands up a TLS stub *as* oauth2.googleapis.com
# and iamcredentials.googleapis.com, the way 45-broker-github-scope does.
#
# Nothing here is a credential: every key is generated per run inside $WORK and
# the tokens the stub hands back are obvious fakes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

require_docker
IMG="sat-test-broker"
build_image "$IMG" stack/broker || exit 1

FAKE_TOKEN="STUB-GCP-ACCESS-TOKEN-VALUE"
SA_EMAIL="agent@example-project.iam.gserviceaccount.com"
OTHER_SA="someone-else@example-project.iam.gserviceaccount.com"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; cleanup' EXIT

# The service account's own key. Generated per run; the stub does not verify
# the signature, but the broker will not produce an assertion without a usable
# private key, so this exercises the real signing path.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/sa.pem" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=oauth2.googleapis.com" -keyout "$WORK/stub.key" -out "$WORK/stub.crt" >/dev/null 2>&1

# JSON-escape the PEM into the ADC file the way Google writes it.
PEM_ESCAPED=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read())[1:-1])' "$WORK/sa.pem")

cat > "$WORK/key-adc.json" <<EOF
{
  "type": "service_account",
  "project_id": "example-project",
  "private_key_id": "stub-key-id",
  "private_key": "$PEM_ESCAPED",
  "client_email": "$SA_EMAIL",
  "token_uri": "https://oauth2.googleapis.com/token"
}
EOF

# A bare authorized_user: the operator's own identity, which must be refused.
cat > "$WORK/human-adc.json" <<'EOF'
{ "type": "authorized_user", "client_id": "x", "client_secret": "y", "refresh_token": "z" }
EOF

# Federation from an outside IdP — deliberately not implemented, and the
# refusal is asserted so "unsupported" stays a decision rather than a silence.
cat > "$WORK/external-adc.json" <<'EOF'
{ "type": "external_account", "audience": "//iam.googleapis.com/x", "token_url": "https://sts.googleapis.com/v1/token" }
EOF

# The stub records the assertion it was sent, so the suite can prove a real
# signed JWT crossed the wire rather than trusting that one was built.
#
# A Python TLS server rather than the nginx stub the other suites use: nginx
# never reads a request body it is going to answer with `return`, so
# $request_body is "-" and client_body_in_file_only has nothing to write. What
# this suite most needs to see is exactly that body.
cat > "$WORK/stub.py" <<'PYEOF'
import http.server, json, ssl, sys

BODY_LOG = "/tmp/posted.txt"

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(BODY_LOG, "a") as fh:
            fh.write(body + "\n")
        if self.path == "/token":
            payload = {"access_token": sys.argv[2], "expires_in": 3600,
                       "token_type": "Bearer"}
        else:
            payload = {"accessToken": sys.argv[2],
                       "expireTime": "2099-01-01T00:00:00Z"}
        out = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2")
        self.end_headers(); self.wfile.write(b"ok")

    def log_message(self, *a):
        pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/certs/stub.crt", "/certs/stub.key")
srv = http.server.HTTPServer(("0.0.0.0", 443), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PYEOF

net_up
curl_up

GS="$RUN_ID-gcpstub"
docker run -d --name "$GS" --network "$NET" \
  -v "$WORK/stub.py:/stub.py:ro" \
  -v "$WORK/stub.crt:/certs/stub.crt:ro" \
  -v "$WORK/stub.key:/certs/stub.key:ro" \
  python:3-alpine python /stub.py serve "$FAKE_TOKEN" >/dev/null
track_container "$GS"
STUB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GS")

# Wait for TLS to be accepting. nginx is listening by the time `docker run`
# returns; a Python server is not, and the broker's first call then fails with
# ECONNREFUSED — which the suite would report as a minting failure.
stub_ready=0
for _ in $(seq 1 40); do
  if docker exec "$CURL_C" curl -sk -o /dev/null "https://$STUB_IP/" 2>/dev/null; then
    stub_ready=1; break
  fi
  sleep 0.25
done
[ "$stub_ready" = 1 ] || { ko "stub did not start" "$(docker logs "$GS" 2>&1 | tail -20)"; finish; }

# start_broker <name> <adc-file> [extra docker args...]
start_broker() {
  local label="$1" name="$RUN_ID-$1" adc="$2"; shift 2
  docker run -d --name "$name" --network "$NET" \
    --add-host "oauth2.googleapis.com:$STUB_IP" \
    --add-host "iamcredentials.googleapis.com:$STUB_IP" \
    -v "$REPO_ROOT/bank/gcp/broker:/app/providers:ro" \
    -v "$adc:/secrets/gcp-adc.json:ro" \
    -e GCP_ADC_PATH=/secrets/gcp-adc.json \
    -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
    -e AUDIT_LOG=/tmp/audit.jsonl \
    "$@" "$IMG" >/dev/null
  track_container "$name"
  wait_http "$name:8080/healthz" 200 "broker $label"
}

# ------------------------------------------------------------- the key path

suite "a service-account key file mints a token, with no user involved"
# The shape that needs nobody to re-authenticate. Whether that is the right
# trade is the deployment's call; that it works is this suite's business.
if start_broker broker-key "$WORK/key-adc.json" -e GCP_SERVICE_ACCOUNT="$SA_EMAIL"; then
  body=$(http_body "http://$RUN_ID-broker-key:8080/gcp/token")
  check_contains "a token is issued" "$body" "$FAKE_TOKEN"

  posted=$(docker exec "$GS" cat /tmp/posted.txt 2>/dev/null)
  check_contains "by the JWT-bearer grant" "$posted" "jwt-bearer"
  check_contains "carrying a signed assertion" "$posted" "assertion="
  # A JWT is three dot-separated segments; a header alone would also contain
  # "assertion=", so assert the shape rather than the substring.
  sig=$(printf '%s' "$posted" | grep -oE 'assertion=[A-Za-z0-9_-]+%2E[A-Za-z0-9_-]+%2E[A-Za-z0-9_-]+' \
        || printf '%s' "$posted" | grep -oE 'assertion=[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')
  check_ne "the assertion is a three-part JWT" "" "$sig"

  trail=$(docker exec "$RUN_ID-broker-key" cat /tmp/audit.jsonl 2>/dev/null)
  check_contains "the trail records the issue" "$trail" '"event":"token_issued"'
  check_contains "naming the service account" "$trail" "$SA_EMAIL"
  check_contains "and which credential shape produced it" "$trail" '"source":"key"'
  check_no_secret "no private key material reaches the trail" "$trail" \
    'BEGIN [A-Z ]*PRIVATE KEY' 'MII[A-Za-z0-9+/]{40,}'
  check_not_contains "and neither does the token" "$trail" "$FAKE_TOKEN"
else
  ko "key-file broker did not start" "$(docker logs "$RUN_ID-broker-key" 2>&1 | tail -20)"
fi

# ------------------------------------------------------ configuration wins

suite "the configured service account is cross-checked against the file"
# A swapped ADC file must not be able to change which identity the deployment
# issues without something saying so. Same rule as #38's profile.
if start_broker broker-mismatch "$WORK/key-adc.json" -e GCP_SERVICE_ACCOUNT="$OTHER_SA"; then
  code=$(http_code "http://$RUN_ID-broker-mismatch:8080/gcp/token")
  check "a mismatch is refused" "403" "$code"
  trail=$(docker exec "$RUN_ID-broker-mismatch" cat /tmp/audit.jsonl 2>/dev/null)
  check_contains "and the refusal reaches the trail" "$trail" '"reason":"sa_mismatch"'
  check_not_contains "nothing was issued" "$trail" '"event":"token_issued"'
else
  ko "mismatch broker did not start" "$(docker logs "$RUN_ID-broker-mismatch" 2>&1 | tail -20)"
fi

# ------------------------------------------------------------ refused shapes

suite "the operator's own identity is refused outright"
# The whole point of the provider. A bare authorized_user would make the agent
# act as the human, across everything that human can reach. See #42.
if start_broker broker-human "$WORK/human-adc.json"; then
  code=$(http_code "http://$RUN_ID-broker-human:8080/gcp/token")
  check "a bare authorized_user is refused" "403" "$code"
  trail=$(docker exec "$RUN_ID-broker-human" cat /tmp/audit.jsonl 2>/dev/null)
  check_contains "named as such in the trail" "$trail" '"reason":"human_principal"'
else
  ko "human-adc broker did not start" "$(docker logs "$RUN_ID-broker-human" 2>&1 | tail -20)"
fi

suite "an unimplemented shape is refused, not half-attempted"
# external_account is federation from an outside IdP. Refusing it loudly is
# better than shipping credential code nothing can exercise.
if start_broker broker-external "$WORK/external-adc.json"; then
  code=$(http_code "http://$RUN_ID-broker-external:8080/gcp/token")
  check_ne "external_account does not mint" "200" "$code"
  trail=$(docker exec "$RUN_ID-broker-external" cat /tmp/audit.jsonl 2>/dev/null)
  check_contains "and says why" "$trail" '"reason":"unsupported_adc_type"'
else
  ko "external-adc broker did not start" "$(docker logs "$RUN_ID-broker-external" 2>&1 | tail -20)"
fi

finish
