# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker setup to run autonomous agents/harness (e.g. Claude Code) without exposing long-lived credentials to the agent's process. The agent's outbound HTTPS traffic is intercepted by mitmproxy, which injects credentials fetched from a broker the agent cannot reach directly.

## Architecture

```
[dev container]  ──HTTPS──►  [proxy: mitmproxy]  ──injects creds──►  external APIs
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

broker, proxy, and cred-gateway each write a structured JSONL audit trail (what got injected/blocked/issued, never a credential value) to a shared `audit-logs` named volume. `observer` tails it and serves a live view; `log-rotator` keeps it bounded. Neither has a `networks:` entry — they reach the volume without joining `secure` or `dev`, so the audit trail cannot become a new channel between the two. See the `observer` and `log-rotator` sections below.

**Two Docker networks enforce the security boundary:**

- `secure`: broker + proxy + cred-gateway. Dev container is **not** on this network.
- `dev`: dev + proxy + cred-gateway.

The broker is on `secure` only. Docker DNS will not resolve `broker` from within the dev container, and there is no route even if it did. The only broker-adjacent surface reachable from dev is the two nginx-whitelisted paths on cred-gateway.

**One directory per service, named after the service — in both `stack/` and `examples/`.**

```
                      stack/ (builds the image)      examples/ (supplies content)
