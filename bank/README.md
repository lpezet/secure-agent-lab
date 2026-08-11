# Provider bank

Vetted provider implementations, installed as data rather than copied by hand.

Every security incident this project has had came from someone writing a
provider file — the `pretty_host` class of bug, the query-string leak, the
strip-after-fetch ordering. Two of those shipped in `PLAYBOOK.md` as the
*recommended* pattern. Making the safe version the thing you **install** rather
than the thing you are **told to write** is a different kind of control from
documenting it better.

Tracking issue: [#32](https://github.com/lpezet/secure-agent-lab/issues/32).

## What an entry is

A bank entry is the complete set of files and data needed to add one provider to
a running deployment. Its correctness test:

> Someone — or something — holding only `bank/<name>/` and a running stack can
> install the provider without reading anything else in this repo.

That bar is what makes an entry *data*. If installing GitHub requires separately
knowing to set `credential.useHttpPath false`, the knowledge lives in a human or
in an installer, and adding a provider needs per-provider code somewhere.

## Layout

```
bank/
  README.md                        this file
  schema/provider.schema.json      the manifest contract
  <name>/
    provider.json                  the manifest
    broker/<name>.js               credential provider, runs on `secure`
    proxy/<name>.py                injection addon — no numeric prefix, see below
    cred-gateway/<name>.conf       whitelist snippet, only if lab must hold it
    lab/setup.sh                   optional fragment, sourced by the deployment
```

- One directory per provider, named exactly `name` in its manifest.
- Inside it, the repo's existing one-directory-per-service convention, so a
  file's mount target is answered by its parent directory.
- File basename is always `<name>.<ext>`. One file per service per entry; an
  entry needing two proxy addons is a signal it is two providers.
- **A service directory exists only if the provider needs it.** Anthropic and
  Cloudflare have no `cred-gateway/`, and that absence is itself the statement
  that their raw credential is never exposed to the lab.

## Rules

- **Match on `flow.request.host`, never `pretty_host`.** `pretty_host` prefers
  the client-supplied `Host` header, so the lab can point a request at its own
  server, spoof the header, and have the real credential injected into it. This
  is the sharpest invariant in the repo and it has been violated once already.
- **Strip the client's authentication as its own statement, before the fetch.**
  Not as a side effect of a successful fetch. When the credential source is
  unreachable the strip must still have happened, or the lab's own header goes
  to the provider untouched.
- **Never log a raw request path.** Parse to a bounded endpoint label first. A
  provider that puts its credential in the query string turns the audit trail —
  which is published over HTTP — into an exfiltration channel.
- **Declare every broker route in `broker_routes`, not just the exposed ones.**
  That is what makes the route list a control rather than documentation: the
  lint asserts that unexposed routes appear in *no* `.conf` in *any* entry.
- **Exact-match locations only** in a `.conf` — `location = /path`. A prefix
  match like `location /github/` exposes `/github/token`.
- **`hosts` must agree with the addon, exactly.** Every host in the manifest
  appears as a quoted literal in the addon, and every quoted hostname literal in
  the addon appears in the manifest. Checked both directions.
- **No numeric prefix on `proxy/<name>.py`.** The manifest declares a
  `load_band`; the installer assigns the lowest free slot in it. Baking a number
  in would make two providers wanting `030` the user's problem.

## The manifest

`provider.json`, validated against `schema/provider.schema.json`. See that file
for the full contract — every field carries its own `description`, including
what breaks when it is wrong.

Three fields are worth calling out.

**`schema_version`** is the generation of the manifest contract, and the only
thing that should ever break compatibility between this bank and a tool
installing from it. An installer supports a fixed set of generations and
**refuses anything higher** rather than doing its best with it: a manifest from
the future may declare a control the installer does not know to apply, and an
install that silently skips a control is worse than one that refuses to run.

It is an integer, not a semver, because it is a compatibility generation rather
than a version — `1.1` invites "that is probably close enough", which is the one
judgement call this field exists to remove. It is carried **per entry** rather
than once for the bank because of the standalone bar above: `bank/<name>/`
copied out on its own is still installable, and still says what it is.

Bump it for anything an installer must act on — a new field, a changed meaning,
a changed directory convention. Not for rewording a description. It should move
on the order of never; if it is moving often, the manifest has become a config
file.

Two more are worth calling out because they are easy to conflate:

**`secrets` vs `config`** are separate because the providers treat them so.
`GITHUB_APP_PRIVATE_KEY_PATH` names a file the broker reads out of the read-only
`/secrets` mount. `GITHUB_APP_ID` is passed by value through `env_file: .env`.
Two storage locations, two permission models, two prompts. A manifest that
conflated them would put an App ID under `secrets/` and prompt for it with echo
off.

**`min_stack`** is the lowest stack tag whose *image* satisfies this entry's
imports. It is the one failure that is silent at install and fatal at runtime —
`MODULE_NOT_FOUND` on `require("../audit")` — so an installer checks it first.

## How this is enforced

`tests/integration/00-config-lint.test.sh` carries the checks. Two things to
know about what that does and does not cover:

- **The schema is load-bearing, not decorative.** The lint reads `required`,
  the `load_band` enum and the `name` pattern *out of the schema* rather than
  restating them, so tightening the schema tightens the lint in the same commit.
- **It is not a full JSON Schema validation.** Running a real validator would
  add a host dependency to the one test suite that currently needs nothing but
  bash. The lint checks the properties that carry security weight; the schema is
  the complete contract for a future installer. If you add a constraint to the
  schema that the lint cannot express, say so in the field's `description`.

Manifest checks need `jq`. It is not a hard dependency — without it those
suites `skip` rather than fail, and the rest of the lint still runs.

## Adding an entry

1. Write `bank/<name>/provider.json` against the schema.
2. Add the files it implies, following the rules above. Start from the closest
   existing entry as a template — that is what they are for.
3. `tests/run.sh`. Suites A–D cover the manifest, the host agreement, the route
   exposure, and whether the examples still match the bank.
4. Anything the entry needs that the manifest cannot express is a bug in the
   schema, not a note for the playbook.

Writing a provider the bank does *not* have is a different job, and the
generation constraints for it stay in [`PLAYBOOK.md`](../PLAYBOOK.md). Those
constraints deliberately do not move here: they are how you write a provider
from scratch, which is precisely the case a bank of finished entries cannot
cover.
