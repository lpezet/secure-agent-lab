# `lab/setup.d/` — provider setup fragments

Empty by design, like `stack/broker/providers/` and
`stack/cred-gateway/gateway.d/`. The image supplies the mechanism; a deployment
supplies the content.

`compose.yaml` mounts this directory at `/etc/agent-setup.d`, read-only, and the
lab image's `entrypoint.sh` runs every `*.sh` in it — in filename order — before
handing off to the container's command. A bank entry that declares `lab_setup`
installs its fragment here.

## Authoring rules

- **One file per provider**, named for it. `sal` installs
  `bank/<name>/lab/setup.sh` as `<name>.sh`; the bank's own filename is fixed
  per entry, so two providers would otherwise collide on `setup.sh`. Prefix with
  `NNN_` if you ever need to order two that interact — nothing shipped does.
- **Fragments are executed, not sourced.** Write to the filesystem; do not
  expect an `export` to survive. It would not reach the agent anyway: `docker
  exec` builds its environment from the container's config, not from PID 1. To
  set an agent-visible variable, write `/etc/profile.d/`, or declare `lab_env`
  in the entry's manifest.
- **Exit non-zero to stop the container.** A lab that comes up with a provider
  installed and unconfigured is the failure this directory exists to prevent, so
  a failing fragment is not logged past.
- **Assume it runs on every start**, not once on create. Write it idempotently.
- **The mount is read-only.** A fragment can do anything the lab can do — that
  is why an entry may ship shell — but it cannot edit the deployment it came
  from.
