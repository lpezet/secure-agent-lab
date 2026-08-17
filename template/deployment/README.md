# Deployment template

The wiring, pinned to a release tag. Copy this directory, fill in `.env`, drop
in the providers you want, `docker compose up -d`.

```bash
git clone --depth 1 --branch v1.13.1 \
  https://github.com/lpezet/secure-agent-lab.git /tmp/sal
cp -r /tmp/sal/template/deployment ./my-deployment
cd ./my-deployment
cp .env.example .env && $EDITOR .env
docker compose up -d
```

That comes up with no credentials and the boundary intact. To give it one, copy
a [bank](../../bank/README.md) entry in — each entry is one directory per service,
landing in the matching directory here:

```bash
cp /tmp/sal/bank/github/broker/*.js          broker/
cp /tmp/sal/bank/github/proxy/*.py           proxy/
cp /tmp/sal/bank/github/cred-gateway/*.conf  cred-gateway/
```

then set that entry's variables — `bank/<name>/provider.json` declares all of
them, and each goes in exactly one place:

| the manifest says | it goes in |
|---|---|
| `secrets[].env` + `secrets[].file` | `.env`, as `VAR=/secrets/<file>` |
| `config` | `.env` |
| `lab_env` | `lab.env` |
| `secrets[].file` | the file itself, in `~/.config/agent-creds/` |

**`compose.yaml` is never edited.** Nothing provider-specific is in it, which
is what lets a tool fetch this directory at a tag and use it verbatim —
and what stops a copied value silently overriding yours, since `environment:`
in a compose file beats `env_file:`.

`lab.env` is separate from `.env` because the lab container is the untrusted
side: `.env` holds your settings, including host paths and app ids, and the
agent has no reason to see them.

## What this is authoritative for

The **wiring**: the service graph, the two networks, the volumes and the
mounts. That is one row of the table in
[`CONCEPT.md`](../../CONCEPT.md#which-document-is-authoritative), which says what
each of the other artefacts owns.

## What you cannot switch off here

Nothing in this file grants the boundary, and removing a line cannot take it
away. The proxy's internal-host block and egress allowlist are baked into the
proxy image, and cred-gateway's default-deny is baked into its `nginx.conf`.
Mounting an empty `proxy/` does not disable the first two — it did before
`v1.10.0`, which is [#62](https://github.com/lpezet/secure-agent-lab/issues/62).

## Why it ships hardened

Audit trail on, `lab` network internal, allowlist file mounted. Whatever this
file is, it is the thing people copy — so the defaults are the strict ones, and
loosening is a visible edit. It is easier to notice a control you removed than
one you never had.

`examples/` holds the smaller shapes, and is where to look for a stack that
does less on purpose.

## The three seams

| directory | mounts at | holds |
|---|---|---|
| `broker/` | `/app/providers` | credential providers, one file per provider |
| `proxy/` | `/addons` | injection addons, one file per provider |
| `cred-gateway/` | `/etc/nginx/gateway.d` | whitelist snippets, only where the lab must hold a credential itself |

Empty here, and a stack with all three empty still comes up — the broker
answers 404 on every credential route and cred-gateway denies everything but
`/healthz`.

`allowlist` is deliberately **not** one of them: it is data, not an addon, and
`proxy/` lands wholesale at `/addons`, so a data file placed there would be
loaded as code.

## Running more than one

The observer publishes a host port, so two copies of this template on one
machine would collide on 9000. Set it empty and Docker picks a free one:

```bash
printf 'OBSERVER_PORT=\n' >> .env
docker compose up -d
docker compose port observer 9000      # 127.0.0.1:64805
```

Leave it unset for the historical 9000. A number works too, but then something
has to remember which deployment owns which port — that is state that can be
wrong, and asking Docker makes the collision impossible instead of tracked.

Either way the dashboard stays on `127.0.0.1`: that prefix is literal in
`compose.yaml` and no value of `OBSERVER_PORT` can move it. The observer serves
the audit trail over plain HTTP with no auth, and is safe only for being
unreachable off the host.

## Turning the dashboard off

`observer` sits behind a compose profile, so switching it off is a value rather
than an edit — a deployment that deleted the service block would look, to
`check-drift.sh` and to anything else comparing it with this template, like one
that had diverged:

```bash
COMPOSE_PROFILES=            # in .env — keep the line, empty it
docker compose --profile observer rm --stop --force observer
```

and back on, without touching anything else or losing the trail it was serving:

```bash
docker compose --profile observer up -d observer
```

**Keep the `COMPOSE_PROFILES` line in `.env` even when empty.** Compose reads an
absent one as "no profiles", so deleting it turns the dashboard off silently.
Only the viewer is optional: the three services that *write* the trail and
`log-rotator` which bounds it are unprofiled, so this costs you the dashboard,
never the audit trail.

## Keeping it current

```bash
scripts/check-drift.sh /path/to/my-deployment
```

reads the pin out of `compose.yaml`, fetches that tag, and reports what has
moved. See [`PLAYBOOK.md`](../../PLAYBOOK.md)'s *Upgrading* section for the rest.
