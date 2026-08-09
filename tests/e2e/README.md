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

**The repository must not be empty.** Give it at least one commit — a README
is enough. The first branch pushed to an empty repo becomes its default
branch, and GitHub refuses to delete a default branch, so the scratch branch
would be permanent. `30-git` checks and skips rather than leaving that behind.

**Repository permissions — `Contents: Read and write`.** `30-git` pushes a
scratch branch, and read-only Contents produces a clone that succeeds and a
push that 403s with `Write access to repository not granted`. That reads like
a proxy fault and is not one. Nothing else is needed: no Issues, no Pull
requests, no Metadata beyond the default.

If you change the permission on an App that is **already installed**, GitHub
does not apply it until the installation accepts the update — look for the
banner on the installation page, or the emailed request. Until then the
installation keeps minting tokens at the old scope and the failure repeats
identically.

```bash
mkdir -p ~/.config/agent-creds-e2e
cp ~/Downloads/<your-test-app>.private-key.pem ~/.config/agent-creds-e2e/github-app.pem
printf 'sk-ant-...' > ~/.config/agent-creds-e2e/anthropic.key
# or, to use an OAuth token instead (wins if both files exist):
# printf 'sk-ant-oat01-...' > ~/.config/agent-creds-e2e/anthropic-auth.token
chmod 600 ~/.config/agent-creds-e2e/*
```

Copying the `.pem` across a Windows filesystem boundary tends to land it
`0777`; the `chmod` above is not decoration.

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

`40-gcp` skips without this and the rest of the tier still runs. It also runs
**on its own, with no GitHub App and no Anthropic key**:

```bash
tests/e2e/run.sh 40
```

The tier's preflight is scoped to the suites actually selected, so a GCP-only
run demands only `gcp-adc.json` and `GCP_SERVICE_ACCOUNT`. You still need
`tests/e2e/.env` to exist and the credential directory, because compose mounts
it.

**Setup is scripted.** Fill in two values in `.env` and run it:

```bash
GCP_PROJECT=your-test-project
GCP_SA=sal-e2e-agent          # already the default
```

```bash
tests/e2e/run.sh setup gcp              # plan, confirm, apply
tests/e2e/run.sh setup gcp --yes        # no prompt, for reruns
tests/e2e/run.sh setup gcp --teardown   # remove what it created
```

It prints what it will do and asks before touching anything. Each step checks
first, so re-running after a partial failure resumes rather than duplicating:

1. enable `iamcredentials.googleapis.com` — impersonation fails without it,
   with a 403 that reads like a permissions problem
2. create the service account, **with no roles at all**
3. grant your account `roles/iam.serviceAccountTokenCreator` on it
4. `gcloud auth application-default login --impersonate-service-account`,
   under a throwaway `CLOUDSDK_CONFIG` so your own ADC is untouched
5. copy the result to `$AGENT_CREDS_DIR/gcp-adc.json`, and write
   `GCP_SERVICE_ACCOUNT` and `GCP_SA_UNIQUE_ID` back into `.env`

That last value is not decoration. Google's `tokeninfo` reports a service
account by **numeric id** — `email` appears only on user tokens carrying the
email scope — so the numeric id is the only way the suite can say *this token
belongs to that service account* rather than merely *some service account*.

Then verify the shape of what it produced — the script does this too and
refuses to finish if it is wrong:

```bash
jq '.type, (has("private_key"))' ~/.config/agent-creds-e2e/gcp-adc.json
# "impersonated_service_account"
# false
```

**No service-account key is created at any point.** That is the property being
tested, not an incidental detail: the grant in step 3 is what replaces a key
file, and the long-lived secret ends up being your refresh token — revocable,
and visible in Google's session management. The SA needing no roles is also
deliberate: the suite asserts an injected call is not rejected as
*unauthenticated*, and a 403 proves that as well as a 200 does.

That 403 is worth more than it looks. The probe targets the project you just
created the SA in — one **you** can read. If the broker had handed over your
own token instead of the impersonated one, it would come back 200. So a 403
there is the narrowing working: authenticated as the service account, and
authorized as nothing much.

The refresh token carries your own cloud identity, which is exactly why it
lives on the broker side and never in the lab. To revoke it later:

```bash
tests/e2e/run.sh setup gcp --teardown   # deletes the SA and the ADC file
gcloud auth application-default revoke  # if you want the token itself dead
```

<details>
<summary>Doing it by hand instead</summary>

```bash
PROJECT=your-test-project
SA=sal-e2e-agent
SA_EMAIL="$SA@$PROJECT.iam.gserviceaccount.com"

gcloud services enable iamcredentials.googleapis.com --project="$PROJECT"

gcloud iam service-accounts create "$SA" --project="$PROJECT" \
  --display-name="secure-agent-lab e2e (no permissions)"

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/iam.serviceAccountTokenCreator"

# CLOUDSDK_CONFIG is not optional here: without it this overwrites your own
# ~/.config/gcloud/application_default_credentials.json.
CLOUDSDK_CONFIG=/tmp/sal-e2e-gcloud gcloud auth application-default login \
  --impersonate-service-account="$SA_EMAIL"

cp /tmp/sal-e2e-gcloud/application_default_credentials.json \
   ~/.config/agent-creds-e2e/gcp-adc.json
chmod 600 ~/.config/agent-creds-e2e/gcp-adc.json
rm -rf /tmp/sal-e2e-gcloud
```

Then set `GCP_SERVICE_ACCOUNT="$SA_EMAIL"` in `.env`.
</details>

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

## Rate limiting between suites

`cred-gateway` limits the credential routes to `10r/m` with `burst 5`. That is
a real control protecting the broker, and a normal deployment never approaches
it — but four suites run back to back do, and the failure is misleading: the
credential helper receives nginx's 503 page and git reports

```
warning: invalid credential line: <html>
fatal: could not read Username for 'https://github.com'
```

which reads as a credential-helper bug. `run.sh` pauses between suites to let
the bucket refill rather than raising the limit, so what runs here stays the
configuration that ships. `E2E_SUITE_PAUSE=0` disables it when running a
single suite.

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
