# Tests

Two tiers, split by whether the credentials involved are real.

```bash
tests/run.sh                     # integration — the safe default
tests/run.sh integration 20 30   # → tests/integration/run.sh 20 30
tests/run.sh e2e                 # → tests/e2e/run.sh
tests/run.sh all                 # both, integration first
```

`tests/run.sh` is a thin facade: it picks a tier and passes every remaining
argument through, so `tests/run.sh 20` still means "integration, suite 20" and
`FORCE_BUILD=1` still works. Each tier's `run.sh` is equally runnable on its
own.

**Prerequisites.** `docker` for everything except `00-config-lint`, and `jq`
for `00-config-lint` — the provider-bank manifests are JSON and are read rather
than pattern-matched. A missing prerequisite exits **2**, which is how it is
told apart from a failing assertion (exit 1).

| Tier | Credentials | Cost | Covers |
|---|---|---|---|
| [`integration/`](integration/README.md) | none — stubs and fixtures | free, ~60s | The security boundaries: whitelist behaviour, proxy host matching, egress allowlist, mount isolation |
| `stacks/` | none | free, ~80s (minutes cold) | The shapes this repo *ships*, run rather than read: the template and both examples, built by compose from the tag each one pins |
| [`e2e/`](e2e/README.md) | real, from a dedicated App and creds dir | real API quota | The paths a stub cannot reach: HTTPS/CONNECT, the CA cert lifecycle, `git push` through the credential helper, live token minting |

**Why `stacks/` is not part of `integration/`.** The integration tier proves a
property against hand-built containers on a hand-made network, which is the
right way to test an addon and says nothing about whether a *deployment* is
wired correctly. `stacks/` starts each shape from its own `compose.yaml`, with
images compose builds from the tag that file pins — so it is the only tier that
notices a repin landing badly, or the template moving, or a mount going away.
It is free and needs no credentials; it is out of the bare default only because
it builds images.

Two bands. `10-compose-config` asks compose what the files *mean* — port
interpolation, profile selection — and builds nothing, so it runs in about a
second. `20-boundary` brings each shape up and checks the boundary from the
`lab` network. `lab` itself is never started: its image is a slow local build
and its `setup.sh` fetches a GitHub App identity, so it is *supposed* to fail
without credentials.

A bare `tests/run.sh` deliberately does not run e2e. That tier spends real API
quota, mints real tokens and pushes to a real repository — it should be
something you ask for by name, not something the obvious command does to you.
For the same reason `all` is fail-fast: if integration is red there is no point
paying for e2e.

## In CI

`.github/workflows/tests.yml` runs the integration tier on every pull request
and on every push to `main`, as two jobs: `lint` (the docker-free band —
`00 05 06 07 08`) and `integration` (the whole tier).

**e2e does not run in CI at all, by decision rather than by omission**
(closing note on #61). Its inputs are a GitHub App private key, an Anthropic
key or OAuth token, and a GCP ADC file carrying the operator's own refresh
token; storing those as repository secrets means putting live personal
credentials in a system this repo exists to treat as untrusted, to buy a
nightly re-run of assertions the integration tier already covers for free.

So there is no e2e workflow, scheduled or otherwise, and **nothing in
`.github/` gets a credential**. The rule is stronger for being permanent: this
is a public repo, so a fork PR that edits a test file runs attacker-authored
code in the job. `permissions: contents: read` and the absence of any `secrets`
reference are the design, not a stepping stone.

Run e2e locally — see [`e2e/README.md`](e2e/README.md).

Note that a push to a branch with no PR open triggers nothing: the workflow
fires on `pull_request` and on `push` to `main`. To check a branch before
opening a PR, dispatch it by hand:

```bash
gh workflow run tests.yml --ref your-branch
```

## Shared code

`lib.sh` holds the assertions (`check`, `check_ne`, `check_contains`,
`check_not_contains`, `check_no_secret`, `ok`, `ko`, `skip`, `suite`,
`finish`) and the docker helpers (`net_up`,
`curl_up`, `stub_broker_up`, `http_code`, `http_body`, `wait_http`,
`build_image`, `track_container`). Both tiers source it; `fixtures/` is shared
the same way.

Every resource is named with the running PID and removed by an `EXIT` trap, so
a run never collides with — or cleans up — a real stack you have running.

## Known environment quirks

### A generated file mounted into the broker needs to be world-readable

The broker image drops to `node` (uid 1000), and a bind-mounted file keeps its
*host* uid and mode inside the container. So a file the suite generates at 0600
— `openssl genrsa -out` does exactly that — is readable by the broker only when
the host user happens to be uid 1000 too. That is true on a typical
workstation and false on a GitHub runner (uid 1001), where it surfaces as
`{"error":"internal error"}` and an `"error":"EACCES"` audit line rather than
as anything about permissions.

`chmod 0644` whatever you generate and mount. Files written with `cat >` or
`printf >` already are, under a normal umask.

### `20-boundary` skips the template during a release

The template must name the version being cut — `00-config-lint` fails if it
lags — but that tag is only created after the release PR merges. So for as long
as the PR is open, the template pins a ref nothing can build from, and the
suite skips that shape rather than failing:

```
SKIP template — pins v1.11.1, which is not tagged yet
```

Scoped to a tag genuinely absent from the remote, so a typo or a pin to
something that never existed still fails. An `ls-remote` that does not answer
at all is treated as "do not skip", so an offline run cannot quietly pass by
skipping everything.

### A killed `stacks` run can break the next one

Each shape brought up by `20-boundary` creates two Docker networks, and
Docker's default address pools are finite. A run that is interrupted before its
teardown leaves six behind; enough of those and the *next* run fails with

```
Error response from daemon: all predefined address pools have been fully subnetted
```

which reads as a broken stack and is not. The suite traps `INT` and `TERM` as
well as `EXIT`, and sweeps anything left by an earlier run of itself at
startup — but a `kill -9` can outrun both. To clear it by hand:

```bash
docker network ls --format '{{.Name}}' | grep '^sattest-' | xargs -r docker network rm
```

### Docker Desktop on WSL

Docker Desktop on WSL writes `"credsStore": "desktop.exe"` into
`~/.docker/config.json`. `docker build` invokes that helper even for public
images and it is often not executable from inside the distro:

```
error getting credentials — fork/exec …/docker-credential-desktop.exe: exec format error
```

`docker run` and `docker pull` are unaffected, which makes it look
intermittent. `lib.sh` detects an unusable store and points `DOCKER_CONFIG` at
a scratch config for the run; it leaves a working store alone.
