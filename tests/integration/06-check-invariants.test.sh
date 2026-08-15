#!/usr/bin/env bash
# scripts/check-invariants.sh against synthetic deployments. No docker, no
# network — every check is a property of the text in front of it.
#
# The cases that matter are the ones a real deployment gets wrong: a custom
# addon that leaks, and a clean report that reads as a pass when it is not.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

INV_SH="$REPO_ROOT/scripts/check-invariants.sh"
SRC="$REPO_ROOT/examples/dev-container/.devcontainer"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"; cleanup' EXIT

# mkdep <name> — a deployment byte-identical to examples/dev-container.
mkdep() {
  local d="$TMPD/$1"
  mkdir -p "$d"/{proxy,broker,cred-gateway}
  cp "$SRC"/proxy/*.py "$d/proxy/"
  cp "$SRC"/broker/*.js "$d/broker/"
  cp "$SRC"/cred-gateway/*.conf "$d/cred-gateway/"
  cp "$SRC"/compose.yaml "$d/compose.yaml"
  printf '%s' "$d"
}

# run <dir> [args...] — output with the exit code appended.
run() {
  local d="$1"; shift
  local out rc
  out=$(bash "$INV_SH" "$@" "$d" 2>&1); rc=$?
  printf '%s\nEXIT=%d' "$out" "$rc"
}

suite "a clean deployment reports no findings and never says 'pass'"
d=$(mkdep clean)
out=$(run "$d")
check_contains "exits 0" "$out" "EXIT=0"
check_contains "counts the files" "$out" "file(s) scanned"
check_contains "reports zero failures" "$out" "0 fail"
# The honesty constraint from #26: a clean scan is silence about what was not
# checked, not a verdict. If this assertion ever has to be deleted, the change
# that deleted it is the bug.
check_contains "says a clean scan is not a review" "$out" "That is not a review."
check_not_contains "never prints PASS" "$out" "PASS"

suite "the two leaks from the incident report"
# Both shipped in a real deployment that had just passed check-drift.sh clean.
d=$(mkdep incident)
cat > "$d/proxy/030_fal.py" <<'PY'
import audit
def request(flow):
    audit.log_event("cred_injected", provider="fal", path=flow.request.path)
PY
cat > "$d/proxy/040_telegram.py" <<'PY'
import audit
def request(flow):
    api_method = flow.request.path.split("/")[2]
    audit.log_event("cred_injected", provider="telegram", endpoint=api_method)
PY
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "030_fal.py — raw path in an audit event" "$out" "logs a raw request path"
check_contains "040_telegram.py — split off a raw path" "$out" "splits a raw path"
check_contains "names the offending file" "$out" "proxy/030_fal.py"
check_contains "quotes the offending line" "$out" "path=flow.request.path"

suite "one planted violation per fail-severity check"
d=$(mkdep planted)
# Built at runtime, never committed. A credential-shaped literal in this file
# would trip the lint's own repo-wide sweep, and the honest fix is to not put
# one in the repo rather than to add another exclusion to that sweep.
FAKE_GH="ghp_$(printf 'a%.0s' $(seq 26))"
cat > "$d/proxy/050_custom.py" <<PY
import audit
SECRET = "$FAKE_GH"
def request(flow):
    if flow.request.pretty_host != "github.com":
        return
    try:
        pass
    except Exception as e:
        audit.log_event("failed", provider="custom", error=str(e))
PY
printf 'location /github/ {\n  proxy_pass http://broker:8080/github/token;\n}\n' \
  > "$d/cred-gateway/wide.conf"
printf 'location = /anthropic/cred {\n  proxy_pass http://broker:8080/anthropic/cred;\n}\n' \
  > "$d/cred-gateway/raw.conf"
sed -i "s|GH_TOKEN: proxy-injected|GH_TOKEN: $FAKE_GH|" "$d/compose.yaml"
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "pretty_host" "$out" "decides on the client-supplied Host header"
check_contains "github.com matched" "$out" "matches github.com"
check_contains "exception quoted" "$out" "quotes an exception"
check_contains "credential-shaped literal" "$out" "credential-shaped string"
check_contains "prefix-match location" "$out" "prefix-match location"
check_contains "raw-credential route exposed" "$out" "exposes a raw-credential broker route"
check_contains "real credential in compose" "$out" "other than the inert placeholder"

suite "an addon steered by a client header is a finding; stripping one is not"
# The #38 bug, generalised. The lab writes these headers, so binding one to a
# name lets the untrusted side choose which credential gets attached. The
# negative case is the load-bearing half: dropping a client header is correct
# and must stay clean, or the check pushes authors toward not stripping at all.
d=$(mkdep header-selector)
cat > "$d/proxy/070_selector.py" <<'PY'
import audit
def request(flow):
    if flow.request.host != "api.example.com":
        return
    tier = flow.request.headers.pop("X-Tier", "readonly")
    flow.request.headers["Authorization"] = "Bearer " + _token(tier)
PY
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "names the pattern" "$out" "binds a client-supplied request header"
check_contains "quotes the offending line" "$out" "X-Tier"

d=$(mkdep header-strip)
cat > "$d/proxy/070_strip.py" <<'PY'
import audit
PROFILE = "workers-deploy"
def request(flow):
    if flow.request.host != "api.example.com":
        return
    flow.request.headers.pop("X-Tier", None)
    del flow.request.headers["Authorization"]
    flow.request.headers["Authorization"] = "Bearer " + _token(PROFILE)
PY
out=$(run "$d")
check_contains "dropping a client header stays clean" "$out" "0 fail"
check_contains "and exits 0" "$out" "EXIT=0"

suite "a wildcard an addon injects for is a note; a multi-tenant one is a failure"
# The rule from #39: a wildcard is safe for credential injection only when the
# entire suffix is single-tenant. Google holds every name under googleapis.com;
# anyone can register a workers.dev subdomain, so injecting for that suffix
# hands a live token to whoever did.
#
# Both halves are load-bearing. Failing on every wildcard would block the GCP
# addon #41 ships and teach authors to route around the check; noting on the
# multi-tenant ones would let a real handover through as advice.
d=$(mkdep wildcard-multitenant)
cat > "$d/proxy/080_deploy.py" <<'PY'
import audit
import hostmatch
def request(flow):
    if not hostmatch.matches(flow.request.host, ["*.workers.dev"]):
        return
    flow.request.headers["Authorization"] = "Bearer " + _token()
PY
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "names the pattern" "$out" "wildcard suffix anyone can register under"
check_contains "quotes the offending line" "$out" "*.workers.dev"

d=$(mkdep wildcard-singletenant)
cat > "$d/proxy/080_gcp.py" <<'PY'
import audit
import hostmatch
def request(flow):
    if not hostmatch.matches(flow.request.host, ["*.googleapis.com"]):
        return
    flow.request.headers["Authorization"] = "Bearer " + _token()
PY
out=$(run "$d")
check_contains "a single-tenant suffix does not fail the run" "$out" "EXIT=0"
check_contains "but is still noted" "$out" "is the whole suffix single-tenant?"
check_contains "and quotes the line" "$out" "*.googleapis.com"
# One finding per line, not two. The note check excludes the multi-tenant list
# and the fail check is exactly that list, so the halves cannot both fire.
check_contains "the multi-tenant half stays silent" "$out" "0 fail"

suite "a wildcard in an addon that attaches no credential is not this check's business"
# 001_allowlist.py answers "may the lab reach this host", not "should a
# credential be attached". A deployment writing its own egress rules must not
# be told off for the entries that addon exists to hold.
d=$(mkdep wildcard-noinject)
cat > "$d/proxy/080_filter.py" <<'PY'
import audit
import hostmatch
BLOCKED = ["*.workers.dev", "*.pages.dev"]
def request(flow):
    if hostmatch.matches(flow.request.host, BLOCKED):
        flow.response = None
PY
out=$(run "$d")
check_contains "no finding at all" "$out" "0 fail"
check_contains "not even a note" "$out" "0 note"
check_contains "and exits 0" "$out" "EXIT=0"

suite "an addon documenting the anti-pattern is not reporting it"
# Every addon in this repo explains in prose the thing it must not do, so a
# docstring quoting `["*.workers.dev"]` is the common case rather than the
# exotic one. The same-line docstring strip has to survive the quote
# characters inside it, or the house style becomes a source of false failures.
d=$(mkdep wildcard-docstring)
cat > "$d/proxy/080_documented.py" <<'PY'
"""Never inject for ["*.workers.dev"] — anyone can register one."""
import audit
def request(flow):
    if flow.request.host != "api.example.com":
        return
    flow.request.headers["Authorization"] = "Bearer " + _token()
PY
out=$(run "$d")
check_contains "prose is not code" "$out" "0 fail"
check_contains "and not a note either" "$out" "0 note"

suite "000_policy.py is exempt from the pretty_host check, and only it"
# It ORs pretty_host with the real host to widen a block, which is safe. The
# exemption is positional, so it must not leak to any other file.
d=$(mkdep policy-exempt)
out=$(run "$d")
check_contains "stock deployment is clean" "$out" "0 fail"
cp "$d/proxy/000_policy.py" "$d/proxy/060_copy.py"
out=$(run "$d")
check_contains "the same code under another name is flagged" "$out" "decides on the client-supplied Host header"

suite "an unvendored policy addon is a note, not a failure"
# It was a failure until 1.10.0, when the proxy image started carrying the
# addon: from that release an absent copy is the correct shape and a vendored
# one is dead weight. Which case a deployment is in depends on its pin, and
# this script deliberately reads no pin — check-drift.sh owns that question now
# and answers it per tag. What stays here is the signal, downgraded, so it does
# not disappear for someone running only this script.
d=$(mkdep nopolicy)
rm "$d/proxy/000_policy.py"
out=$(run "$d")
check_contains "does not fail the run on its own" "$out" "EXIT=0"
check_contains "still says something" "$out" "000_policy.py is not vendored"
check_contains "and names the version the answer turns on" "$out" "v1.10.0"
check_contains "and points at the script that knows the pin" "$out" "check-drift.sh"

suite "a misordered policy addon is still a failure"
# The other half of the old suite name, which never actually asserted it. This
# one is a pure property of the files present — no pin involved — so unlike the
# check above it stays a failure. A vendored policy addon that loads after a
# provider addon lets that addon act on a request the policy would have denied.
#
# Done by adding a file that sorts ahead of it rather than by renaming the
# policy addon: only 000_policy.py is exempt from the pretty_host rule, so a
# renamed copy trips *that* check instead and the suite would pass for the
# wrong reason. It did, on the first attempt here.
d=$(mkdep misordered)
printf 'def request(flow):\n    pass\n' > "$d/proxy/000_aaa.py"
out=$(run "$d")
check_contains "exits 1" "$out" "EXIT=1"
check_contains "names what loaded first instead" "$out" "first addon is 000_aaa.py"

suite "unmediated egress is a finding, in all three of its shapes"
# internal: true on the lab network is what makes 001_allowlist.py enforcing
# rather than advisory. Off is the pre-toggle status quo, so this has to fire on
# a compose file that never had the key as well as on one that opted out.
d=$(mkdep egress)
out=$(run "$d")
check_contains "the shipped default is clean" "$out" "0 fail"

d=$(mkdep egress-nokey)
sed -i '/internal: /d' "$d/compose.yaml"
out=$(run "$d")
check_contains "no internal: key at all is a finding" "$out" "no \`internal:\` key"
check_contains "and fails the run" "$out" "EXIT=1"

d=$(mkdep egress-off)
sed -i 's/internal: ${LAB_INTERNAL:-true}/internal: false/' "$d/compose.yaml"
out=$(run "$d")
check_contains "an explicit opt-out is a finding" "$out" "lab network is not internal"

d=$(mkdep egress-baddefault)
sed -i 's/internal: ${LAB_INTERNAL:-true}/internal: ${LAB_INTERNAL:-false}/' "$d/compose.yaml"
out=$(run "$d")
check_contains "a flipped default is a finding" "$out" "lab network is not internal"

suite "the egress check reads the network, not the service of the same name"
# compose.yaml declares both a `lab:` service and a `lab:` network. An earlier
# cut matched the service block and only looked correct because the real
# network further down happened to supply the key it wanted.
d=$(mkdep egress-scope)
line=$(grep -n 'internal:' "$d/compose.yaml" | cut -d: -f1)
svc=$(grep -n '^  lab:' "$d/compose.yaml" | head -1 | cut -d: -f1)
sed -i '/internal: /d' "$d/compose.yaml"
out=$(run "$d")
check_not_contains "does not point at the service block" "$out" " $svc: lab network"

suite "a lab that sets only uppercase proxy vars is a finding"
# The deployment-facing half. Existing deployments predate this and will start
# seeing it, which is the intended behaviour: their gRPC clients are not being
# proxied and nothing said so.
d=$(mkdep proxycase)
out=$(run "$d")
check_contains "the shipped default is clean" "$out" "0 fail"

d=$(mkdep proxycase-upperonly)
sed -i '/^[[:space:]]*http_proxy:/d; /^[[:space:]]*https_proxy:/d' "$d/compose.yaml"
out=$(run "$d")
check_contains "uppercase alone is a finding" "$out" "which gRPC ignores"
check_contains "and fails the run" "$out" "EXIT=1"

suite "note-severity findings do not fail the run"
d=$(mkdep noteonly)
# observer published on all interfaces: worth saying, not worth failing on.
sed -i 's|127.0.0.1:9000:9000|9000:9000|' "$d/compose.yaml"
out=$(run "$d")
check_contains "still exits 0" "$out" "EXIT=0"
check_contains "but reports the note" "$out" "not bound to loopback"

suite "refuses a directory that is not a deployment"
mkdir -p "$TMPD/empty"
out=$(run "$TMPD/empty")
check_contains "exits 2" "$out" "EXIT=2"
check_contains "says why" "$out" "is this a deployment of this stack"

suite "the lint and the scanner share one implementation"
# #26's whole premise: two copies of these patterns would drift, and the drift
# would be invisible because each copy keeps passing its own tests. Structural
# assertions, because a behavioural one cannot prove the absence of a second
# copy.
lint="$REPO_ROOT/tests/integration/00-config-lint.test.sh"
check_contains "the lint sources the library" "$(cat "$lint")" 'scripts/lib/invariants.sh'
check_contains "the scanner sources the library" "$(cat "$INV_SH")" 'lib/invariants.sh'
for fn in inv_pretty_host inv_raw_path_logged inv_raw_path_split inv_github_com_matched \
          inv_exception_quoted inv_location_prefix inv_raw_cred_endpoint inv_real_credential \
          inv_header_selector inv_injection_wildcard_multitenant; do
  check_contains "lint calls $fn" "$(cat "$lint")" "$fn"
done
# The patterns themselves must exist in exactly one place. Prose is fine and
# wanted — the lint still explains what each suite guards — so comment lines
# and backticked mentions are excluded; what must not reappear is a second
# *implementation*.
#
# Only patterns distinctive enough that an occurrence *is* an implementation.
# A bare identifier like `pretty_host` appears in suite titles and failure
# messages too, so counting it proves nothing — "lint calls inv_pretty_host"
# above is what covers that one.
for pat in 'path=flow\.request\.path' 'flow\.request\.path\.split' ; do
  hits=$(grep -n "$pat" "$lint" | grep -v ':[[:space:]]*#' | grep -vc '`' || true)
  check "the lint inlines no executable copy of /$pat/" "0" "$hits"
done

finish