broker         →      broker/providers/*.js          broker/*.js
proxy          →      proxy/addons/*.py              proxy/*.py
cred-gateway   →      cred-gateway/gateway.d/*.conf  cred-gateway/*.conf
dev            →      dev/Dockerfile                 dev/Dockerfile
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
| `/github/token` | proxy `010_github.py` | Installation token, cached with 5-min safety window |
| `/github/credential` | cred-gateway → dev git helper | Same token in `git credential` format |
| `/github/identity` | cred-gateway → setup-start.sh | App name+email for `git config`, lifetime-cached |
| `/anthropic/key` | proxy `020_anthropic.py` | Reads key file on each uncached call |
| `/cloudflare/token?profile=` | proxy `030_cloudflare.py` | Mints scoped token via Cloudflare API, cached per profile |
| `/healthz` | Docker healthcheck | |

The broker makes direct outbound HTTPS calls to `api.github.com` and `api.cloudflare.com` — it does **not** go through the proxy. Routing through the proxy would be circular (proxy fetches creds from broker to authenticate outbound calls).

`stack/broker/audit.js`, baked into the image alongside `server.js`, is a JSONL writer any provider can use: `require("../audit").logEvent("token_issued", { provider: "github" })`. It writes to `AUDIT_LOG` if set and is a silent no-op otherwise, so providers that call it keep working in deployments that have not wired up the `audit-logs` volume. Log the shape of what happened, never a credential value.

### proxy (`stack/proxy/`)

mitmproxy with addons in `stack/proxy/addons/`, bind-mounted into the container at `/addons/`. `entrypoint.sh` globs `*.py` files from that directory at startup and passes them to `mitmdump` in alphabetical order — dropping a new addon file and restarting the container is sufficient to load it. Numeric prefixes control load order. Current addons:

- **`000_policy.py`** — blocks any request destined for `broker` or `cred-gateway` hostnames (defense-in-depth; Docker network isolation is the primary control). Must load first.
- **`010_github.py`** — matches `api.github.com` and `uploads.github.com` only. Fetches token from broker, injects as `Authorization: token ...`. Strips whatever the client sent. **Does not match `github.com`** — git push/pull goes through the credential helper path, not here.
- **`020_anthropic.py`** — matches `api.anthropic.com`. Injects the API key. Blocks `/v1/organizations/*` (Admin API). Uses `responseheaders` hook + `flow.response.stream = True` for SSE to avoid buffering streamed responses.
- **`030_cloudflare.py`** — matches `api.cloudflare.com`. Injects a scoped token. Caller can hint a profile via `X-Cf-Profile` header (stripped before forwarding); defaults to `workers-deploy`.

All addons cache credentials with a 5-minute TTL (`cachetools.TTLCache`). A 401 from GitHub clears the cache immediately.

`stack/proxy/audit.py` is baked into the image at `/opt/agent-proxy` and put on `PYTHONPATH` (see Dockerfile) so any addon — including ones bind-mounted from an example — can `import audit` and call `audit.log_event("blocked", host=host)` regardless of load order. Same no-op-when-`AUDIT_LOG`-unset behavior as the broker's `audit.js`.

### cred-gateway (`stack/cred-gateway/`)

nginx image built from `stack/cred-gateway/Dockerfile` — the `nginx.conf` is baked into the image at build time (not bind-mounted). This prevents runtime config substitution.

The base image ships **no** provider endpoints: `/healthz`, then `include /etc/nginx/gateway.d/*.conf`, then `location / { return 403; }`. Whitelisted endpoints come from a bind-mounted directory of snippets, mirroring how the broker gets `/app/providers` and the proxy gets `/addons` — base image is mechanism, the deployment supplies content. `stack/cred-gateway/gateway.d/` is empty (like `stack/broker/providers/`) and holds the authoring rules in its README.

Both examples vendor `cred-gateway/github.conf`, the counterpart to their `proxy/010_github.py` and `broker/github.js`:
- `GET /github/credential` — proxies to `broker:8080/github/credential`
- `GET /github/identity` — proxies to `broker:8080/github/identity`

Snippets must use exact-match locations (`location = /path`); a prefix match like `location /github/` would expose `/github/token`. The mount source must sit outside whatever is mounted at `/workspace`, or the dev container could widen its own whitelist — `examples/dev-container` mounts `../:/workspace` so it shadows `.devcontainer` with a nested read-only bind to close that.

Everything else returns 403. `/anthropic/key`, `/github/token`, and `/cloudflare/token` are intentionally not exposed — exposing them would allow the dev container to exfiltrate raw credentials.

cred-gateway also writes a JSON audit line per request (`log_format audit_json` in `nginx.conf`) to `/var/log/audit/cred-gateway.jsonl`, separate from the existing stdout access log. `/healthz` opts out via `access_log off;` in its location block so healthchecks do not spam the trail. Unlike the broker/proxy helpers this is not opt-in: nginx opens configured `access_log` targets at startup and fails hard if the directory is missing, so the Dockerfile bakes in an empty `/var/log/audit` (same "valid unmounted" treatment as `gateway.d`) — the runtime volume mount just shadows it.

### observer (`stack/observer/`)

Node HTTP server on `:9000`, dependency-free like the broker. Polls `/var/log/audit/*.jsonl` every 500ms, broadcasts new lines over SSE at `/events`, and serves a minimal live-stream dashboard at `/`. Keeps a 200-event in-memory backlog so a client that connects mid-run sees recent history immediately.

Read-only consumer: mounts the `audit-logs` volume `:ro` and holds no credentials. Detects `log-rotator`'s `copytruncate` rotation (file size shrinking means "start over from offset 0") rather than needing a reopen signal. Not on `secure` or `dev` — see "Non-obvious invariants" below — and its published port is bound to `127.0.0.1` on the host, so it's viewable from outside the stack but not from inside it.

### log-rotator (`stack/log-rotator/`)

Alpine + `logrotate` + busybox `crond`, mounting `audit-logs` read-write. `entrypoint.sh` runs `mkdir -p /var/log/audit && chmod 1777 /var/log/audit` on every start — idempotent, self-healing — then `crond` runs `logrotate` hourly against `/etc/logrotate.d/audit-logs` (`daily` + `maxsize 50M`, `rotate 14`, `dateext`, `copytruncate`).

Runs as root, unlike every other service in this stack. That's deliberate here, not an oversight: broker (`node`) and proxy (`mitmproxy`) are different non-root uids writing into the same shared directory, and only a root process can reliably chmod it for both and copytruncate files regardless of which uid created them.

### dev container (`stack/dev/`, `examples/*/dev/`)

`stack/dev/` is the minimal base image (Node 22 + curl + jq + ca-certificates). Individual examples extend it with their own `dev/Dockerfile` adding tools specific to that use case (e.g., `gh` CLI and `wrangler` in the dev-container example).

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

**Never use `flow.request.pretty_host` for a security decision in an addon.** It prefers the client-supplied `Host` header, which the dev container fully controls, while mitmproxy connects to `flow.request.host` (absolute-form URI, CONNECT authority, or TLS SNI). Every addon originally matched `pretty_host`, which meant `curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/` made the proxy inject the real Anthropic key into a request delivered to `my-server`, and `-H 'Host: anything'` walked `000_policy.py` straight through to `broker:8080/github/token`. Always match on `flow.request.host`. `tests/integration/20`, `25` and `30` cover each addon.

**`GH_TOKEN=proxy-injected` and `CLOUDFLARE_API_TOKEN=proxy-injected` are dummy values.** They exist to satisfy client-side "am I authenticated?" checks in `gh` and `wrangler`. The proxy strips them at the wire level and injects real tokens. Do not replace them with real values — the whole point is that dev never holds real credentials.

**`010_github.py` must not match `github.com`.** Git push/pull to `github.com` goes through the HTTPS credential helper (via cred-gateway), not through token injection. Adding `github.com` to the addon would conflict with git's HTTP Basic auth handshake inside the MITMed tunnel.

**`020_anthropic.py` uses `responseheaders`, not `response`.** Accessing `flow.response.content` for a streamed response would buffer the entire body. The addon sets `flow.response.stream = True` in `responseheaders` so SSE chunks pass through immediately.

**The broker's `identityCache` is lifetime-cached.** If the GitHub App is renamed, restart the broker to refresh it. All other caches are TTL-based (5 minutes).

**CA cert persistence.** The mitmproxy CA cert lives in the `proxy-certs` named Docker volume, shared between the `proxy` container (where it's generated) and the `dev` container (read-only). The proxy's healthcheck gates on the cert file existing, so `postCreateCommand` cannot race cert generation. Removing the volume forces cert regeneration and requires a container rebuild.

**`credential.useHttpPath false` in git config** means one installation token is used for all repos regardless of path. This is intentional — the GitHub App's installation already scopes which repos it can access.

**Do not add `USER mitmproxy` to `proxy/Dockerfile`.** The base image (`mitmproxy/mitmproxy`) ships with a `docker-entrypoint.sh` that runs `usermod` (requires root) to align the `mitmproxy` user's UID with the mounted volume owner, then drops privileges via `gosu mitmproxy`. Adding `USER mitmproxy` makes the entrypoint run as non-root, causing `usermod` to fail with "operation not permitted". The `USER root` + `RUN pip install` block is correct; the entrypoint handles the privilege drop. Proxy stdout is also block-buffered when not attached to a tty — add `-e PYTHONUNBUFFERED=1` or `-it` when testing standalone to see logs in real time.

**`observer` and `log-rotator` deliberately have no `networks:` entry in `compose.yaml`.** Omitting it does not isolate a service by itself — Compose attaches services with no explicit `networks:` to an implicit `default` network — but since every other service (`broker`, `proxy`, `cred-gateway`, `dev`) declares an explicit `networks:` list and never touches `default`, that implicit network ends up containing only `observer` and `log-rotator`, with no route to anything else. They reach `audit-logs` because Docker volumes are not network-scoped, not because they're on `secure` or `dev`. Do not "fix" this by adding a `networks:` entry — that would give `observer`, whose whole job is a host-facing dashboard, a route into `secure`.

**Examples do not pick up `stack/` changes until they repin their build tag.** `stack/broker/audit.js` and `stack/proxy/audit.py` are baked into the image; example provider/addon files under `examples/*/broker/` and `examples/*/proxy/` are bind-mounted at runtime into whatever tag that example's `compose.yaml` builds from (`...git#vX.Y.Z:stack/broker`). Adding `require("../audit")` or `import audit` to an example's files before its pin reaches the release that introduced those helpers (1.1.0) would `MODULE_NOT_FOUND` at runtime. `examples/dev-container` is pinned to 1.1.0 and does call the helpers; `examples/claude-code` is still on 1.0.0 and must not, until it's repinned. `tests/integration/00-config-lint.test.sh` derives this per example from its actual pinned tag rather than a hardcoded list, so it keeps working unattended as each example upgrades in turn.

