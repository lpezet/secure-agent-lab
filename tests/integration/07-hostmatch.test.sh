#!/usr/bin/env bash
# stack/proxy/hostmatch.py — the shared host matcher. Unit tests, no docker.
#
# This is the only pure-unit suite here, and it earns that: the module is a
# security primitive with no I/O, and the cases that matter (evilexample.com,
# the apex, a trailing root dot) are one function call each. Standing up a
# container to ask whether a string ends with a dot would be theatre.
#
# python3 is a soft dependency, like jq in 00-config-lint: absent, this skips
# and the rest of the tier still runs. The behaviour it covers is also
# exercised end to end by 30-proxy-allowlist, which does need docker.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

if ! command -v python3 >/dev/null 2>&1; then
  suite "hostmatch unit tests"
  skip "python3 is not installed" "30-proxy-allowlist covers the same matching through the proxy"
  finish
fi

# The module is baked into the image at /opt/agent-proxy; here it is imported
# straight from the source tree, so this suite needs nothing built.
CASES=$(PYTHONPATH="$REPO_ROOT/stack/proxy" python3 - <<'PY'
import hostmatch

EX = ["api.example.com", "*.example.com"]

def emit(label, expected, actual):
    print(f"{label}\t{expected}\t{actual}")

def m(host, patterns=EX):
    return "yes" if hostmatch.matches(host, patterns) else "no"

# --- the suffix boundary, which is the whole reason this is shared code ---
emit("evilexample.com does not match *.example.com", "no", m("evilexample.com"))
emit("notexample.com does not match *.example.com", "no", m("notexample.com"))
emit("a.example.com matches *.example.com", "yes", m("a.example.com"))
emit("a.b.example.com matches *.example.com", "yes", m("a.b.example.com"))
# The apex is not a subdomain. A deployment wanting both lists both, which is
# what the EX pattern list above does via the exact entry.
emit("the apex matches only via its exact entry", "yes", m("api.example.com"))
emit("the apex does not match the wildcard alone", "no", m("example.com", ["*.example.com"]))

# --- normalisation ---
emit("uppercase host", "yes", m("A.EXAMPLE.COM"))
emit("uppercase pattern", "yes", hostmatch.matches("a.example.com", ["*.EXAMPLE.COM"]) and "yes" or "no")
emit("trailing root dot on a wildcard match", "yes", m("a.example.com."))
emit("trailing root dot on an exact match", "yes", m("api.example.com."))
emit("host carrying a port", "yes", m("a.example.com:443"))
emit("exact host carrying a port", "yes", m("api.example.com:8080"))
emit("normalize strips port and case", "api.example.com", hostmatch.normalize("API.Example.com:443"))
emit("normalize strips the root dot", "example.com", hostmatch.normalize("example.com."))
emit("normalize keeps a bare IPv6 literal", "::1", hostmatch.normalize("::1"))
emit("normalize unwraps a bracketed IPv6 with port", "::1", hostmatch.normalize("[::1]:8080"))
emit("normalize on empty is empty", "", hostmatch.normalize(""))

# --- dotless hosts: docker network aliases, which the allowlist fixture uses ---
emit("dotless host matches its exact entry", "yes", m("readonly-api", ["readonly-api"]))
emit("dotless host does not match a wildcard", "no", m("readonly-api", ["*.example.com"]))

# --- find() returns which pattern matched, not merely that one did ---
emit("find returns the exact pattern", "api.example.com", str(hostmatch.find("api.example.com", EX)))
emit("find returns the wildcard pattern", "*.example.com", str(hostmatch.find("a.example.com", EX)))
emit("find returns None for a miss", "None", str(hostmatch.find("nope.test", EX)))
# Specificity, not file order: reversing the list must not change the answer.
SPEC = ["*.example.com", "*.a.example.com"]
emit("longest suffix wins", "*.a.example.com", str(hostmatch.find("x.a.example.com", SPEC)))
emit("longest suffix wins regardless of order", "*.a.example.com",
     str(hostmatch.find("x.a.example.com", list(reversed(SPEC)))))
emit("exact beats a wildcard that also matches", "a.example.com",
     str(hostmatch.find("a.example.com", ["*.example.com", "a.example.com"])))

# --- uninterpretable patterns are skipped, and skipping denies ---
for bad in ["*", "*.", "a.*.com", "*foo.com", "", "has space.com"]:
    emit(f"pattern {bad!r} matches nothing", "no", m("a.example.com", [bad]))
emit("a bad pattern does not suppress a good one", "yes", m("a.example.com", ["*", "*.example.com"]))
emit("invalid() names the unusable ones", "['*', 'a.*.com']",
     str(hostmatch.invalid(["*", "api.example.com", "a.*.com", "*.example.com"])))
emit("invalid() is empty for a clean list", "[]", str(hostmatch.invalid(EX)))

# --- an empty or absent host never matches ---
emit("empty host matches nothing", "no", m(""))
emit("None host matches nothing", "no", m(None))

# --- the rule this module deliberately does NOT enforce ---
# *.workers.dev is multi-tenant and unsafe to inject for, and matches anyway:
# the policy lives in inv_injection_wildcard_multitenant, not here. If this
# assertion ever flips, the docstring and the invariant both need revisiting.
emit("a multi-tenant suffix still matches (policy lives in the lint)", "yes",
     m("victim.workers.dev", ["*.workers.dev"]))
PY
)
rc=$?

suite "hostmatch.matches — suffix boundaries, normalisation, specificity"
if [ "$rc" != 0 ] || [ -z "$CASES" ]; then
  ko "the module imports and runs" "python3 exited $rc; output: ${CASES:-<empty>}"
  finish
fi
ok "the module imports and runs"

while IFS=$'\t' read -r label expected actual; do
  [ -n "$label" ] || continue
  check "$label" "$expected" "$actual"
done <<EOF
$CASES
EOF

suite "the matcher is shared, not reimplemented"
# #39's premise: the algorithm was correct and private to one addon, so the
# next addon needing it had to write its own. Suffix matching reimplemented
# per addon is how pretty_host ended up in three files at once.
check_contains "001_allowlist.py imports it" \
  "$(cat stack/proxy/addons/001_allowlist.py)" "import hostmatch"
check_not_contains "001_allowlist.py keeps no private endswith matcher" \
  "$(grep -v '^\s*#' stack/proxy/addons/001_allowlist.py)" ".endswith("
check_contains "the Dockerfile bakes it in beside audit.py" \
  "$(cat stack/proxy/Dockerfile)" "COPY hostmatch.py /opt/agent-proxy/hostmatch.py"

finish
