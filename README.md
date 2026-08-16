# Secure Agent Lab

Docker infrastructure for running autonomous agents (e.g. Claude Code) without exposing
long-lived credentials to the agent's process. Outbound HTTPS is intercepted by mitmproxy,
which injects credentials fetched from a broker the agent cannot reach directly.

**The agent never holds a credential. It holds the ability to spend one.**

[`CONCEPT.md`](CONCEPT.md) is the model — the threat it addresses, why the boundary is
drawn where it is, and what it does **not** protect against. Read that first if you are
deciding whether this fits your problem. This file is the tour.

## Repository structure

```
stack/          Core reusable infrastructure (broker, proxy, cred-gateway, observer,
                log-rotator, base lab image) — the images, and the only place a
                mandatory control lives
template/
  deployment/    The deployment template: the wiring, pinned by tag. Start here.
  provider/      Skeletons for writing a bank entry of your own
bank/           Vetted credential providers, installed as data rather than written
examples/       Two working deployments to read — see examples/README.md for how
                they differ
scripts/        check-drift.sh — does a deployment's bind-mounted files still
                match the tag it is pinned at?
                check-invariants.sh — are a deployment's own files safe on
                their own terms? (custom providers have nothing to diff)
tests/          Regression suite — integration (no credentials) and e2e (real ones)
```

**Upgrading from 0.1.0?** See [CHANGELOG.md](CHANGELOG.md). 1.0.0 fixes a
credential-disclosure bug, and two of the upgrade steps are manual — a
`docker compose pull` alone leaves you vulnerable and breaks git auth.

Each example's `compose.yaml` builds `broker`, `proxy`, and `cred-gateway` directly from
this repo's GitHub URL, so you only need the example directory itself to get started.

## How it works

```
┌─────────────────────────────────────────┐
│  lab container (Claude Code, git, gh)   │
│  HTTPS_PROXY=http://proxy:8080          │  network: lab
│  GIT_CREDENTIAL_URL=http://cred-gateway │
│  No credentials, no .env, no API keys   │
└────┬─────────────────────────┬──────────┘
     │ HTTPS (intercepted)     │ git creds only
     ▼                         ▼
┌──────────────┐   ┌─────────────────────┐
│  proxy       │   │  cred-gateway       │
│  mitmproxy   │   │  nginx, whitelist:  │
│  + addons    │   │  /github/credential │
│              │   │  /github/identity   │
└──────┬───────┘   └──────────┬──────────┘
       │                      │
       │     network: secure  │
       │     (no lab access)  │
       ▼                      ▼
┌─────────────────────────────────────────┐
│  broker                                 │
│  - Reads .pem / api keys from /secrets  │
│  - Mints GitHub installation tokens     │
│  - Injects Anthropic API key            │
│  - Mints scoped Cloudflare tokens       │
└─────────────────────────────────────────┘
             │
             ▼
        ~/.config/agent-creds/   (read-only bind mount)
```

