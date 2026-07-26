# PLAYBOOK.md

Instructions for an AI agent — not a human reader — working in an
end-user's own project, to generate, extend, and upgrade a deployment of
the secure-agent-lab stack. This file does not assume the agent
has read this repo's `CLAUDE.md`, and it shouldn't: that file is scoped to
developing and maintaining this repo itself, not to using it. `README.md`
and `examples/` are for anyone to read; nothing here depends on them, but
browsing them is fine.

Fetch and follow this file at a pinned tag, e.g.:

```
https://raw.githubusercontent.com/lpezet/secure-agent-lab/refs/tags/vX.Y.Z/PLAYBOOK.md
```

The stack this playbook generates pins `stack/` at the same tag, the same
way `examples/*/compose.yaml` do (`...git#vX.Y.Z:stack/broker`).

## Before you start

Gather this from the end-user, asking whenever it isn't already clear —
don't guess:

- Which credential providers are needed: `github`, `anthropic` (Claude
  Code), `cloudflare`, other/custom.
- Where the stack should live in their project (e.g. `.devcontainer/`,
  `infra/agent-stack/`).
- Whether they want the `observer` dashboard.
- Which tag to pin to (default: latest release tag).

If a partial setup already exists in their project, adapt to it rather than
assuming a blank slate — use judgment, and ask the user if it's unclear
whether something already there should be kept, replaced, or extended.

## Known providers

Concrete shape for the providers this stack already ships support for.
Anything not listed here is a custom provider — see "A custom provider"
under "Adding a credential provider" below.

### GitHub

- Broker routes: `/github/token` (installation token, 5-minute safety-window
  cache), `/github/credential` (same token, `git credential` output
  format), `/github/identity` (App name + email for `git config`, cached
  for the broker's lifetime — restart the broker if the GitHub App is
  renamed).
- Proxy (`010_github.py`): matches `api.github.com` and `uploads.github.com`
  only. Never match `github.com` — git push/pull to it goes through the
  HTTPS credential helper (via `cred-gateway`), not token injection; adding
  `github.com` here would conflict with git's own Basic-auth handshake
  inside the MITM'd tunnel.
- `cred-gateway`: exact-match routes for `/github/credential` and
  `/github/identity` only, proxying to the broker. Never expose
  `/github/token` — that would hand the dev container a raw token.
- Dev container: wire `git config credential.helper` to
  `curl $GIT_CREDENTIAL_URL` (pointed at the cred-gateway route), set
  `credential.useHttpPath false` (the App's installation already scopes
  which repos it can reach — intentional, not a bug), force `gh` to HTTPS
  (`gh config set git_protocol https`) so it can't bypass the proxy over
  SSH, and set `git config user.name`/`user.email` from the
  `/github/identity` route on every container start.

### Anthropic (Claude Code)

- Broker route: `/anthropic/key` — reads the key file fresh on every call
  (cheap local read, no need to cache).
- Proxy (`020_anthropic.py`): matches `api.anthropic.com` only, injects the
  key, blocks `/v1/organizations/*` (Admin API). Must use the
  `responseheaders` hook and set `flow.response.stream = True` there —
  touching `flow.response.content` on a streamed response buffers the
  entire SSE body instead of passing chunks through live.
- No `cred-gateway` route — the raw key is never exposed to the dev
  container.

### Cloudflare

- Broker route: `/cloudflare/token?profile=` — mints a scoped token via the
  Cloudflare API per named profile, cached per profile.
- Proxy (`030_cloudflare.py`): matches `api.cloudflare.com` only, injects
  the token. The caller can hint a profile via an `X-Cf-Profile` header,
  stripped before forwarding to Cloudflare; default profile is
  `workers-deploy` if the header is absent.
- No `cred-gateway` route.
- Dev container: `CLOUDFLARE_API_TOKEN=proxy-injected` is a dummy value
  satisfying `wrangler`'s "am I authenticated" check — never replace it
  with a real token.

## Generating a stack

Produce:

- A `compose.yaml` wiring `broker`, `proxy`, `cred-gateway`, `dev`, and
  (if requested) `observer` + `log-rotator`, each pinned to `stack/<service>`
  at the chosen tag.
- One directory per service, named after the service, holding only the
  content that gets bind-mounted into it — never the service's own
  Dockerfile/image files, those live in `stack/` at the pinned tag:
  - `broker/*.js` → `/app/providers` (one file per credential provider)
  - `proxy/*.py` → `/addons` (numbered, e.g. `010_github.py`, load order is
    alphabetical)
  - `cred-gateway/*.conf` → `/etc/nginx/gateway.d`
  - `dev/Dockerfile` extending `stack/dev`'s base image with any
    project-specific tools
- The two Docker networks: `secure` (broker + proxy + cred-gateway) and
  `dev` (dev + proxy + cred-gateway). The dev container is never on
  `secure`.
- For each requested provider, the files described under "Known providers"
  above (or "A custom provider" below, for anything else).
- If `observer`/`log-rotator` are requested: no `networks:` entry for
  either — see the constraints below for why that's correct, not an
  omission.

Generation-time constraints that apply regardless of which provider is
being generated:

- Match `flow.request.host` in proxy addons, never
  `flow.request.pretty_host` — the latter is client-controlled and lets a
  spoofed `Host` header steal injected credentials or bypass the broker
  block.
