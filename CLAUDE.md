# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker setup to run autonomous agents/harness (e.g. Claude Code) without exposing long-lived credentials to the agent's process. The agent's outbound HTTPS traffic is intercepted by mitmproxy, which injects credentials fetched from a broker the agent cannot reach directly.

## Architecture

```
[lab container]  ──HTTPS──►  [proxy: mitmproxy]  ──injects creds──►  external APIs
     │                              │
     │ git creds only               │ fetches creds from broker
     ▼                              ▼
[cred-gateway: nginx]  ──────►  [broker: Node.js]  ──reads──►  ~/.config/agent-creds/
     │                              │
     │                              │  JSONL, no secret values
     ▼                              ▼
              [audit-logs volume]
             │                    │
             ▼                    ▼
    [log-rotator: cron+logrotate] [observer: :9000, loopback-only]
```

broker, proxy, and cred-gateway each write a structured JSONL audit trail (what got injected/blocked/issued, never a credential value) to a shared `audit-logs` named volume. `observer` tails it and serves a live view; `log-rotator` keeps it bounded. Neither has a `networks:` entry — they reach the volume without joining `secure` or `lab`, so the audit trail cannot become a new channel between the two. See the `observer` and `log-rotator` sections below.

**Two Docker networks enforce the security boundary:**

- `secure`: broker + proxy + cred-gateway. Dev container is **not** on this network.
- `lab`: lab + proxy + cred-gateway. **`internal: ${LAB_INTERNAL:-true}`** — no
  default gateway, so the proxy is the only way out and the allowlist is
  enforcing rather than advisory. `secure` is *not* internal: the broker needs
  direct egress to provider APIs.

The broker is on `secure` only. Docker DNS will not resolve `broker` from within the lab container, and there is no route even if it did. The only broker-adjacent surface reachable from lab is the two nginx-whitelisted paths on cred-gateway.

**One directory per service, named after the service — in both `stack/` and `examples/`.**

```
                      stack/ (builds the image)      examples/ (supplies content)
broker         →      broker/providers/*.js          broker/*.js
proxy          →      proxy/addons/*.py              proxy/*.py
cred-gateway   →      cred-gateway/gateway.d/*.conf  cred-gateway/*.conf
lab            →      lab/Dockerfile                 lab/Dockerfile
```

`stack/` needs the extra `providers/` / `addons/` / `gateway.d/` level because those directories sit alongside the image's own files — `stack/broker/` also holds `Dockerfile`, `server.js`, `package.json`. An example's service directory holds nothing but the mounted content, so the level would be pure ceremony; the mount says where it lands:

```yaml
- ./broker:/app/providers:ro
- ./proxy:/addons:ro
- ./cred-gateway:/etc/nginx/gateway.d:ro
```

Which service owns a file is answered by the directory name, rather than by knowing that addons are a mitmproxy concept and providers a broker one. Keep new content under the service that consumes it.

### broker (`stack/broker/`)

Node.js HTTP server on `:8080`. Reads credentials from `/secrets` (bind-mounted from `~/.config/agent-creds/` on the host, read-only).

Route handlers live in `stack/broker/providers/` — one file per credential provider, bind-mounted into the container at `/app/providers/`. `server.js` loads all `*.js` files from that directory at startup and dispatches requests by pathname. Adding a new provider means dropping a file in `providers/` and restarting the broker. Exposed routes:

| Path | Who calls it | Notes |
|---|---|---|
| `/github/token` | proxy `010_github.py` | Installation token, cached with 5-min safety window. Audits the scope it carries (`permissions`, `repository_selection`) |
| `/github/credential` | cred-gateway → lab git helper | Same token in `git credential` format, same scope audited |
| `/github/identity` | cred-gateway → setup-start.sh | App name+email for `git config`, lifetime-cached |
| `/anthropic/cred` | proxy `020_anthropic.py` | Returns `{type, value}`; prefers `ANTHROPIC_AUTH_TOKEN_PATH` (OAuth) over `ANTHROPIC_API_KEY_PATH`, read fresh on each uncached call |
| `/cloudflare/token?profile=` | proxy `030_cloudflare.py` | Mints scoped token via Cloudflare API, cached per profile. The `profile` param is a cross-check against the broker's own `CLOUDFLARE_PROFILE`, not an input — a mismatch is a 403 |
| `/gcp/token` | proxy `040_gcp.py`, **and** cred-gateway → lab | SA access token by either shape: `impersonated_service_account` (refresh token → user access token → `generateAccessToken`) or `service_account` (RS256 JWT-bearer, no user, never expires). Cached per SA. Rejects a bare `authorized_user` ADC and `external_account`, and cross-checks the SA against `GCP_SERVICE_ACCOUNT`. Audits the SA email, expiry and which shape produced it, never the token |
| `/healthz` | Docker healthcheck | |

