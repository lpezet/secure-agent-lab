# The model

What this protects, how, and what it does not. Read this before deciding
whether the design fits your problem; [`README.md`](README.md) is the tour and
[`PLAYBOOK.md`](PLAYBOOK.md) is the how-to.

## The problem

An autonomous agent needs credentials to be useful. It needs to push to a repo,
call a model API, deploy a worker. The ordinary way to give it those is an
environment variable or a mounted key file — at which point the credential is
inside the process you are least able to reason about.

That matters more than it does for a script, for three reasons:

- **The agent runs code it wrote.** There is no review step between deciding and
  doing, so "the agent will not exfiltrate the key" is a claim about a model's
  behaviour rather than about a system's properties.
- **It is a confused deputy by construction.** It reads issues, web pages, and
  files, any of which can carry instructions. A prompt injection that reaches a
  process holding a long-lived key has that key.
- **The blast radius is the credential's, not the task's.** A token minted for
  "open a PR on one repo" is usually an org-wide PAT, because that is what was
  lying around.

## The approach

**The agent never holds a credential. It holds the ability to spend one.**

Every outbound request leaves through a proxy that attaches the credential in
flight. The agent's process, environment, filesystem and container image
contain no secret at any point — what it has is network access to something
that will authenticate on its behalf, for the specific destinations it is
allowed to reach.

```
[lab] ──HTTPS──► [proxy] ──injects──► api.github.com
  │                 │
  │ git creds only  │ fetches from
  ▼                 ▼
[cred-gateway] ─► [broker] ──reads──► ~/.config/agent-creds/
```

Three properties do the work:

**The broker is unreachable from the lab.** Not firewalled off — *unroutable*.
It sits on a Docker network the lab container has no membership in, so its name
does not resolve and there is no path to its address. Every other control here
is defence in depth behind that one.

**The lab network has no default gateway** (`internal: true`). Without this,
`HTTP_PROXY` is a request the agent can decline — `curl --noproxy '*'` leaves
the container untouched by any addon. With it, the proxy is the only way out,
which is what makes the egress allowlist enforcing rather than advisory.

**The credential is attached at the wire, to a named destination.** The addon
matches the host the connection is actually going to, mints or fetches the
credential for it, and strips whatever the client sent. A request to anywhere
else gets nothing.

## Why cred-gateway exists

The proxy cannot mediate everything, and git is the case that proves it.

Git authenticates to `github.com` with HTTP Basic auth *inside* the TLS tunnel
— a different flow from an API call with an `Authorization` header. Injecting a
token there collides with git's own handshake inside the MITM'd connection, so
`010_github.py` deliberately does not match `github.com` at all.

So git needs a credential locally, and something has to hand it over. That is
cred-gateway: an nginx sitting on both networks, denying everything by default,
exposing only the paths a deployment explicitly whitelists. It gives the lab
`/github/credential` — a short-lived installation token in git's own format —
and nothing else.

The line it draws is worth stating exactly, because it is the one judgement
call in the design:

> A route may be exposed when what it hands over is **short-lived and scoped**.
> A route that hands over a **reusable secret** stays unexposed, because at that
> point the agent holds the credential and the whole model collapses.

`/github/credential` and `/gcp/token` meet that bar — both are minted, both
expire, both carry exactly the permissions their installation or service
account was granted. `/anthropic/cred` and `/github/token` do not, and return
403.

## What the deployment does not get to choose

Some controls are the deployment's to configure. Others would be worthless if
they could be omitted by accident, so they are not configurable at all — they
are baked into the images:

| control | lives in | so that |
|---|---|---|
| internal-host block (`000_policy.py`) | proxy image | mounting an empty `proxy/` cannot remove it |
| egress allowlist (`001_allowlist.py`) | proxy image | the same, and no stale vendored copy |
| default-deny (`location / { return 403; }`) | cred-gateway image | a runtime config cannot widen it |

This was learned the expensive way. Until `v1.10.0` the policy addon was a file
each deployment copied, and a deployment that copied nothing got no
internal-host block at all — while looking healthy. The requirement was
documented, and checked by two scripts, and none of that reached the person who
built it. **A mandatory control whose enforcement depends on someone having
copied a file is not mandatory.**

## What this does not protect against

Stating these plainly is more useful than a longer feature list.

**A malicious agent spending what it is allowed to spend.** This is the central
limitation and not an oversight. If the agent may push to a repo, it may push
something bad. The model bounds *which credentials* and *which destinations*,
not *what is done with them* — so the real control is the scope of the
credential the broker mints, which is set outside this stack in GitHub's or
Google's UI. Narrow it there.

**Exfiltration through an allowed destination.** If `api.github.com` is
reachable, data can leave inside a gist, an issue, a commit. Egress filtering
picks destinations, not intent.

**A compromised broker or proxy.** They hold and handle the credentials by
design. This moves the secret out of the agent's process, which is the part you
cannot audit; it does not remove the need to trust the parts you can.

**The host.** Anything that can read `~/.config/agent-creds/` or talk to the
Docker socket has already won. The credential directory is mounted read-only
into one container; that is a bound on the blast radius, not a barrier against
the host.

**A provider you wrote yourself.** The bank entries are vetted; a file you add
is yours. `scripts/check-invariants.sh` catches the mistakes that have actually
shipped here — matching `pretty_host`, logging a raw path, selecting a
credential from a client header — but it is a list of known errors, not a
proof.

**Anything that cannot use an HTTP proxy.** Raw sockets, `ssh`, tools that
resolve before proxying. `LAB_INTERNAL=false` exists for them and costs you
egress mediation; the broker stays unreachable either way.

## Which document is authoritative

Five documents with real overlap is how the gap above survived being written
down three times. Each answers one question:

| artefact | authoritative for |
|---|---|
| **the images** | mandatory mechanism — the controls a deployment does not get to choose |
| **[`template/`](template/README.md)** | the wiring: service graph, networks, volumes, mounts |
| **[`bank/`](bank/README.md)** | optional providers, installable as data |
| **[`PLAYBOOK.md`](PLAYBOOK.md)** | what none of those can carry — writing a provider from scratch, and upgrading |
| **[`CLAUDE.md`](CLAUDE.md)** | maintainer-facing invariants of this repo |
| **this file** | the threat model, and the limits above |

If two of them disagree, the one nearer the top of that list wins, and the
disagreement is a bug worth reporting.