**cred-gateway's `access_log` requires the target directory to exist at container start, unlike the broker/proxy `AUDIT_LOG` env vars.** nginx opens every configured `access_log` file during startup and fails hard (`emerg`, refuses to start) if the directory is missing — there's no equivalent to the no-op-when-unset behavior `audit.js`/`audit.py` have, since nginx.conf is static and baked in. That's why `stack/cred-gateway/Dockerfile` bakes in an empty `/var/log/audit` even though the real content lives on the mounted volume.

## Tests

Two tiers behind one facade. `tests/run.sh` dispatches to `tests/<tier>/run.sh` and passes the remaining arguments through.

- `tests/integration/` — the security boundaries, against stubs and fixtures. No credentials, free, ~60s. `00-config-lint.test.sh` needs no docker.
- `tests/e2e/` — the paths a stub cannot reach (HTTPS/CONNECT, CA cert lifecycle, `git push` through the credential helper), against a **dedicated** GitHub App and `~/.config/agent-creds-e2e`. Spends real API quota.

A bare `tests/run.sh` runs integration only — e2e must be asked for by name (`tests/run.sh e2e`, or `all` for both, fail-fast). `lib.sh` and `fixtures/` are shared. See `tests/README.md`.

## Adding a new credential provider

1. Add a credential file path env var under `broker` in the relevant `compose.yaml`
2. Add a provider file in `stack/broker/providers/` (follow existing pattern; expose via cred-gateway only if dev tools need raw access — almost never). Restart the broker to pick it up.
3. Add a numbered addon in `stack/proxy/addons/` following the `020_anthropic.py` or `030_cloudflare.py` pattern
4. Restart the proxy — `entrypoint.sh` auto-discovers `*.py` files in `/addons/` at startup, no Dockerfile change needed
5. Add a smoke-test section verifying injection works AND the broker endpoint is unreachable from dev
6. Add coverage in `tests/` — at minimum a spoofed-`Host` case proving the new addon does not inject for any host but the genuine one
