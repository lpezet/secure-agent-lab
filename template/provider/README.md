# Provider skeletons

One directory per *shape* — the mechanism by which a credential is obtained and
attached, which is what actually differs between providers:

| shape | the credential is |
|---|---|
| `static-key/` | a secret read from a file, injected as a header |

The placeholder name inside every shape is `acme`.

Copy the shape closest to your provider, replace every **`acme`** in it with
your own name — file contents and filenames both — and fill in the blanks.
`PLAYBOOK.md` has the constraints that apply to whatever you write; the
skeleton is laid out so that following it satisfies them by default.

**`acme` is the only thing to replace, and that is deliberate.** The word
*provider* also appears in these files, and none of those occurrences should
move: `provider.json` is a fixed filename, `"load_band": "provider"` is a value
the schema requires, `provider=` is the audit trail's field **name** — renaming
it changes the shape of the trail rather than its contents — and the rest is
English. An earlier draft used `provider` as the placeholder too, and a
downstream tool doing the obvious substitution corrupted all four. A distinctive
token makes the rename a single unambiguous replace for a tool, and no harder to
follow by hand.

**These are validated like real entries.** `00-config-lint` runs the same
invariant checks over a skeleton that it runs over `bank/*/` — a scaffold that
fails this repo's own checks would teach the mistake `PLAYBOOK.md` exists to
prevent. What it is *not* checked for is being installable: a skeleton has
placeholder hosts and no credential behind it.

**Named by mechanism, not by complexity.** `static-key` sits beside a future
`oauth-refresh` or `minted-token` as a sibling. A `basic`/`advanced` pair would
read as one scale and stop being true the moment a second shape arrived that is
not more advanced, only different.

## Why the extra directory level

There is one shape. The level exists so a second one does not force a rename —
the bill this repo has already paid once, moving `template/` to
`template/deployment/` in 1.11.0.
