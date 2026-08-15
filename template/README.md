# Templates

Skeletons meant to be copied, fetched at a release tag the way a
[`bank/`](../bank/README.md) entry is.

| | copy it to get |
|---|---|
| [`deployment/`](deployment/README.md) | a whole stack — the service graph, both networks, the volumes and the mounts |
| [`provider/`](provider/) | one bank entry, for a credential the bank does not carry |

## Why two levels

`deployment/` was `template/` until 1.11.0. The rename cost a path that had
shipped in three tags, and it happened because the first version assumed there
would only ever be one kind of template. There are two, so the nesting is the
lesson rather than the plan.

`provider/` is nested one level further — `provider/<shape>/` — for the same
reason and before the same bill arrives. There is one shape today; if a second
ever lands it slots in beside the first instead of forcing another move. If it
never does, the cost was one directory.

## What is not here

The **mechanism** is not a template. Neither the internal-host block, the
egress allowlist, nor cred-gateway's default-deny is a file you copy — they are
baked into the images precisely so a deployment cannot leave one out. See
[`CONCEPT.md`](../CONCEPT.md#what-the-deployment-does-not-get-to-choose).

Nor are the **vetted providers**. If the bank already carries the credential you
need, install that entry rather than starting from a skeleton — it is
maintained, versioned, and checked by the same invariants this repo runs on
itself.
