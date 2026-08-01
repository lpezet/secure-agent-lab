#!/usr/bin/env bash
# check-drift.sh — compare a deployment's bind-mounted files against the tag it
# is pinned at.
#
# A deployment is versioned in two halves and only one moves when you repin.
# compose.yaml builds each image from stack/<service> at the tag, but the files
# that enforce the security boundary — proxy/*.py, broker/*.js,
# cred-gateway/*.conf — are bind-mounted from the deployment's own directories.
# Bumping the tag upgrades the images and leaves those files byte-for-byte as
# they were, with nothing in `docker compose ps` to show for it. The stack
# guarantees this drift; this script is what detects it.
#
# Dependency-free on purpose: bash, git, diff. Runs against a deployment
# directory anywhere on disk, including one that has never heard of this repo.
#
#   scripts/check-drift.sh .devcontainer
#   scripts/check-drift.sh --to v1.4.0 /path/to/deployment   # preview an upgrade
#   scripts/check-drift.sh --ref . --show-diff .devcontainer # against a checkout
#
# Exit codes: 0 clean · 1 drift found · 2 cannot run.
set -uo pipefail

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DEPLOY="" TO_TAG="" REF_DIR="" EXAMPLE="" SHOW_DIFF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)        TO_TAG="${2:-}"; shift 2 ;;
    --ref)       REF_DIR="${2:-}"; shift 2 ;;
    --example)   EXAMPLE="${2:-}"; shift 2 ;;
    --show-diff) SHOW_DIFF=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$DEPLOY" ]; then printf 'unexpected argument: %s\n' "$1" >&2; exit 2; fi
      DEPLOY="$1"; shift ;;
  esac
done

[ -n "$DEPLOY" ] || { usage >&2; exit 2; }
[ -d "$DEPLOY" ] || { printf 'not a directory: %s\n' "$DEPLOY" >&2; exit 2; }
DEPLOY="$(cd "$DEPLOY" && pwd)"

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; B=''; N=''
fi

DRIFT=0 MISSING=0 CUSTOM=0 NOTE=0

# Findings are ranked by what they cost you to ignore.
drift()   { DRIFT=$((DRIFT+1));     printf '  %sDRIFT%s   %-24s %s\n' "$R" "$N" "$1" "$2"; }
missing() { MISSING=$((MISSING+1)); printf '  %sMISSING%s %-24s %s\n' "$R" "$N" "$1" "$2"; }
custom()  { CUSTOM=$((CUSTOM+1));   printf '  %scustom%s  %-24s %s\n' "$Y" "$N" "$1" "$2"; }
note()    { NOTE=$((NOTE+1));       printf '  %snote%s    %-24s %s\n' "$C" "$N" "$1" "$2"; }
same()    {                         printf '  %sok%s      %-24s %s\n' "$G" "$N" "$1" "$2"; }
warn()    { printf '%swarning:%s %s\n' "$Y" "$N" "$1" >&2; }
die()     { printf '%serror:%s %s\n' "$R" "$N" "$1" >&2; exit 2; }

# ------------------------------------------------------------------ the pin

COMPOSE=""
for c in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
  [ -f "$DEPLOY/$c" ] && { COMPOSE="$DEPLOY/$c"; break; }
done
[ -n "$COMPOSE" ] || die "no compose file in $DEPLOY"

# Every build: line points at this repo with a #ref fragment. Collect the set:
# more than one means the services disagree about which version they are.
REFS=$(grep -ohE '(secure-agent-lab|secure-autonomous-agents)\.git#[^:[:space:]"'"'"']+' "$COMPOSE" |
       sed 's/.*#//' | sort -u)
[ -n "$REFS" ] || die "no secure-agent-lab build refs in $(basename "$COMPOSE") — is this a deployment of this stack?"

PIN=$(printf '%s\n' "$REFS" | head -1)
REF_COUNT=$(printf '%s\n' "$REFS" | wc -l | tr -d ' ')

# ------------------------------------------------------- the provenance stub

STUB="$DEPLOY/CLAUDE.md"
GEN_FROM="" RECON_LINE=""
if [ -f "$STUB" ]; then
  GEN_FROM=$(sed -n 's/^[[:space:]]*Generated from:[[:space:]]*//p' "$STUB" | head -1)
  RECON_LINE=$(sed -n 's/^[[:space:]]*Reconciled:[[:space:]]*//p' "$STUB" | head -1)
fi
[ -n "$EXAMPLE" ] && GEN_FROM="$EXAMPLE"

# reconciled_tag <dir> — the tag this directory was last reconciled against,
# from the stub's `Reconciled:` line. Empty when unrecorded.
reconciled_tag() {
  [ -n "$RECON_LINE" ] || return 0
  printf '%s\n' "$RECON_LINE" | tr '·,;' '\n\n\n' |
    sed -n "s|^[[:space:]]*$1/*[[:space:]]*\(v[0-9][0-9.]*\).*|\1|p" | head -1
}