Two Docker networks enforce the boundary: `secure` (broker, proxy, cred-gateway) and
`lab` (lab, proxy, cred-gateway), with the lab container never on `secure` and the `lab`
network `internal: true` so the proxy is the only route out. Why each of those matters,
and what breaks without it, is in [`CONCEPT.md`](CONCEPT.md#the-approach).

### Why cred-gateway exists

Git authenticates to `github.com` with HTTP Basic auth *inside* the TLS tunnel, which
collides with token injection — so `010_github.py` deliberately does not match
`github.com`, and git needs a credential locally instead. cred-gateway is the narrow
bridge that hands one over: nginx on both networks, denying everything by default,
exposing only the paths a deployment whitelists.

The proxy handles API traffic by injection; cred-gateway handles git's credential helper
through a tightly scoped whitelist. Which routes may be exposed and which may not is a
single rule, stated in [`CONCEPT.md`](CONCEPT.md#why-cred-gateway-exists).

### Audit logging

broker, proxy, and cred-gateway each write a structured, secret-free JSONL trail — what got
injected, blocked, or issued, never a credential value — to a shared `audit-logs` volume.
`observer` tails it and serves a live view at `http://localhost:9000` (loopback-only: viewable
from the host, not from `lab` or `secure`, so it cannot become a new channel between the two).
`log-rotator` keeps the files bounded with `logrotate`.

On by default in [`template/deployment/`](template/deployment/README.md) and in the VS Code dev container example
below. Deliberately absent from `examples/claude-code`, which is the smaller shape: the audit
helpers are opt-in and no-op without `AUDIT_LOG`, so dropping the trail means dropping
`observer`, `log-rotator` and the `audit-logs` volume together rather than half-configuring
them. (`stack/CLAUDE.md` has a smoke-test walkthrough that needs no real credentials.)

## Quick start

### Build your own deployment

[`template/deployment/`](template/deployment/README.md) is the wiring, pinned to a release tag and fetched the same
way a `bank/` entry is. It ships the hardened shape — audit trail on, `lab` network internal,
allowlist mounted — because it is the thing people copy, and it is easier to notice a control
you removed than one you never had.

```bash
git clone --depth 1 --branch v1.11.2 \
  https://github.com/lpezet/secure-agent-lab.git /tmp/sal
cp -r /tmp/sal/template/deployment ./my-deployment && cd ./my-deployment
cp .env.example .env && $EDITOR .env
docker compose up -d
```

That comes up with no credentials and the boundary intact; add one by copying a
[`bank/`](bank/README.md) entry into `broker/`, `proxy/` and `cred-gateway/`.

### Or start from an example

Two working deployments, pinned and meant to be read — [`examples/README.md`](examples/README.md)
says how they differ and which axis is which. In short: `claude-code` is the smaller shape
(4 services, no audit trail) and `dev-container` is the fuller one delivered as a VS Code
devcontainer. Each has its own README with prerequisites, credential setup, and the security
checks to run against it.

## Extending the stack

### Adding a credential provider

Two ways, and the first is usually right:

**Install one from [`bank/`](bank/README.md).** Vetted, versioned, and installable as data —
one directory per service, copied into the matching directory of your deployment. No code to
write and nothing to get subtly wrong.

**Write one.** [`PLAYBOOK.md`](PLAYBOOK.md) has the whole procedure — which file goes where,
restart order, and the generation-time constraints that exist because each one has been
violated at least once here. Every deployment is one directory per service, holding exactly
the files that service loads:

```
broker/        *.js    → /app/providers
proxy/         *.py    → /addons
cred-gateway/  *.conf  → /etc/nginx/gateway.d
```

The one decision worth making deliberately is whether a `cred-gateway/` snippet is needed at
all. If the credential is only ever spent on an outbound API call, it is not — that is the
difference between the agent never seeing a secret and it holding one. See
[`CONCEPT.md`](CONCEPT.md#why-cred-gateway-exists) for the rule.

### Proxy allowlist

The proxy can restrict outbound destinations to an explicit list. It is **off by default**:
with no allowlist file mounted every destination is permitted and the proxy warns at startup,
so a half-enabled allowlist fails open rather than silently blocking.

Turning it on is one file, not two. Since `v1.10.0` the addon is in the proxy image — there
is nothing to copy — so all a deployment supplies is the data:

```yaml
  proxy:
    volumes:
      - ./allowlist:/etc/agent-allowlist:ro
```

[`template/deployment/allowlist`](template/deployment/allowlist) ships this mount already wired, with the file
present and empty of entries. The list must sit **outside** `proxy/`, because that directory
is mounted wholesale as `/addons` — a data file placed there would be loaded as an addon.

One entry per line, `domain [METHODS]`, methods defaulting to `GET,HEAD,OPTIONS`. Matching is
on label boundaries, so `*.example.com` covers `a.b.example.com` but never the `example.com`
apex and never `evilexample.com`. [`PLAYBOOK.md`](PLAYBOOK.md) has the full format and the
edge cases; restart the proxy after editing:

```bash
docker compose up -d --force-recreate proxy
```

## Security notes

The threat model, and what this does **not** protect against, are in
[`CONCEPT.md`](CONCEPT.md#what-this-does-not-protect-against). What follows is specific to
the pieces above.

- `GH_TOKEN=proxy-injected` and `ANTHROPIC_API_KEY=proxy-injected` are deliberate dummy
  values. They satisfy client-side "am I authenticated?" checks without holding real secrets.
  The proxy strips them at the wire and injects the real credentials.
- `020_anthropic.py` blocks `/v1/organizations/*` (Anthropic Admin API) — the agent can use
  the API but cannot enumerate or manage org resources.
- The broker never routes through the proxy. It makes direct HTTPS calls to `api.github.com`
  and `api.cloudflare.com`. Routing through the proxy would be circular.
- `observer` and `log-rotator` have no `secure`/`lab` network membership — they reach the
  `audit-logs` volume without joining either, so the audit trail cannot become a new channel
  between the two.

## License

MIT — see [LICENSE](LICENSE).
