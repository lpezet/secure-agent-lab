# Examples

Two working deployments. Both are real and both are pinned to a release tag;
they differ along two axes, and it is worth knowing which before you copy one.

| | services | audit trail | how you use it |
|---|---|---|---|
| [`claude-code/`](claude-code/) | 4 | no | `docker compose up`, then attach to the container |
| [`dev-container/`](dev-container/) | 6 | yes | VS Code **Dev Containers: Reopen in Container** |

**The service count is the hardening axis.** `claude-code` is the smaller
shape: no `observer`, no `log-rotator`, no `audit-logs` volume. That is a
deployment choice rather than a half-finished upgrade — the audit helpers are
opt-in and no-op without `AUDIT_LOG`, so dropping the trail coherently means
dropping all three together. `dev-container` keeps them and gets the live
dashboard on `localhost:9000`.

**The delivery mechanism is a different axis, and it is not a hardening
level.** `dev-container` is a devcontainer: VS Code owns the lifecycle, which
is why its compose file lives under `.devcontainer/` and why it has a
`postCreateCommand`. Reading the two as one scale — "light" and "hardened" —
would be wrong, because the audit trail and the editor integration vary
independently.

**Neither is the template.** For a deployment of your own, start from
[`template/deployment/`](../template/deployment/README.md): it ships the hardened shape, is fetched
by tag the way a `bank/` entry is, and is the artefact that is authoritative
for the wiring. These two exist to be *read* — each vendors a real provider set
you can follow end to end, and each has a README with the security checks you
can run against it.

## What they share

Both build `broker`, `proxy`, `cred-gateway` (and `observer`/`log-rotator`
where present) from this repo at a pinned tag, and build only their own `lab`
image locally. Both mount one directory per service, holding exactly the files
that service loads:

```
broker/        *.js    → /app/providers
proxy/         *.py    → /addons
cred-gateway/  *.conf  → /etc/nginx/gateway.d
```

Neither vendors `000_policy.py` or `001_allowlist.py`. Since `v1.10.0` the
proxy image carries both and loads them ahead of the mount — see
[`CONCEPT.md`](../CONCEPT.md)'s *what the deployment does not get to choose*.

## Keeping them current

An example pinned several releases back teaches an old boundary to whoever
copies it, which is the opposite of the job. `scripts/check-drift.sh` reads the
pin out of a `compose.yaml` and reports what has moved:

```bash
scripts/check-drift.sh examples/claude-code
```

`tests/integration/00-config-lint.test.sh` derives what to expect from each
example's *actual* pin rather than a hardcoded list, so an example can lag
deliberately without the suite going red.
