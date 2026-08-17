# `lab/setup.d/` — provider setup fragments

This directory is mounted read-only at `/etc/agent-setup.d`, and the lab image's
entrypoint runs every `*.sh` in it, in filename order, before starting the
container's command.

Installing a provider that declares `lab_setup` in its manifest means copying
its fragment here, named for the provider:

```
lab/setup.d/github.sh      from bank/github/lab/setup.sh
lab/setup.d/gcp.sh         from bank/gcp/lab/setup.sh
```

Renamed per provider because the bank's filename is fixed per entry — two
entries would otherwise both be `setup.sh`. Uninstalling is deleting the file.

Two of the four bank entries ship one, and both are load-bearing:
`github` wires the git credential helper and forces `gh` onto HTTPS;
`gcp` writes the inert ADC file that lets a Google client library's credential
chain get far enough to make a request the proxy can answer. A deployment that
copies the broker provider and the proxy addon but not the fragment has the
provider installed and not working.

If you write your own, the rules are in `PLAYBOOK.md` under "Adding a credential
provider". The short version: executed rather than sourced, so write files
rather than exporting variables; idempotent, because it runs on every start; and
exit non-zero to stop the container rather than come up half-configured.
