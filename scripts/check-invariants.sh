#!/usr/bin/env bash
# check-invariants.sh — is this deployment's own code safe?
#
# check-drift.sh asks whether your files match ours. That is the right question
# and it is not the only one: a file you wrote has no upstream counterpart, so
# drift reports it as `custom` and diffs nothing. A maintainer once reconciled
# everything check-drift reported, got a clean run, and had two of their own
# addons writing secrets into the audit trail the whole time.
#
# This asks the other question. It needs no upstream, no pinned tag, no
# provenance stub, no network and no git — the answer is a property of the file
# in front of you.
#
#   scripts/check-invariants.sh .devcontainer
#   scripts/check-invariants.sh --quiet /path/to/deployment   # findings only
#
# Exit codes: 0 no findings · 1 at least one `fail` finding · 2 cannot run.
# `note` findings alone do not fail the run.
set -uo pipefail

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DEPLOY="" QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$DEPLOY" ]; then printf 'unexpected argument: %s\n' "$1" >&2; exit 2; fi
      DEPLOY="$1"; shift ;;
  esac
done

[ -n "$DEPLOY" ] || { usage >&2; exit 2; }
[ -d "$DEPLOY" ] || { printf 'not a directory: %s\n' "$DEPLOY" >&2; exit 2; }
DEPLOY="$(cd "$DEPLOY" && pwd)"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/invariants.sh"
[ -f "$LIB" ] || { printf 'cannot find %s\n' "$LIB" >&2; exit 2; }
# shellcheck source=lib/invariants.sh
. "$LIB"

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; N=''
fi

FAILN=0 NOTEN=0 SCANNED=0
fail_f() { FAILN=$((FAILN+1)); printf '    %sFAIL%s  %s\n' "$R" "$N" "$1"; }
note_f() { NOTEN=$((NOTEN+1)); printf '    %snote%s  %s\n' "$Y" "$N" "$1"; }

printf '\n%sdeployment%s  %s\n' "$B" "$N" "$DEPLOY"
printf '%schecks%s      %d known invariants\n\n' "$B" "$N" \
  "$(printf '%s\n' "$INV_REGISTRY" | grep -c .)"

# scan_file <path>
scan_file() {
  local f="$1" kind check sev desc out ev header_done=0 base
  kind=$(inv_kind "$f") || return 0
  [ -n "$kind" ] || return 0
  base=$(basename "$f")
  SCANNED=$((SCANNED+1))

  for check in $(inv_checks_for "$kind"); do
    # 000_policy.py is the one file allowed to read pretty_host: it ORs it with
    # the real host to *widen* a block, and trusting a claimed Host to deny
    # more is safe. Telling that apart from the dangerous use by grep is not
    # worth attempting, so it is exempted by name.
    [ "$check" = pretty_host ] && [ "$base" = "000_policy.py" ] && continue

    if out=$("inv_$check" "$f"); then continue; fi
    sev=$(inv_field "$check" 1); desc=$(inv_field "$check" 3)
    if [ "$header_done" = 0 ]; then
      printf '  %s%s%s\n' "$B" "${f#$DEPLOY/}" "$N"; header_done=1
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Evidence carries the source file's indentation; strip it so findings
      # line up regardless of how deeply nested the offending line was.
      ev=$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//')
      case "$sev" in
        fail) fail_f "$(printf '%-5s %s\n           %s' "${line%%:*}:" "$desc" "$ev")" ;;
        *)    note_f "$(printf '%-5s %s\n           %s' "${line%%:*}:" "$desc" "$ev")" ;;
      esac
    done <<EOF
$out
EOF
  done
  [ "$header_done" = 1 ] && printf '\n'
  return 0
}

for sub in proxy broker cred-gateway; do
  [ -d "$DEPLOY/$sub" ] || continue
  for f in "$DEPLOY/$sub"/*; do [ -f "$f" ] && scan_file "$f"; done
done
for c in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
  [ -f "$DEPLOY/$c" ] && scan_file "$DEPLOY/$c"
done

# Directory-level: the policy addon must load first, and must exist at all.
if [ -d "$DEPLOY/proxy" ]; then
  if [ ! -f "$DEPLOY/proxy/000_policy.py" ]; then
    printf '  %sproxy/%s\n' "$B" "$N"
    fail_f "$(printf '%-6s %s' '' '000_policy.py is absent — nothing blocks requests to broker or cred-gateway')"
    printf '\n'
  elif out=$(inv_policy_addon_first "$DEPLOY/proxy"); then :
  else
    printf '  %sproxy/%s\n' "$B" "$N"
    fail_f "$(printf '%-6s %s' '' "${out#*: }")"
    printf '\n'
  fi
fi

# ------------------------------------------------------------------- verdict
#
# The honesty constraint, and the reason this script exists in the shape it
# does. The maintainer whose report opened #26 made the point that a clean
# report reads as a pass, and it applies recursively: these are greps against a
# known list, and a custom provider can be unsafe in ways none of them
# anticipate. So there is no "PASS" here, ever — only "no findings", and a
# standing note about what that does and does not mean.
printf '%ssummary%s     %d file(s) scanned · %d fail · %d note\n' \
  "$B" "$N" "$SCANNED" "$FAILN" "$NOTEN"

if [ "$SCANNED" = 0 ]; then
  printf '\nNothing to scan. Expected proxy/, broker/, cred-gateway/ or a compose\n'
  printf 'file under %s — is this a deployment of this stack?\n' "$DEPLOY"
  exit 2
fi

if [ "$FAILN" = 0 ] && [ "$QUIET" = 0 ]; then
  printf '\n%d file(s) checked against %d known invariants, %s.\n' \
    "$SCANNED" "$(printf '%s\n' "$INV_REGISTRY" | grep -c .)" \
    "$([ "$NOTEN" = 0 ] && printf 'no findings' || printf "$NOTEN note(s)")"
  printf '%sThat is not a review.%s A provider can be unsafe in ways these checks\n' "$Y" "$N"
  printf 'do not look for. PLAYBOOK.md "What is safe to log" is the standard, and\n'
  printf 'a file you wrote is yours to review against it.\n'
fi

[ "$FAILN" -gt 0 ] && exit 1
exit 0
