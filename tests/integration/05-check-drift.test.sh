#!/usr/bin/env bash
# scripts/check-drift.sh against synthetic deployments. No docker, no network —
# every case runs with --ref pointed at this checkout, which is also what makes
# the script testable at all.
#
# The cases that matter are the ones where a real deployment gets told the wrong
# thing: an upstream file reported as custom (nobody will ever patch it), or a
# missing control reported as fine.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

DRIFT_SH="$REPO_ROOT/scripts/check-drift.sh"
EX="$REPO_ROOT/examples/claude-code"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"; cleanup' EXIT

# mkdep <name> — a deployment that is byte-identical to examples/claude-code,
# plus the allowlist addon (opt-in upstream, so no example vendors it).
mkdep() {
  local d="$TMPD/$1"
  mkdir -p "$d"/{proxy,broker,cred-gateway}
  cp "$EX"/proxy/*.py "$d/proxy/"
  cp "$REPO_ROOT"/stack/proxy/addons/001_allowlist.py "$d/proxy/"
  cp "$EX"/broker/*.js "$d/broker/"
  cp "$EX"/cred-gateway/*.conf "$d/cred-gateway/"
  cat > "$d/compose.yaml" <<'YAML'
services:
  broker:
    build: https://github.com/lpezet/secure-agent-lab.git#v1.3.1:stack/broker
  proxy:
    build: https://github.com/lpezet/secure-agent-lab.git#v1.3.1:stack/proxy
YAML
  cat > "$d/CLAUDE.md" <<'MD'
Stack: secure-agent-lab, pinned v1.3.1
Generated from: examples/claude-code
Reconciled: proxy/ v1.3.1 · broker/ v1.3.1 · cred-gateway/ v1.3.1
MD
  printf '%s' "$d"
}

# run <deployment-dir> [args...] — output with the exit code appended as a line.
run() {
  local d="$1"; shift
  local out rc
  out=$(bash "$DRIFT_SH" --ref "$REPO_ROOT" "$@" "$d" 2>&1); rc=$?
  printf '%s\nEXIT=%d' "$out" "$rc"
}

suite "a deployment matching its pin is clean"
d=$(mkdep clean)
out=$(run "$d")
check_contains "exits 0" "$out" "EXIT=0"
check_contains "reports no drift" "$out" "0 drift · 0 missing"
check_contains "reads the recorded source" "$out" "examples/claude-code (recorded)"

suite "an edited addon is drift, not a customization"
d=$(mkdep edited)
printf '\n# local edit\n' >> "$d/proxy/020_anthropic.py"
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "names the file" "$out" "DRIFT   020_anthropic.py"
check_not_contains "does not call it custom" "$out" "custom  020_anthropic.py"

# The regression this script exists for. examples/* vendor 000_policy.py but
# none vendors 001_allowlist.py, so resolving counterparts against examples/
# alone reports a vendored upstream addon as ownerless — and an upstream fix to
# it would never be applied. Its home is stack/proxy/addons/.
suite "vendored upstream addons resolve to stack/proxy/addons/"
d=$(mkdep addons)
out=$(run "$d")
check_contains "000_policy.py matches upstream" "$out" "ok      000_policy.py            matches stack/proxy/addons/"
check_contains "001_allowlist.py matches upstream" "$out" "ok      001_allowlist.py         matches stack/proxy/addons/"
check_not_contains "allowlist is not reported as custom" "$out" "custom  001_allowlist.py"

suite "an edited allowlist addon is drift too"
d=$(mkdep allowlist-edited)
printf '\n# local edit\n' >> "$d/proxy/001_allowlist.py"
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "names it against stack/" "$out" "DRIFT   001_allowlist.py         differs from stack/proxy/addons/"

suite "a genuinely custom addon is flagged as owned, not as drift"
d=$(mkdep custom)
printf 'def request(flow):\n    pass\n' > "$d/proxy/030_fal.py"
out=$(run "$d")
check_contains "exits 0 — ownership is not a failure" "$out" "EXIT=0"
check_contains "names it custom" "$out" "custom  030_fal.py"
check_contains "counts it" "$out" "1 custom"

suite "an unvendored policy addon is a missing control"
d=$(mkdep nopolicy)
rm "$d/proxy/000_policy.py"
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "reports it missing" "$out" "MISSING 000_policy.py"

suite "build refs that are not release tags are drift"
d=$(mkdep unpinned)
sed -i 's|#v1\.3\.1:stack/proxy|#main:stack/proxy|' "$d/compose.yaml"
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "flags the mixed refs" "$out" "services pinned at different refs"
check_contains "flags the branch ref" "$out" "not a release tag"

suite "a stale Reconciled: tag is surfaced"
d=$(mkdep stale)
sed -i 's|proxy/ v1\.3\.1|proxy/ v1.1.0|' "$d/CLAUDE.md"
out=$(run "$d")
check_contains "names both tags" "$out" "last reconciled at v1.1.0"

suite "a deployment with no stub still works"
d=$(mkdep nostub)
rm "$d/CLAUDE.md"
out=$(run "$d")
check_contains "exits 0" "$out" "EXIT=0"
check_contains "guesses the example" "$out" "examples/claude-code (guessed"
check_contains "asks for the stub" "$out" "no provenance stub"

suite "the other example is matched when it is the source"
d="$TMPD/devc"
mkdir -p "$d"/{proxy,broker,cred-gateway}
cp "$REPO_ROOT"/examples/dev-container/.devcontainer/proxy/*.py "$d/proxy/"
cp "$REPO_ROOT"/examples/dev-container/.devcontainer/broker/*.js "$d/broker/"
cp "$REPO_ROOT"/examples/dev-container/.devcontainer/cred-gateway/*.conf "$d/cred-gateway/"
cp "$TMPD/clean/compose.yaml" "$d/compose.yaml"
out=$(run "$d" --example examples/dev-container)
check_contains "exits 0" "$out" "EXIT=0"
# The .devcontainer/ layout still has to resolve — example_path() dies if it
# cannot find one — but it is no longer observable through a file comparison.
# Every provider file in this fixture now resolves through the bank, which
# wins ahead of the example fallback on purpose (#32 §7). The source line is
# what proves .devcontainer/ was found.
check_contains "resolves .devcontainer/" "$out" "examples/dev-container (recorded)"
check_contains "prefers the bank over the example" "$out" "matches bank/github/proxy/"

suite "the example fallback still catches what the bank does not cover"
# A file with no bank counterpart and no stack counterpart is the deployment's
# own. Proves the chain falls through rather than mis-resolving by name.
cp "$d/proxy/010_github.py" "$d/proxy/040_acme.py"
out=$(run "$d" --example examples/dev-container)
check_contains "unmatched file reads as custom" "$out" "040_acme.py"
check_contains "and is named as owned" "$out" "no upstream counterpart"
rm -f "$d/proxy/040_acme.py"

suite "refuses a directory that is not a deployment"
mkdir -p "$TMPD/empty"
out=$(run "$TMPD/empty")
check_contains "exits 2" "$out" "EXIT=2"
check_contains "says why" "$out" "no compose file"

finish