The broker makes direct outbound HTTPS calls to `api.github.com` and `api.cloudflare.com` — it does **not** go through the proxy. Routing through the proxy would be circular (proxy fetches creds from broker to authenticate outbound calls).

`stack/broker/audit.js`, baked into the image alongside `server.js`, is a JSONL writer any provider can use: `require("../audit").logEvent("token_issued", { provider: "github" })`. It writes to `AUDIT_LOG` if set and is a silent no-op otherwise, so providers that call it keep working in deployments that have not wired up the `audit-logs` volume. Log the shape of what happened, never a credential value.

### proxy (`stack/proxy/`)

mitmproxy with addons from two places. `entrypoint.sh` passes the **baked** ones at `/opt/agent-proxy/addons/` to `mitmdump` first, then globs `*.py` from the deployment's bind mount at `/addons/` in alphabetical order, skipping any file whose basename it already loaded and warning by name. Dropping a new addon file into the mount and restarting the container is sufficient to load it; numeric prefixes control load order *within* the mount, but the base addons are first by construction rather than by alphabetical luck.

`000_policy.py` and `001_allowlist.py` are baked in as of 1.10.0 (#62). Not into `/addons` — a bind mount replaces that directory wholesale, which is exactly how a deployment with an empty `proxy/` ran with no internal-host block at all and could reach `broker:8080/anthropic/cred` through the proxy. A control the deployment does not get to choose belongs in the image; see `cred-gateway`'s baked `nginx.conf` for the same shape. Current addons:

- **`000_policy.py`** — baked in. Blocks any request destined for `broker` or `cred-gateway` hostnames, or whatever `POLICY_INTERNAL_HOSTS` names instead. Loads first. On the path it covers — a request *through* the proxy, which sits on both networks — it is the only control, not a second layer behind Docker network isolation; that isolation stops the lab routing to the broker directly, and does nothing about the proxy being asked to.
- **`010_github.py`** — matches `api.github.com` and `uploads.github.com` only. Fetches token from broker, injects as `Authorization: token ...`. Strips whatever the client sent. **Does not match `github.com`** — git push/pull goes through the credential helper path, not here.
- **`020_anthropic.py`** — matches `api.anthropic.com`. Injects the API key. Blocks `/v1/organizations/*` (Admin API). Uses `responseheaders` hook + `flow.response.stream = True` for SSE to avoid buffering streamed responses.
- **`030_cloudflare.py`** — matches `api.cloudflare.com`. Injects a scoped token. Which profile comes from `CLOUDFLARE_PROFILE` on the proxy service (default `workers-deploy`); `X-Cf-Profile` is stripped and discarded, never read.
- **`040_gcp.py`** — matches `*.googleapis.com` via `hostmatch`. Two behaviours: a token exchange at `sts.`/`oauth2.googleapis.com` is **answered locally** with the inert `proxy-injected` value so a client library's credential chain completes without reaching Google; every other `*.googleapis.com` request gets the client's auth stripped and a broker-minted token injected. Which SA comes from `GCP_SERVICE_ACCOUNT` on the proxy service.

All addons cache credentials with a 5-minute TTL (`cachetools.TTLCache`). A 401 from GitHub clears the cache immediately.

`stack/proxy/audit.py` is baked into the image at `/opt/agent-proxy` and put on `PYTHONPATH` (see Dockerfile) so any addon — including ones bind-mounted from an example — can `import audit` and call `audit.log_event("blocked", host=host)` regardless of load order. Same no-op-when-`AUDIT_LOG`-unset behavior as the broker's `audit.js`.

`stack/proxy/hostmatch.py` sits beside it on the same `PYTHONPATH`, for the same reason. `hostmatch.matches(flow.request.host, ["api.example.com", "*.example.com"])` matches on label boundaries, so `*.example.com` covers `a.example.com` and `a.b.example.com` but never the `example.com` apex and never `evilexample.com`; it normalises case, a trailing root dot, and a `:port` suffix. `find()` returns *which* pattern matched, which is what lets `001_allowlist.py` keep a permitted-method set per entry on top of the shared matcher. It takes a **host string, never a flow** — it cannot tell where the string came from, so it cannot stop an addon handing it `pretty_host`; `inv_pretty_host` remains the control for that.

### cred-gateway (`stack/cred-gateway/`)

nginx image built from `stack/cred-gateway/Dockerfile` — the `nginx.conf` is baked into the image at build time (not bind-mounted). This prevents runtime config substitution.

The base image ships **no** provider endpoints: `/healthz`, then `include /etc/nginx/gateway.d/*.conf`, then `location / { return 403; }`. Whitelisted endpoints come from a bind-mounted directory of snippets, mirroring how the broker gets `/app/providers` and the proxy gets `/addons` — base image is mechanism, the deployment supplies content. `stack/cred-gateway/gateway.d/` is empty (like `stack/broker/providers/`) and holds the authoring rules in its README.

Both examples vendor `cred-gateway/github.conf`, the counterpart to their `proxy/010_github.py` and `broker/github.js`:
- `GET /github/credential` — proxies to `broker:8080/github/credential`
- `GET /github/identity` — proxies to `broker:8080/github/identity`

Snippets must use exact-match locations (`location = /path`); a prefix match like `location /github/` would expose `/github/token`. The mount source must sit outside whatever is mounted at `/workspace`, or the lab container could widen its own whitelist — `examples/dev-container` mounts `../:/workspace` so it shadows `.devcontainer` with a nested read-only bind to close that.

Everything else returns 403. `/anthropic/cred`, `/github/token`, and `/cloudflare/token` are intentionally not exposed — exposing them would allow the lab container to exfiltrate raw credentials.

`bank/gcp/cred-gateway/gcp.conf` exposes `/gcp/token`, which is the same bargain as `/github/credential` rather than an exception to the rule above: it hands the lab a real short-lived token for tooling that wants one locally rather than injected in flight. The original justification was gRPC being unmediatable; #48 measured that false, and the reason that survives is the `/github/credential` one. What that token can do is exactly the impersonated service account's IAM roles — bounding it is the deployment's job, the same way a GitHub App's permissions bound the installation token. The routes that stay unexposed are the ones handing over a *reusable* secret rather than a short-lived scoped one.

cred-gateway also writes a JSON audit line per request (`log_format audit_json` in `nginx.conf`) to `/var/log/audit/cred-gateway.jsonl`, separate from the existing stdout access log. `/healthz` opts out via `access_log off;` in its location block so healthchecks do not spam the trail. Unlike the broker/proxy helpers this is not opt-in: nginx opens configured `access_log` targets at startup and fails hard if the directory is missing, so the Dockerfile bakes in an empty `/var/log/audit` (same "valid unmounted" treatment as `gateway.d`) — the runtime volume mount just shadows it.

### observer (`stack/observer/`)

Node HTTP server on `:9000`, dependency-free like the broker. Polls `/var/log/audit/*.jsonl` every 500ms, broadcasts new lines over SSE at `/events`, and serves a minimal live-stream dashboard at `/`. Keeps a 200-event in-memory backlog so a client that connects mid-run sees recent history immediately.

Read-only consumer: mounts the `audit-logs` volume `:ro` and holds no credentials — but note it is the one service whose safety the stack cannot supply. It publishes over HTTP whatever the trail contains, and the images write no events themselves: every line comes from a bind-mounted provider or addon file the deployment owns. `observer` is therefore only as leak-free as those files are, which is why `PLAYBOOK.md`'s "What is safe to log" is addressed to whoever writes them. Detects `log-rotator`'s `copytruncate` rotation (file size shrinking means "start over from offset 0") rather than needing a reopen signal. Not on `secure` or `lab` — see "Non-obvious invariants" below — and its published port is bound to `127.0.0.1` on the host, so it's viewable from outside the stack but not from inside it.

### log-rotator (`stack/log-rotator/`)

Alpine + `logrotate` + busybox `crond`, mounting `audit-logs` read-write. `entrypoint.sh` runs `mkdir -p /var/log/audit && chmod 1777 /var/log/audit` on every start — idempotent, self-healing — then `crond` runs `logrotate` hourly against `/etc/logrotate.d/audit-logs` (`daily` + `maxsize 50M`, `rotate 14`, `dateext`, `copytruncate`).

Runs as root, unlike every other service in this stack. That's deliberate here, not an oversight: broker (`node`) and proxy (`mitmproxy`) are different non-root uids writing into the same shared directory, and only a root process can reliably chmod it for both and copytruncate files regardless of which uid created them.

### lab container (`stack/lab/`, `examples/*/lab/`)

`stack/lab/` is the minimal base image (Node 22 + curl + jq + ca-certificates). Individual examples extend it with their own `lab/Dockerfile` adding tools specific to that use case (e.g., `gh` CLI and `wrangler` in the dev-container example).

`setup.sh` (postCreateCommand, idempotent):
1. Installs the mitmproxy CA cert into the system trust store
2. Wires `git credential.helper` to `curl $GIT_CREDENTIAL_URL`
3. Forces `gh` to use HTTPS (not SSH) to prevent bypassing the proxy
4. Verifies broker is unreachable — exits non-zero if it is (security boundary broken)
5. Calls `setup-start.sh`

`setup-start.sh` (postStartCommand, runs on every restart):
1. Fetches GitHub App identity from cred-gateway and writes `git config user.name/email`
2. Smoke-checks that `gh api /rate_limit` works through the proxy

## Non-obvious invariants

**Never use `flow.request.pretty_host` for a security decision in an addon** — see `PLAYBOOK.md`'s generation constraints for the rule (match `flow.request.host` instead). Concretely, every addon originally matched `pretty_host`, which meant `curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/` made the proxy inject the real Anthropic key into a request delivered to `my-server`, and `-H 'Host: anything'` walked `000_policy.py` straight through to `broker:8080/github/token`. `tests/integration/20`, `25` and `30` cover each addon against regressing on this.

**Which credential an addon attaches is deployment config, never request data** — see `PLAYBOOK.md`'s generation constraints for the rule. `030_cloudflare.py` shipped the counter-example until 1.6.0: `X-Cf-Profile` selected the profile, so a `dev`/`qa`/`prod-ir` ladder was decorative and the audit line recorded the escalated profile as authorised. `CLOUDFLARE_PROFILE` on the proxy service replaces it, the broker rejects any other profile as defense-in-depth, and `header_selector` in `scripts/lib/invariants.sh` catches the next addon that reaches for the same shortcut. Stripping a client header is not reading it — a bare `pop()`/`del` is correct and does not trip the check.

**A wildcard host pattern is safe for credential injection only when the entire suffix is single-tenant** — see `PLAYBOOK.md`'s generation constraints for the rule. The allowlist and an injection addon both match hosts but carry different blast radius: a too-wide allowlist entry means the agent can *reach* something it should not, a too-wide injection match means a live token is *handed* to whoever owns the name. `*.googleapis.com` is fine because Google holds every name beneath it; `*.workers.dev` is not, because anyone can register one. `injection_wildcard_multitenant` fails on a known list in `scripts/lib/invariants.sh` and `injection_wildcard` notes on every other wildcard — deliberately a note, since #41 ships a legitimate one and the list will never be complete. Both are scoped to addons that actually attach a credential header, so `001_allowlist.py` is not told off for the entries it exists to hold.

**The base addons are baked into the proxy image, and the deployment-checking scripts invert around `v1.10.0`.** Below it, an unvendored `000_policy.py` is a missing control and `check-drift.sh` hard-fails; at or above it the image carries it and a vendored copy is a note — dead weight the entrypoint ignores. `check-drift.sh` derives which from the deployment's pin, and treats a non-tag pin as "below" because that direction fails closed. `check-invariants.sh` deliberately reads no pin (it is a property-of-the-file-in-front-of-you scanner), so it downgraded existence to a note and keeps ordering as a failure.

**Hostname comparisons in an addon must be normalised.** `000_policy.py` compared a raw host against a lowercase set until 1.9.2, so `http://BROKER:8080/github/token` through the proxy returned 200 with the broker's body — DNS is case-insensitive, and a trailing root dot did the same. Use `hostmatch.normalize()`, or a local mirror of it in a file deployments vendor at pins predating `hostmatch.py` (1.7.0). `tests/integration/20` covers it.

**`GH_TOKEN=proxy-injected` and `CLOUDFLARE_API_TOKEN=proxy-injected` are dummy values, never real ones** — see `PLAYBOOK.md`'s Known Providers / generation constraints for why.

**`010_github.py` must not match `github.com`** — see `PLAYBOOK.md`'s GitHub section for why (conflicts with git's own Basic-auth handshake inside the MITM'd tunnel for push/pull).

**`020_anthropic.py` uses `responseheaders`, not `response`** — see `PLAYBOOK.md`'s Anthropic section for why (avoids buffering streamed SSE responses).

**The broker's `identityCache` and `installationScopeCache` are lifetime-cached.** Both describe things only a human changes in GitHub's UI — the App's name, and whether the installation is granted `all` repositories or `selected` ones. Restart the broker to refresh either. All other caches are TTL-based (5 minutes).

**`repository_selection` needs its own API call; `permissions` does not.** `auth({ type: "installation" })` returns `permissions` on the authentication object, so `github.js` gets it free. It does *not* return `repository_selection`, and `repositoryIds`/`repositoryNames` appear only when passed *in* as narrowing options — which the broker does not do. So the installation's repository scope is unknowable from the token itself, and `getInstallationScope()` calls `GET /app/installations/{id}` with the App JWT to get it. Do not "simplify" that away by reading it off the auth object.

**CA cert persistence.** The mitmproxy CA cert lives in the `proxy-certs` named Docker volume, shared between the `proxy` container (where it's generated) and the `lab` container (read-only). The proxy's healthcheck gates on the cert file existing, so `postCreateCommand` cannot race cert generation. Removing the volume forces cert regeneration and requires a container rebuild.

**`credential.useHttpPath false` in git config** is intentional, not a bug — see `PLAYBOOK.md`'s GitHub section for why.

**Do not add `USER mitmproxy` to `proxy/Dockerfile`** — see `PLAYBOOK.md`'s generation constraints for the rule. Mechanism: the base image (`mitmproxy/mitmproxy`) ships a `docker-entrypoint.sh` that runs `usermod` (requires root) to align the `mitmproxy` user's UID with the mounted volume owner, then drops privileges via `gosu mitmproxy`. Adding `USER mitmproxy` makes the entrypoint run as non-root, causing `usermod` to fail with "operation not permitted". The `USER root` + `RUN pip install` block is correct; the entrypoint handles the privilege drop. Proxy stdout is also block-buffered when not attached to a tty — add `-e PYTHONUNBUFFERED=1` or `-it` when testing standalone to see logs in real time.

**`observer` and `log-rotator` deliberately have no `networks:` entry in `compose.yaml`** — see `PLAYBOOK.md`'s generation constraints for the mechanism and why not to "fix" it.

**Examples do not pick up `stack/` changes until they repin their build tag.** `stack/broker/audit.js` and `stack/proxy/audit.py` are baked into the image; example provider/addon files under `examples/*/broker/` and `examples/*/proxy/` are bind-mounted at runtime into whatever tag that example's `compose.yaml` builds from (`...git#vX.Y.Z:stack/broker`). Adding `require("../audit")` or `import audit` to an example's files before its pin reaches the release that introduced those helpers (1.1.0) would `MODULE_NOT_FOUND` at runtime. Both examples are now pinned above that (`dev-container` 1.3.1, `claude-code` 1.2.0) and call the helpers; the constraint binds the next example added, or any repin that moves one *down*. `tests/integration/00-config-lint.test.sh` derives this per example from its actual pinned tag rather than a hardcoded list, so it keeps working unattended as each example upgrades in turn.

**cred-gateway's `access_log` requires the target directory to exist at container start, unlike the broker/proxy `AUDIT_LOG` env vars.** nginx opens every configured `access_log` file during startup and fails hard (`emerg`, refuses to start) if the directory is missing — there's no equivalent to the no-op-when-unset behavior `audit.js`/`audit.py` have, since nginx.conf is static and baked in. That's why `stack/cred-gateway/Dockerfile` bakes in an empty `/var/log/audit` even though the real content lives on the mounted volume.

## Tests

Two tiers behind one facade. `tests/run.sh` dispatches to `tests/<tier>/run.sh` and passes the remaining arguments through.

- `tests/integration/` — the security boundaries, against stubs and fixtures. No credentials, free, ~60s. `00-config-lint.test.sh` needs no docker.
- `tests/e2e/` — the paths a stub cannot reach (HTTPS/CONNECT, CA cert lifecycle, `git push` through the credential helper), against a **dedicated** GitHub App and `~/.config/agent-creds-e2e`. Spends real API quota.

A bare `tests/run.sh` runs integration only — e2e must be asked for by name (`tests/run.sh e2e`, or `all` for both, fail-fast). `lib.sh` and `fixtures/` are shared. See `tests/README.md`.

## Adding a new credential provider

The mechanics — which file goes where, restart order, generation-time constraints like host-matching and exact-match locations — are documented once, for maintainers and end-users alike, in `PLAYBOOK.md` under "Adding a credential provider to an existing stack". Follow that rather than duplicating it here.

Maintainer-only steps on top of it, when the provider is being added to `stack/` itself rather than an end-user's deployment:

1. Add a credential file path env var under `broker` in the relevant `compose.yaml`.
2. Add coverage in `tests/` — at minimum a spoofed-`Host` case proving the new addon does not inject for any host but the genuine one.

## Release process

Every release branch is cut from `main`, never from another release branch. Right after tagging `vX.Y.Z` on `main`, immediately cut both of the next branches it could need, so work always has a release branch to target instead of `main` directly — the standing branch is what makes "target the release branch, not main" the default instead of something to remember:

- `release/X.Y.(Z+1)` — the next patch. Cheap to create; makes it that much quicker to start a hotfix.
- `release/X.(Y+1).0` — the next minor.

Both branch off `main` at the tag. Feature/fix branches then target whichever release branch fits (`fix/*` off the patch branch, `feature/*` off the minor branch), not `main`.

When a release branch is ready:

1. Add a `CHANGELOG.md` entry directly on the release branch (see existing entries for format — this project versions the security boundary, not the code, so most entries need no "Upgrading" section).
2. Open a PR from the release branch into `main`, get it reviewed, merge it.
3. Tag `vX.Y.Z` on `main`.
4. **Sync forward only.** Merge `main` into every still-open release branch whose version is *above* the tag you just cut. Never merge it into one below. The direction is the whole rule:

   - **Above the tag — merge `main` in.** That branch will supersede this release, so it has to contain it. Skipping this is how a fix that lands via the patch branch never reaches the minor branch: the same "forgot where to land it" risk one level up, moved from branch-creation-time to release-time. This is what makes the standing-branch approach safe.
   - **Below the tag — it is overtaken, not dormant.** This project only moves forward; no older line is supported and nothing gets backported. Releasing a minor therefore does *not* mean syncing the previous minor's still-open branch: once `v1.4.0` is tagged, `release/1.3.2` has simply been passed, and merging `main` into it would only rebuild 1.4.0 under a patch number. Leave it where it is and retarget any work still aimed at it onto the current patch branch. (If an overtaken branch ever does need to ship, rebase its unique commits onto its own tag — `git rebase --onto v1.3.1 …` — never merge `main`.)

Most `release/*` branches here are inert: level with or behind `main`, carrying no unique commits, kept deliberately as markers of where a line was cut. Nothing needs doing to them, and by the rule above nothing ever should be.

Worked example from `v1.1.0` → `v1.1.1` — the above-the-tag case: `release/1.1.1` and `release/1.2.0` were cut from `main` right after tagging `v1.1.0`. A fix (`fix/dev-container-observer`) targeted `release/1.1.1`, not `main`. Once that PR merged into `release/1.1.1`, a CHANGELOG entry went straight on `release/1.1.1`, that branch PR'd into `main`, and `main` got tagged `v1.1.1`. Immediately after, `main` was merged into `release/1.2.0` — above `1.1.1`, so it had to carry the fix forward.
