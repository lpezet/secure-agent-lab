# e2e tier

The whole stack, real credentials, real vendor APIs.

```bash
tests/run.sh e2e          # via the facade
tests/e2e/run.sh          # or directly
tests/e2e/run.sh 20       # only suites starting with 20
KEEP_STACK=1 tests/e2e/run.sh   # leave the stack up afterwards to poke at
```

Without credentials configured this **skips** (exit 0) and tells you what is
missing, so it is safe in a pipeline that does not have them. It never fails
for being unconfigured.

## Why this exists

[`../integration/`](../integration/README.md) covers the security boundaries
thoroughly and for free, so this tier only earns its keep on the paths a stub
cannot reach:

- **HTTPS / CONNECT.** Every integration request is plain HTTP. Here the proxy
  terminates a real TLS tunnel with its own CA, which exercises the cert trust
  chain, `update-ca-certificates`, and the `proxy-certs` volume.
- **`git push` through the credential helper.** `010_github.py` deliberately
  does not match `github.com`, so pushing authenticates through `git
  credential` → cred-gateway → broker — a path nothing else touches. It can
  break while every other test stays green.
- **The broker's real provider code.** JWT signing, the GitHub token exchange,
  the caches. Integration tests the loader; this tests the providers.
- **SSE passthrough.** A stub cannot show you whether a response buffered.
- **The vendors' own auth.** An injected credential that the API rejects is
  still a failure, and only a real call finds it.

It also re-runs the boundary assertions against a broker that is genuinely
holding secrets. Same checks, real stakes.

## Setup

**1. A dedicated GitHub App.** Not the one your agent uses. Create it, install
it on one throwaway repository, download the private key.

```bash
mkdir -p ~/.config/agent-creds-e2e
cp ~/Downloads/<your-test-app>.private-key.pem ~/.config/agent-creds-e2e/github-app.pem
printf 'sk-ant-...' > ~/.config/agent-creds-e2e/anthropic.key
# or, to use an OAuth token instead (wins if both files exist):
# printf 'sk-ant-oat01-...' > ~/.config/agent-creds-e2e/anthropic-auth.token
chmod 600 ~/.config/agent-creds-e2e/*
```

**2. `.env`.**

```bash
cp tests/e2e/.env.example tests/e2e/.env
$EDITOR tests/e2e/.env
```

Only `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and `E2E_TEST_REPO` go in
`.env`. The Anthropic credential is a file in the creds directory, same as
`github-app.pem` — the reference `providers/anthropic.js` reads it from disk,
never from the environment.

Override the directory with `AGENT_CREDS_DIR` if you keep it elsewhere.
`run.sh` refuses outright to run against `~/.config/agent-creds`: this tier
mints tokens, pushes commits and burns quota, and doing that with the App a
real agent depends on turns a test bug into a production incident.

### GCP (optional)

`40-gcp` skips without this and the rest of the tier still runs. Four commands,
and **no service-account key is created at any point** — that is the whole
point of the design being tested.

```bash
PROJECT=your-test-project
SA=sal-e2e-agent
SA_EMAIL="$SA@$PROJECT.iam.gserviceaccount.com"

# 1. A service account with NO roles. It can authenticate and do nothing else,
#    which is deliberate: 40-gcp asserts that an injected call is not rejected
#    as *unauthenticated*, and a 403 proves that as well as a 200 does.
gcloud iam service-accounts create "$SA" --project="$PROJECT" \
  --display-name="secure-agent-lab e2e (no permissions)"

# 2. Let yourself impersonate it. This is the grant that replaces a key file.
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/iam.serviceAccountTokenCreator"

# 3. Produce an ADC file that impersonates it. CLOUDSDK_CONFIG points somewhere
#    throwaway ON PURPOSE: without it this overwrites your own
#    ~/.config/gcloud/application_default_credentials.json, and you would be
#    re-running `gcloud auth application-default login` to get your own back.
CLOUDSDK_CONFIG=/tmp/sal-e2e-gcloud gcloud auth application-default login \
  --impersonate-service-account="$SA_EMAIL"

# 4. Hand it to the tier.
cp /tmp/sal-e2e-gcloud/application_default_credentials.json \
   ~/.config/agent-creds-e2e/gcp-adc.json