- `cred-gateway` snippets must use exact-match `location = /path` blocks,
  never a prefix match — a prefix like `location /github/` exposes sibling
  routes that must stay broker-only.
- Expose a `cred-gateway` route only if dev tooling genuinely needs raw
  access to it — almost never. Raw provider tokens/keys must never be
  reachable from the dev container.
- The proxy's Dockerfile must not add `USER mitmproxy` — the base image's
  entrypoint needs to run as root initially to `usermod` the `mitmproxy`
  user before dropping privileges via `gosu`.
- The broker calls provider APIs directly, never through the proxy —
  routing through the proxy would be circular (the proxy needs the broker
  to authenticate its own outbound calls).
- If a dev-side CLI tool needs a placeholder credential to pass its own
  "am I authenticated" check (e.g. `gh`, `wrangler`), use an obvious dummy
  value and let the proxy inject the real one at the wire level — never
  put a real credential in the dev container's environment.
- `observer` and `log-rotator` must have no `networks:` entry at all —
  that's what keeps them off `secure` and `dev` (Compose's implicit
  `default` network ends up containing only the two of them, since every
  other service declares an explicit `networks:` list). Do not "fix" this
  by adding one.

Last step: write a small stub `CLAUDE.md` at the root of wherever the stack
was generated (e.g. `.devcontainer/CLAUDE.md`), recording the pinned tag and
pointing back at this file's URL for anything future related to this
stack. This keeps the reference scoped to that subdirectory instead of
bloating the end-user's top-level `CLAUDE.md`.

## Adding a credential provider to an existing stack

### A known provider

Follow the concrete shape under "Known providers" above: add the
broker/proxy/(rarely) cred-gateway files it describes, restart the
affected services, then run the relevant check from "Verifying the stack"
below.

### A custom provider

For anything not covered above:

**Broker** — add a file to the project's `broker/` directory (bind-mounted
to `/app/providers`). Reads a credential from an env-var-specified path
under `/secrets`, exposes a route, dispatches on pathname. Restart the
broker to pick it up. Log significant events via the baked-in `audit.js`
(`require("../audit").logEvent(...)`) — never log a credential value.

**Proxy** — add a numbered file to the project's `proxy/` directory
(bind-mounted to `/addons`, loaded alphabetically — pick a prefix that
puts it after `000_policy.py`). Match `flow.request.host` against the
exact provider hostname, fetch a token from the broker route added above,
inject it, strip whatever the client sent. Cache with a short TTL. Restart
the proxy — `entrypoint.sh` auto-discovers `*.py` at startup. Use the
baked-in `audit.py` (`import audit; audit.log_event(...)`) the same way.

**Cred-gateway** — only if dev tooling needs raw access to something the
broker/proxy path doesn't cover (rare). Add an exact-match snippet to the
project's `cred-gateway/` directory (bind-mounted to
`/etc/nginx/gateway.d`), proxying to a broker route. Restart cred-gateway.

## Upgrading

1. Bump the pinned tag in `compose.yaml` (and in the stub `CLAUDE.md`'s
   recorded pin) to the new tag.
2. Read this repo's `CHANGELOG.md` for every entry between the old and new
   tag, and apply anything listed under that entry's "Upgrading" section,
   if present.
3. Restart the affected services.

## Verifying the stack

Run these against the live `docker compose` stack after generating or
changing anything (adjust service names below if the generated
`compose.yaml` names them differently than `dev`, `broker`, `proxy`,
`cred-gateway`, `observer`).

**All services healthy:**

```
docker compose ps
```

Every service should be `running`/`healthy`, none restarting.

**Broker is unreachable from the dev container** — the core security
boundary, since `dev` is not on the `secure` network:

```
docker compose exec dev getent hosts broker                              # should fail to resolve
docker compose exec dev curl -sS --max-time 3 http://broker:8080/healthz # should fail to connect
```

Both failing is the pass condition; either succeeding means the network
boundary is broken.

**`cred-gateway` only serves whitelisted routes:**

```
docker compose exec dev curl -s -o /dev/null -w '%{http_code}\n' http://cred-gateway/definitely-not-a-real-path
# expect 403

docker compose exec dev curl -s -o /dev/null -w '%{http_code}\n' http://cred-gateway/github/identity
# expect 200, only if github is configured
```

**Each configured provider works end-to-end through the proxy**, using
whatever client the dev container already has for it:

```
docker compose exec dev gh api /rate_limit   # github
docker compose exec dev wrangler whoami      # cloudflare
```

For Anthropic, the check is Claude Code (or whatever agent harness runs in
the dev container) successfully making one real request — there usually
isn't a separate CLI to probe with.

**Host-spoofing resistance** (whether a proxy addon matches the real
destination rather than a client-supplied `Host` header) is what this
repo's own `tests/integration/20-proxy-policy.test.sh` and
`25-proxy-injection.test.sh` cover, against stub servers standing in for
each hostname. Reproducing that against a live stack needs a second server
for the spoofed `Host` to legitimately point at, which is more setup than a
post-generation smoke check warrants — treat it as covered by construction
(the "match `flow.request.host`" constraint above) rather than something to
re-verify by hand every time.
