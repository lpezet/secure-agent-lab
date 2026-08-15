# Deployment template

The wiring, pinned to a release tag. Copy this directory, fill in `.env`, drop
in the providers you want, `docker compose up -d`.

```bash
git clone --depth 1 --branch v1.10.1 \
  https://github.com/lpezet/secure-agent-lab.git /tmp/sal
cp -r /tmp/sal/template ./my-deployment
cd ./my-deployment
cp .env.example .env && $EDITOR .env
docker compose up -d
```

That comes up with no credentials and the boundary intact. To give it one, copy
a [bank](../bank/README.md) entry in — each entry is one directory per service,
landing in the matching directory here:

```bash
cp /tmp/sal/bank/github/broker/*.js          broker/
cp /tmp/sal/bank/github/proxy/*.py           proxy/
cp /tmp/sal/bank/github/cred-gateway/*.conf  cred-gateway/
```

then set that provider's variables in `.env` and put its credential file in
`~/.config/agent-creds/`. `bank/<name>/provider.json` lists both.

## What this is authoritative for

The **wiring**: the service graph, the two networks, the volumes and the
mounts. That is one row of the table in
[`CONCEPT.md`](../CONCEPT.md#which-document-is-authoritative), which says what
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

## Keeping it current

```bash
scripts/check-drift.sh /path/to/my-deployment
```

reads the pin out of `compose.yaml`, fetches that tag, and reports what has
moved. See [`PLAYBOOK.md`](../PLAYBOOK.md)'s *Upgrading* section for the rest.