chmod 600 ~/.config/agent-creds-e2e/gcp-adc.json
rm -rf /tmp/sal-e2e-gcloud
```

Then set `GCP_SERVICE_ACCOUNT` in `.env` to `$SA_EMAIL`. Optionally set
`GCP_TEST_PROJECT`; it needs neither to exist nor to be readable.

Check what you produced before trusting it — the file should say
`impersonated_service_account`, and contain no `private_key`:

```bash
jq '.type, (.service_account_impersonation_url // "none"), (has("private_key"))' \
  ~/.config/agent-creds-e2e/gcp-adc.json
# "impersonated_service_account"
# "https://iamcredentials.googleapis.com/v1/.../$SA_EMAIL:generateAccessToken"
# false
```

The long-lived secret in that file is **your refresh token**, not a key. It is
revocable (`gcloud auth application-default revoke`, or Google's session
management) and it carries your own cloud identity, which is why it lives on
the broker side and never in the lab. Cleaning up afterwards:

```bash
gcloud iam service-accounts delete "$SA_EMAIL" --project="$PROJECT"
rm ~/.config/agent-creds-e2e/gcp-adc.json
```

## The stack under test

`compose.yaml` here, **not** `examples/claude-code/compose.yaml` — that one
builds from `github.com/…#main`, so running it would certify whatever is on
`main` rather than the tree you are about to ship. Every build here is a local
path.

The addons, providers and gateway snippets are bind-mounted straight out of
`examples/claude-code/`, so this exercises the reference implementation the
repo ships and cannot drift from a copy of it.

Two additions a real deployment does not have: an `echo` service aliased to
`attacker-host`, which reflects request headers so a test can see what the
proxy sent and to whom; and `command: sleep infinity` on `lab`, since there is
no devcontainer lifecycle to hold it open. `run.sh` performs the two steps
`setup.sh` would have done — trusting the CA and wiring the credential helper.

## Suites

| | Covers |
|---|---|
| `10-boundary` | Broker unresolvable and unroutable from lab, no tunnel through the proxy (including with a spoofed `Host`), cred-gateway allows exactly two paths, dummy env values intact, nothing credential-shaped in lab's environment or git config |
| `20-injection` | Anthropic and GitHub over real HTTPS with no credential in the request, SSE not buffered, Admin API blocked, and the pre-fix exploit — claim to be the vendor, deliver to your own server — leaking nothing |
| `30-git` | Identity from the broker, clone over HTTPS via the credential helper, no token persisted into `.git/config`, push a scratch branch, verify it landed, delete it |
| `40-gcp` | Google's own `tokeninfo` confirming the minted token belongs to the *service account* and not the operator, an injected call not rejected as unauthenticated, the token exchange answered with the inert placeholder rather than a real token, and no credential shape in the broker's log. Skips unless GCP is configured |

## Cost and side effects

Each run makes two small Anthropic calls (haiku, ≤32 output tokens), a handful
of GitHub API calls, and — if `E2E_TEST_REPO` is set — pushes one empty commit
on a scratch branch named `e2e-<timestamp>-<pid>` and deletes it again. The
delete runs from an `EXIT` trap, so it still happens if an assertion fails
partway.

## Never print a secret

`check_no_secret` (in `../lib.sh`) is the assertion to use whenever the value
under test could be live. `check_not_contains` writes its haystack to the
terminal on failure, which for these suites means dumping a real key into your
scrollback and any CI log. `check_no_secret` reports the matching pattern and a
byte offset and nothing else.

Match credential *shapes* — `sk-ant-…`, `ghs_…`, `v1.<hex>` — via
`SECRET_PATTERNS`, so a suite never has to hold the secret it asserts about.

## What is still not covered

- Cloudflare. The `claude-code` example has no `030_cloudflare.py`; the
  addon has integration coverage only.
- The devcontainer lifecycle itself. `run.sh` reimplements the two essential
  steps of `setup.sh` rather than running it, so a regression in those scripts
  would not show up here.
- The TLS form of the Host-spoofing attack. The exploit is reproduced over
  plain HTTP through the proxy, which is how it was originally found; the
  addons make their host decision before any TLS handling, so the code under
  test is the same, but a CONNECT-tunnelled variant is not exercised.