# --------------------------------------------------------- reference checkout

TMP_CLONE=""
cleanup() { [ -n "$TMP_CLONE" ] && rm -rf "$TMP_CLONE"; }
trap cleanup EXIT

TARGET="${TO_TAG:-$PIN}"
if [ -n "$REF_DIR" ]; then
  [ -d "$REF_DIR/examples" ] && [ -d "$REF_DIR/stack" ] ||
    die "--ref $REF_DIR does not look like a checkout of this repo"
  REF="$(cd "$REF_DIR" && pwd)"
  REF_LABEL="$REF (--ref)"
else
  command -v git >/dev/null 2>&1 || die "git is required unless you pass --ref"
  TMP_CLONE=$(mktemp -d) || die "cannot create a temp directory"
  printf 'fetching %s...\n' "$TARGET"
  if ! git clone --quiet --depth 1 --branch "$TARGET" \
       https://github.com/lpezet/secure-agent-lab.git "$TMP_CLONE/repo" 2>/dev/null; then
    die "cannot fetch $TARGET — check the ref exists and the network is reachable"
  fi
  REF="$TMP_CLONE/repo"
  REF_LABEL="$TARGET"
fi

# example_path <name> — where an example's mounted content lives in the ref
# tree. dev-container keeps its under .devcontainer/; claude-code does not.
example_path() {
  local n="${1#examples/}"
  for p in "$REF/examples/$n/.devcontainer" "$REF/examples/$n"; do
    [ -d "$p/proxy" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# bank_path <sub> <basename> — where a bank-installed file lives in the ref
# tree, or nothing. Strips the NNN_ prefix the installer assigns, which is
# deployment state by design and so cannot be in the bank; that prefix is the
# single documented normalization in this comparison.
#
# Tried before the example fallback because it resolves by *name* rather than
# by guessing which example a deployment started from. A deployment full of
# custom files degrades that guess — count_mismatches counts every custom file
# as a mismatch and so picks the wrong example to diff against — while a
# bank-installed file resolves the same regardless of what sits beside it.
bank_path() {
  local sub="$1" base="$2" stripped name ext p
  stripped="${base#[0-9][0-9][0-9]_}"
  name="${stripped%.*}"; ext="${stripped##*.}"
  p="$REF/bank/$name/$sub/$name.$ext"
  [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  return 1
}

# count_mismatches <example-path> — how badly a deployment matches an example.
# Used only to guess the counterpart when the stub does not record one, and
# only for files bank_path could not resolve.
count_mismatches() {
  local ex="$1" n=0 sub f base
  for sub in proxy broker cred-gateway; do
    [ -d "$DEPLOY/$sub" ] || continue
    for f in "$DEPLOY/$sub"/*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      if [ -f "$ex/$sub/$base" ]; then
        cmp -s "$f" "$ex/$sub/$base" || n=$((n+1))
      else
        n=$((n+1))
      fi
    done
  done
  printf '%d' "$n"
}

EX=""
if [ -n "$GEN_FROM" ]; then
  EX=$(example_path "$GEN_FROM") ||
    die "the stub records \`Generated from: $GEN_FROM\`, which does not exist at $REF_LABEL"
  SOURCE_NOTE="$GEN_FROM (recorded)"
else
  # Fall back to the playbook's advice: diff against both, take the closer.
  best="" best_n=-1
  for cand in "$REF"/examples/*; do
    [ -d "$cand" ] || continue
    p=$(example_path "examples/$(basename "$cand")") || continue
    n=$(count_mismatches "$p")
    if [ "$best_n" -lt 0 ] || [ "$n" -lt "$best_n" ]; then best="$p"; best_n="$n"; fi
  done
  [ -n "$best" ] || die "no usable example found at $REF_LABEL"
  EX="$best"
  SOURCE_NOTE="examples/$(basename "${EX%/.devcontainer}") (guessed — record it in the stub)"
fi

# --------------------------------------------------------------------- report

printf '\n%sdeployment%s  %s\n' "$B" "$N" "$DEPLOY"
printf '%spinned%s      %s (%s)\n' "$B" "$N" "$PIN" "$(basename "$COMPOSE")"
printf '%scomparing%s   %s\n' "$B" "$N" "$REF_LABEL"
printf '%ssource%s      %s\n' "$B" "$N" "$SOURCE_NOTE"

# .sal/installed.json is the authoritative record of which bank entries a
# deployment carries — name, assigned NNN, files written (see PLAYBOOK, "A
# known provider"). Nothing writes it yet: the install steps are normative for
# an installer that does not exist, and a person following the playbook by hand
# will not produce one. So this reads it when it is there and is silent when it
# is not. Absence is the status quo for a deployment installed by hand, not a
# fault; resolution falls through to matching by name, which needs no record.
SAL="$DEPLOY/.sal/installed.json"
SAL_NAMES=""
if [ -f "$SAL" ]; then
  if command -v jq >/dev/null 2>&1; then
    SAL_NAMES=$(jq -r '(.installed // .)[]?.name // empty' "$SAL" 2>/dev/null | sort -u | tr '\n' ' ')
    [ -n "$SAL_NAMES" ] && printf '%sbank%s        %s(recorded in .sal/)\n' "$B" "$N" "$SAL_NAMES"
  else
    printf '%sbank%s        .sal/installed.json present, jq missing — not read\n' "$B" "$N"
  fi
fi
printf '\n'
for n in $SAL_NAMES; do
  [ -d "$REF/bank/$n" ] ||
    drift ".sal/" "records bank entry '$n', which does not exist at $REF_LABEL"
done

if [ "$REF_COUNT" -gt 1 ]; then
  drift "compose.yaml" "services pinned at different refs: $(printf '%s' "$REFS" | tr '\n' ' ')"
fi
case "$PIN" in
  v[0-9]*) ;;
  *) drift "compose.yaml" "pinned to '$PIN', not a release tag — builds move under you" ;;
esac
if [ ! -f "$STUB" ]; then
  note "CLAUDE.md" "no provenance stub — see PLAYBOOK.md \"Last step: record the provenance\""
elif [ -z "$RECON_LINE" ]; then
  note "CLAUDE.md" "stub has no \`Reconciled:\` line — a skipped reconciliation stays invisible"
fi

# compare <label> <local-file> <ref-file> <where>
compare() {
  local label="$1" lf="$2" rf="$3" where="$4"
  if cmp -s "$lf" "$rf"; then
    same "$label" "matches $where"
  else
    drift "$label" "differs from $where"
    [ "$SHOW_DIFF" = "1" ] && diff -u "$rf" "$lf" | sed 's/^/      /'
  fi
}

for sub in proxy broker cred-gateway; do
  printf '%s%s/%s' "$B" "$sub" "$N"
  rt=$(reconciled_tag "$sub")
  if [ -n "$rt" ] && [ "$rt" != "$TARGET" ]; then
    printf '  %s(last reconciled at %s, comparing against %s)%s' "$Y" "$rt" "$TARGET" "$N"
  fi
  printf '\n'

  if [ ! -d "$DEPLOY/$sub" ]; then
    note "$sub/" "not present in this deployment"
    printf '\n'; continue
  fi

  found=0
  for f in "$DEPLOY/$sub"/*; do
    [ -f "$f" ] || continue
    found=1
    base=$(basename "$f")
    # Addons whose upstream home is stack/proxy/addons/ rather than examples/.
    # Every example vendors 000_policy.py; none vendors 001_allowlist.py, so
    # without this the allowlist addon reads as a custom file with no owner.
    if [ "$sub" = "proxy" ] && [ -f "$REF/stack/proxy/addons/$base" ]; then
      compare "$base" "$f" "$REF/stack/proxy/addons/$base" "stack/proxy/addons/"
    elif bp=$(bank_path "$sub" "$base"); then
      bn="${bp#$REF/bank/}"; bn="${bn%%/*}"
      compare "$base" "$f" "$bp" "bank/$bn/$sub/"
    elif [ -f "$EX/$sub/$base" ]; then
      compare "$base" "$f" "$EX/$sub/$base" "$(basename "${EX%/.devcontainer}")/$sub/"
    else
      custom "$base" "no upstream counterpart — you own it, review it by hand"
    fi
  done
  [ "$found" = "1" ] || note "$sub/" "empty"
  printf '\n'
done

# 000_policy.py is not optional and not shipped in the image: /addons exists
# only because the deployment mounts it, so an unvendored policy addon is a
# control that does not exist rather than a stale one.
if [ ! -f "$DEPLOY/proxy/000_policy.py" ]; then
  missing "000_policy.py" "not vendored — the proxy has no internal-host block at all"
fi

printf '%ssummary%s     %d drift · %d missing · %d custom · %d note\n' "$B" "$N" \
  "$DRIFT" "$MISSING" "$CUSTOM" "$NOTE"

if [ "$((DRIFT + MISSING))" -gt 0 ]; then
  printf '\nReconcile with PLAYBOOK.md "Upgrading" step 3, then update the stub'\''s\n'
  printf '`Reconciled:` line. Custom files are yours: no upstream fix reaches them.\n'
  exit 1
fi
printf '\nNo drift. Custom files above are still yours to review against the\n'
printf 'generation constraints when an addon or provider fix lands upstream.\n'
exit 0
