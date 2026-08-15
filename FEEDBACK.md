# Feedback to `secure-agent-lab`, from building a tool on top of it

From the authors of [`secure-agent-lab-cli`](https://github.com/lpezet/secure-agent-lab-cli),
against stack `v1.9.0`.

We built `sal` by doing exactly what `bank/README.md` asks a consumer to do:
hold only what the repo publishes and make the stack real. Most of that went
well, and where it did not, it went wrong in one specific and fixable way. This
is a report from that position — not a review of the code, which we did not
read as a reviewer, but a record of what a consumer got wrong and why.

---

## 1. The thing that matters: an undocumented requirement cost us a credential

`sal init` produced a deployment whose `proxy/` directory was empty, on the
reasoning that the bank supplies proxy addons and a fresh lab has no providers
yet. We then installed a provider and ran the stack. From inside the lab
container:

```
$ curl http://cred-gateway/anthropic/cred
403                                          ← correct, the route is exposed:false

$ curl http://broker:8080/anthropic/cred
{"type":"auth_token","value":"sk-ant-oat01-…"}
200                                          ← the agent has the credential
```

cred-gateway did its job. It just is not the only path to the broker: the proxy
sits on both `secure` and `lab`, so the lab can ask it to fetch an internal
host, and with nothing loaded to stop it, it does.

**The stack already ships the defence.** `stack/proxy/addons/000_policy.py` is
precisely this control, and its docstring describes the attack — including the
`Host:`-header variant — better than we could:

```python
"""Block forwarding of requests to internal service hostnames.
...
_INTERNAL_HOSTS = {"broker", "cred-gateway"}
```

Both examples install it. **Nothing states that a deployment must.** It is not
in `bank/`, it has no manifest, and no document says "every deployment needs
these regardless of which providers it has". A consumer assembling a deployment
from the published contract will not include it, because the published contract
does not mention it.

We fixed this on our side: `sal init` now installs everything in
`stack/proxy/addons/` and refuses to create a lab if it cannot obtain them.
Re-running both variants of the exploit afterwards returns 403.

**Ask:** state, somewhere a tool can act on, that the contents of
`stack/proxy/addons/` are mandatory for any deployment. A line in `bank/README.md`
would help a human; a manifest or an explicit list would help a tool.

---

## 2. The shape of the problem: the bank is machine-consumable, the deployment is not

This is the one-sentence version of everything below.

`bank/` was designed to be installed from by something that is not a person,
and it works. It has a schema, a `schema_version` (a genuinely good call — we
adopted the same rule for our own files), and an explicit bar in
`bank/README.md`:

> Someone — or something — holding only `bank/<name>/` and a running stack can
> install the provider without reading anything else in this repo.

`sal providers add <name>` is completely generic as a result. All four entries
install with zero per-provider code, and we have a test that fails if a bank
entry name ever appears as a string literal in our source. That contract held
under real pressure.

**The deployment never got the same treatment**, and so a consumer must guess.
There are three candidates for "what a deployment looks like", none of them
authoritative:

| Candidate | Services | Pinned at | Usable as a template? |
|---|---|---|---|
| `stack/compose.yaml` | 6 | local `build: ./broker` | No — its own header says it will not work as-is |
| `examples/claude-code/` | **4** | `v1.2.0` | No — no `observer`, no `log-rotator`, no `audit-logs` volume |
| `examples/dev-container/.devcontainer/` | 6 | `v1.3.1` | Closest, but a demo, and six releases behind |

Faced with that, `sal` ended up authoring its own foundation `compose.yaml` —
which we flagged in our own docs as a reversal of what the two-repo split is
for. A change to the stack's service graph now requires a `sal` release. We
kept it in one deliberately dumb file so that handing it back is a copy rather
than a rewrite.

**Ask:** own a versioned deployment template in this repo, fetched by tag the
way the bank already is. That is the single change that would stop a downstream
tool being an accidental reference implementation.

---

## 3. Smaller observations

**The examples do not say which is which.** `examples/claude-code/` runs four
services; `examples/dev-container/.devcontainer/` runs six, adding `observer`,
`log-rotator` and the `audit-logs` volume. Both are defensible — an audit trail
is opt-in, and dropping it coherently means dropping all three together. The
gap is that nothing tells a reader one is the minimal shape and the other the
fuller one, so which they copy depends on which directory they opened first.

Making the axis explicit in the names would fix it: `claude-code-light` for the
minimal shape, and a `claude-code-tight` showing the hardened one — audit trail
on, egress allowlist mounted, base proxy addons present. That second example
would also be the natural place to make ask (1) concrete: a worked deployment
with every control actually turned on, rather than a sentence saying they
exist. Note this is a different axis from `dev-container`, which varies the
delivery mechanism rather than the hardening level, so the two namings should
not be read as a single scale.

Separately and regardless of naming: `examples/claude-code/` pins `v1.2.0`
internally while the repo is at `v1.9.0`. An example seven releases back
teaches an old boundary to whoever copies it.

**There is no CI.** No `.github` directory anywhere in the repo. For something
that versions a security boundary and ships a test suite of this quality —
`tests/run.sh`, two tiers split by whether the credentials are real, with the
config lint alone carrying hundreds of assertions — nothing runs any of it on a
pull request. This is the cheapest
high-value change on the list.

**No published images.** Every deployment builds five images from a git ref, so
a first `sal up` takes minutes rather than seconds. Publishing to GHCR would
also allow pinning by digest instead of by a mutable tag.

**`check-drift.sh` is genuinely good and we built around it.** It reads
`"$DEPLOY/.sal/installed.json"` (`scripts/check-drift.sh:210`), so our
deployments write that file at that path, even though the nesting looks
redundant inside a directory our own tool owns. We kept it because it makes a
lab an *ordinary* deployment that a tool which has never heard of `sal` still
works on. Worth knowing that the contract is being honoured deliberately.

---

## 4. On the repo's overall shape

Our reading, offered as a proposal rather than a complaint: this repo is the
concept, the reference implementation, and the bank — and the bank should stay
here, because bank entries are coupled to the *image* API (`require("../audit")`
resolves only from 1.1.0; `import audit` depends on `PYTHONPATH=/opt/agent-proxy`).
They have to version with the boundary they run against. Separating them would
break something that currently works.

What is missing is not more directories but a statement of which artefact is
authoritative for what, and a deployment template that a tool can consume the
way it already consumes the bank.

**One document, as the entry point.** Understanding SAL today means assembling
it from `README.md`, `CLAUDE.md`, `PLAYBOOK.md`, the changelog, and docstrings
inside addons. Some of that writing is genuinely excellent — the
`000_policy.py` docstring explains an attack better than most security advisories
do, and the `load_band` description carries a real design decision — and almost
nobody will ever find either. A reader deciding whether this project is for
them should not have to go looking.

A `WHITEPAPER.md` or `CONCEPT.md`, linked prominently from `README.md`, gives
that reader one path: read the overview, decide whether the model fits, and
only then start poking at how it works. Whoever bounces off it costs nothing.
Whoever stays arrives with the model already in their head, which is also the
difference between someone who copies an example and someone who understands
why the lab network is `internal: true`.

The raw material is mostly written, so this is closer to an editing job than a
research one. And writing it will probably force the questions in asks (1) and
(2), because an overview has to say which artefact is authoritative for what.
That is a feature, not a reason to wait.

---

## Summary of asks

1. **State that `stack/proxy/addons/` is mandatory for every deployment**, in a
   form a tool can act on. This one is a security fix.
2. **Own a versioned deployment template**, fetched by tag like the bank. We
   will delete ours and consume yours.
3. **Add CI** that runs the existing suite on pull requests.
4. **Write one overview document** — `WHITEPAPER.md` or `CONCEPT.md`, linked
   from `README.md` — so a newcomer has a single entry point instead of five.
5. **Name the examples for what they demonstrate** — e.g. `claude-code-light`
   and a hardened `claude-code-tight` — and refresh the `v1.2.0` pin.
6. Optionally: publish images to GHCR, so a deployment can pull rather than
   build five of them from a git ref, and pin by digest rather than by tag.

Happy to open PRs for any of these, particularly (2) — we have a working
template and the strong motivation of wanting to stop maintaining it.
