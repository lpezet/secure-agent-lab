#!/usr/bin/env bash
# invariants.sh — static checks that a single file is safe on its own terms.
#
# Sourced by two callers that ask different questions:
#
#   tests/integration/00-config-lint.test.sh   is OUR code safe?
#   scripts/check-invariants.sh                is YOUR code safe?
#
# One copy on purpose. These patterns encode incidents — a leaked query string,
# a spoofed Host, a fail-open strip — and two copies of them would drift, which
# is the failure this repo documents everywhere else.
#
# Contract for every inv_* function:
#   inv_<name> <file>   → prints "LINE: evidence" per finding on stdout
#                         returns 0 when clean, 1 when it found something
#
# Dependency-free: bash, grep, sed, awk. No git, no jq, no network — a
# deployment must be able to run this against its own files with nothing
# installed and no checkout of this repo.
#
# These are greps. They check a known list and cannot prove a file is safe.
# Callers must never render a clean result as "pass" — see check-invariants.sh.

# ---------------------------------------------------------------- shared data

# Broker routes that must never be exposed through a cred-gateway snippet:
# each hands over a reusable secret rather than spending it on the lab's behalf.
#
# Static on purpose. The scanner runs on a deployment with no checkout, so it
# cannot derive this from bank/*/provider.json the way the lint does. Instead
# 00-config-lint asserts this list is a SUPERSET of every "exposed": false route
# in the bank — so adding a provider whose unexposed route is missing here fails
# upstream CI rather than silently narrowing what a deployment gets checked for.
INV_DENY_PATHS="/github/token /anthropic/cred /anthropic/key /cloudflare/token"

# Env vars that must hold the inert placeholder, never a real credential.
INV_PLACEHOLDER_VARS="GH_TOKEN CLOUDFLARE_API_TOKEN ANTHROPIC_API_KEY"
INV_PLACEHOLDER_VALUE="proxy-injected"

# Suffixes anyone can register a name under. A credential injected for
# `*.<suffix>` is handed to whoever registered the subdomain it was aimed at,
# which is a direct handover rather than a widened match.
#
# The list will never be complete, and that is why the wildcard check has two
# halves: this list is the `fail`, and every other wildcard gets a `note`
# pointing at the single-tenant rule. A clean scan is not a pass — see the
# header. Contrast `*.googleapis.com`, where Google holds every name beneath
# the suffix, which is the case the note exists to permit.
INV_MULTITENANT_SUFFIXES='workers.dev
pages.dev
myshopify.com
herokuapp.com
vercel.app
netlify.app
s3.amazonaws.com
blob.core.windows.net
github.io'

# Credential shapes. Length-bounded so `.env.example` stubs (sk-ant-…, ghp_xxx)
# do not trip while a real key still would.
INV_CRED_PATTERNS='sk-ant-[A-Za-z0-9_-]{20,}
ghp_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
BEGIN RSA PRIVATE KEY
BEGIN PRIVATE KEY
BEGIN OPENSSH PRIVATE KEY'

# ------------------------------------------------------------------- helpers

# Two characters these checks must match literally, held as constants rather
# than escaped inline. `'\''` gymnastics inside a "$( … )" is how this file
# first failed to parse at all, and a security check that does not load is
# worse than one that is slightly ugly.
_INV_SQ=$(printf '\047')   # '
_INV_BT=$(printf '\140')   # `
_INV_NL='
'

# _inv_strip_py <file> — python source with comments and docstrings removed.
# Every shipped addon explains these anti-patterns in its own prose; without
# this, each one reports itself.
_inv_strip_py() {
  awk '
    { line = $0; sub(/#.*$/, "", line) }
    # Same-line docstrings close as fast as they open, so the block counter
    # below never sees them. Drop them first.
    #
    # Greedy .* between the delimiters, not [^"]*: a docstring quoting the
    # anti-pattern it warns about — """never write ["*.workers.dev"] here""" —
    # contains quote characters, and the excluding form stops at the first one
    # and leaves the line looking like code. Every addon here documents the
    # pattern it must not use, so that is the common case, not the exotic one.
    { sub(/""".*"""/, "", line); sub(/\x27\x27\x27.*\x27\x27\x27/, "", line) }
    { q = gsub(/"""/, "&", line) + gsub(/\x27\x27\x27/, "&", line) }
    ds  { if (q % 2 == 1) ds = 0; print ""; next }
    q % 2 == 1 { ds = 1; print ""; next }
    { print line }
  ' "$1"
}

# _inv_report <file> <grep-output> — pass grep -n output through unchanged,
# returning 1 when there was any. Keeps every check's tail identical.
_inv_report() {
  [ -z "$2" ] && return 0
  printf '%s\n' "$2"
  return 1
}

# ------------------------------------------------------- checks: proxy addons

# The trail is a plaintext file observer serves over HTTP, and
# flow.request.path includes the query string. For a provider carrying its
# credential in the URL, `path=flow.request.path` writes a live secret into it.
inv_raw_path_logged() {
  _inv_report "$1" "$(grep -n 'path=flow\.request\.path' "$1" 2>/dev/null | grep -v "$_INV_BT")"
}

# The same bug wearing a parse. Because the raw path carries the query string,
# the last segment absorbs it: on /bot<TOKEN>/sendMessage?chat_id=…&text=…,
# split("/")[2] is the message body, not the method. The token sits in segment
# 1 and stays out, which is exactly what let the mistake read as safe.
inv_raw_path_split() {
  _inv_report "$1" "$(grep -n 'flow\.request\.path\.split("/")' "$1" 2>/dev/null | grep -v "$_INV_BT")"
}

# pretty_host prefers the client-supplied Host header, so matching on it lets
# `curl -H 'Host: api.anthropic.com' http://my-server/` collect a real injected
# credential. First non-obvious invariant in CLAUDE.md, with a real regression
# behind it.
#
# 000_policy.py is the one legitimate use — it ORs pretty_host with the real
# host to *widen* a block, and trusting a claimed Host to deny more is safe.
# Callers skip that file by name rather than trying to tell the two apart here.
inv_pretty_host() {
  _inv_report "$1" "$(_inv_strip_py "$1" | grep -n 'pretty_host')"
}

# An exception message is free text from whoever raised it, and providers
# interpolate vendor responses into theirs. Only .code and .name are safe to
# put in an audit event; detail belongs on stdout, which observer does not read.
#
# Allowlist, not blocklist: enumerating the ways of writing "the error" loses to
# the next one invented. Strip the field names, strip the two permitted
# references, flag whatever still names the exception.
inv_exception_quoted() {
  _inv_report "$1" "$(awk '
    { line = $0; sub(/[[:space:]]*(\/\/|#).*$/, "", line) }
    !inside && line ~ /log_?[Ee]vent\(/ { inside = 1; start = NR; buf = ""; depth = 0 }
    inside {
      buf = buf " " line
      n = gsub(/\(/, "(", line); depth += n
      n = gsub(/\)/, ")", line); depth -= n
      if (depth > 0) next
      inside = 0
      t = buf
      # Brace-free quoted literals are values, not references. An f-string is a
      # reference wearing a literal, so those stay visible; so do backticks.
      gsub(/"[^"{}]*"/, "", t); gsub(/\x27[^\x27{}]*\x27/, "", t)
      gsub(/(err|error|e|ex|exc)[[:space:]]*[:=]/, "", t)
      gsub(/(err|error|e|ex|exc)\.(code|name)/, "", t)
      if (t ~ /(^|[^[:alnum:]_.])(err|error|e|ex|exc)([^[:alnum:]_]|$)/) print start ": " buf
    }' "$1" 2>/dev/null)"
}

# A request header is written by the lab container. An addon that reads one
# into a variable is letting the untrusted side steer what happens next — and in
# a credential-injecting addon, what happens next is which credential gets
# attached. 030_cloudflare.py shipped exactly this: `X-Cf-Profile` chose the
# profile, so a ladder of dev/qa/prod profiles was decorative, and the audit
# line recorded the escalated profile as though it had been authorised.
#
# Stripping is not reading. A bare `flow.request.headers.pop("X-Foo", None)` or
# `del flow.request.headers["Authorization"]` is the correct way to drop a
# client header and does not match; binding the value to a name does.
#
# Same family as inv_pretty_host: both catch a decision made from client-
# supplied data. This one is the general case, that one the specific host bug.
inv_header_selector() {
  _inv_report "$1" "$(_inv_strip_py "$1" \
    | grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*flow\.request\.headers\.(get|pop)\(')"
}

# _inv_injection_wildcards <file> — wildcard host literals, but only in a file
# that also attaches a credential header.
#
# The scoping is the point. An allowlist and an injection addon both match
# hosts, and they are asking different questions:
#
#   may the lab REACH this host?      too wide → it talks to something it should not
#   should a CREDENTIAL be attached?  too wide → a live token goes to whoever owns it
#
# Only the second is this check's business, so a deployment writing its own
# allowlist with `*.cdn.example.com` in it is not told off for the entry that
# addon exists to hold. 001_allowlist.py reads its patterns from a file and
# carries no literals, so it stays clean either way.
_inv_injection_wildcards() {
  local stripped
  stripped=$(_inv_strip_py "$1" 2>/dev/null) || return 0
  printf '%s\n' "$stripped" \
    | grep -qE 'flow\.request\.headers[[:space:]]*\[[^]]*\][[:space:]]*=|flow\.request\.headers\.update\(' \
    || return 0
  printf '%s\n' "$stripped" | grep -nE \
    "\"\\*\\.[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}\"|${_INV_SQ}\\*\\.[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}${_INV_SQ}"
}

# _inv_multitenant_filter keep|drop — partition wildcard findings by the list.
# Matches the literal ending at the suffix, so `*.workers.dev` is caught and
# `*.mine.workers.dev` is not: the second is single-tenant if you hold `mine`.
_inv_multitenant_filter() {
  local pats="" s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    pats="$pats*.$s\"$_INV_NL*.$s$_INV_SQ$_INV_NL"
  done <<EOF
$INV_MULTITENANT_SUFFIXES
EOF
  if [ "$1" = keep ]; then
    grep -F -f <(printf '%s' "$pats") || true
  else
    grep -F -v -f <(printf '%s' "$pats") || true
  fi
}

# A wildcard is safe for credential injection only when the entire suffix is
# single-tenant — one party holds every name under it. `*.googleapis.com`
# qualifies; `*.workers.dev` does not, and injecting for it hands a live token
# to whoever registered the subdomain.
#
# Deliberately a note, not a failure: legitimate wildcards exist and #41 ships
# one. What a note cannot do is stay silent about the suffixes nobody thought
# to list, which is the honest shape given a hardcoded list.
inv_injection_wildcard() {
  _inv_report "$1" "$(_inv_injection_wildcards "$1" | _inv_multitenant_filter drop)"
}

# The same finding where the suffix is known to be multi-tenant. That is not a
# judgment call, so it fails.
inv_injection_wildcard_multitenant() {
  _inv_report "$1" "$(_inv_injection_wildcards "$1" | _inv_multitenant_filter keep)"
}

# git push/pull to github.com authenticates through the credential helper, not
# header injection. Matching it here collides with git's own Basic-auth
# handshake inside the MITM'd tunnel.
inv_github_com_matched() {
  _inv_report "$1" "$(_inv_strip_py "$1" | grep -nE "\"github\\.com\"|${_INV_SQ}github\\.com${_INV_SQ}")"
}

# --------------------------------------------------- checks: gateway snippets

# `location /github/` exposes every broker route under it, including
# /github/token. Exact match only.
inv_location_prefix() {
  _inv_report "$1" "$(grep -nE '^[[:space:]]*location[[:space:]]+[^=]' "$1" 2>/dev/null)"
}

# Exposing one of these hands the lab a reusable secret instead of spending it
# on the lab's behalf. They belong in a proxy addon.
inv_raw_cred_endpoint() {
  local f="$1" p out=""
  for p in $INV_DENY_PATHS; do
    out="$out$(grep -nE "location[[:space:]]*=[[:space:]]*$p([[:space:]]|\{|$)" "$f" 2>/dev/null)"$'\n'
  done
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$f" "$out"
}

# ---------------------------------------------------------- checks: compose

# These are dummy values satisfying a client's "am I authenticated?" check; the
# proxy strips and replaces them at the wire. A real one here is a credential
# sitting in the untrusted container.
inv_real_credential() {
  local f="$1" var line num rest val out=""
  for var in $INV_PLACEHOLDER_VARS; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # grep -n prefixes "NNN:", and the YAML pair adds its own colon, so the
      # value is what follows the *second* one.
      num=${line%%:*}; rest=${line#*:}
      val=$(printf '%s' "${rest#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d "\"$_INV_SQ")
      case "$val" in
        # An unresolved ${VAR} interpolation is the deployment's business, not
        # a literal credential — flagging it would punish the safe pattern.
        "$INV_PLACEHOLDER_VALUE"|'${'*|'') ;;
        *) out="$out$num: $var is '$val', not '$INV_PLACEHOLDER_VALUE'"$'\n' ;;
      esac
    done <<EOF
$(grep -nE "^[[:space:]]*$var:" "$f" 2>/dev/null)
EOF
  done
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$f" "$out"
}

# observer publishes the audit trail over HTTP with no auth. Binding its port to
# all interfaces puts the trail on the network.
inv_observer_port() {
  _inv_report "$1" "$(grep -nE '^[[:space:]]*-[[:space:]]*"?[0-9]+:9000"?' "$1" 2>/dev/null)"
}

# ---------------------------------------------------------- checks: providers

# A credential read from an env VALUE is visible in `docker inspect` and
# /proc/<pid>/environ. The convention is a *_PATH var naming a file under the
# read-only /secrets mount.
inv_env_value_credential() {
  _inv_report "$1" "$(grep -nE 'process\.env\.[A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)([^A-Za-z0-9_]|$)' "$1" 2>/dev/null \
    | grep -v '_PATH' | grep -v "$_INV_BT")"
}

# The lab network must have no default gateway. Without that, HTTP_PROXY is a
# request the agent can decline — `curl --noproxy '*'` leaves the box without
# touching the proxy, so the egress allowlist governs cooperating traffic only.
#
# Reports the *absence* of the control, so it fires on a compose file that never
# had the key as well as on one that opted out. A deployment predating this is
# the common case and is exactly what should be told.
inv_egress_unmediated() {
  local f="$1" block line
  # Only the lab network. `secure` is deliberately not internal: broker calls
  # provider APIs directly through it.
  #
  # Scoped to the top-level `networks:` section. A service is commonly named
  # `lab` too, and an earlier cut of this matched that block instead — it only
  # looked correct because the real network block further down supplied the
  # key it was looking for.
  block=$(awk '
    /^networks:[[:space:]]*$/ { innet = 1; next }
    /^[^[:space:]#]/          { innet = 0 }
    innet && /^[[:space:]]+lab:[[:space:]]*$/ { inlab = 1; print NR ": " $0; next }
    innet && inlab && /^[[:space:]]{1,2}[a-zA-Z_-]+:/ { inlab = 0 }
    innet && inlab { print NR ": " $0 }
  ' "$f" 2>/dev/null)
  [ -n "$block" ] || return 0            # no lab network declared here at all

  line=$(printf '%s\n' "$block" | grep 'internal:' || true)
  if [ -z "$line" ]; then
    printf '%s: lab network has no `internal:` key — egress is unmediated\n' \
      "$(printf '%s' "$block" | head -1 | cut -d: -f1)"
    return 1
  fi
  # An unresolved ${LAB_INTERNAL:-true} is the shipped default and is fine.
  case "$line" in
    *'internal: false'*|*'internal: "false"'*|*':-false}'*)
      printf '%s\n' "${line%%:*}: lab network is not internal — egress is unmediated"
      return 1 ;;
  esac
  return 0
}

# gRPC reads `grpc_proxy`, `https_proxy` and `http_proxy` — lowercase only. A
# lab that sets HTTP_PROXY and not http_proxy proxies its HTTP clients and not
# its gRPC ones, which is invisible until something speaks gRPC and then looks
# like a network fault rather than a proxy one.
#
# Fails rather than notes because of what it means with `internal: false`: the
# lab has a default gateway, so an unproxied gRPC client egresses directly,
# past the allowlist and absent from the audit trail. With `internal: true` it
# fails closed instead — still wrong, just quietly.
#
# Measured in #48: zero flows reached the proxy with only the uppercase forms
# set, two with the lowercase ones.
inv_proxy_env_case() {
  local f="$1" upper lower
  upper=$(grep -nE '^[[:space:]]*HTTP(S)?_PROXY:' "$f" 2>/dev/null | head -1)
  [ -n "$upper" ] || return 0            # no proxy env here at all
  lower=$(grep -cE '^[[:space:]]*http(s)?_proxy:' "$f" 2>/dev/null)
  [ "${lower:-0}" -ge 1 ] && return 0
  printf '%s: sets HTTP_PROXY but not http_proxy — gRPC reads lowercase only\n' \
    "${upper%%:*}"
  return 1
}

# --------------------------------------------------------------- checks: any

# A credential-shaped literal anywhere in a deployment file. The lint sweeps the
# whole repo with git grep; here the same patterns run per file, so a secret
# pasted into an addon or a compose file is caught even though nothing tracks it.
inv_credential_material() {
  local f="$1" pat out=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    out="$out$(grep -nE "$pat" "$f" 2>/dev/null | cut -c1-120)"$'\n'
  done <<EOF
$INV_CRED_PATTERNS
EOF
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$f" "$out"
}

# ----------------------------------------------- checks: the secrets directory
#
# A new class. Every check above reads a file INSIDE the deployment — an addon,
# a provider, a snippet, a compose file. These read deployment *inputs*, which
# live on the host, outside anything the scanner is otherwise pointed at. They
# run only when `--secrets-dir` is given, and their absence is reported rather
# than passed over.
#
# THE RULE: the credential's principal must not be the human operator.
#
# Value isolation survives a personal token — the agent still never reads it,
# the broker holds it, the proxy injects it. Authority isolation does not: the
# agent acts as the human, everywhere that human can reach. Only the second
# depends on what is in this directory, and it is the one that sets blast
# radius. The mechanism is fine and the setup is the whole risk.
#
# NOTHING HERE MAY PRINT A FILE'S CONTENTS. Detection is by shape — a prefix, a
# PEM header, a JSON type field — using quiet greps, and output is a filename
# and a verdict. A check that leaks the credential it is checking would be a
# worse bug than the one it looks for. `tests/integration/08-credential-principal`
# asserts that directly, against real credential-shaped fixtures.

# _inv_adc_type <file> — the TOP-LEVEL `type` field of a Google ADC file.
# The value is a type name, never a secret.
#
# Depth matters, and a plain grep gets this wrong on a real file. An
# impersonated ADC nests the credential that does the impersonating:
#
#   { "service_account_impersonation_url": "...",
#     "source_credentials": { ..., "type": "authorized_user" },
#     "type": "impersonated_service_account" }
#
# gcloud writes those keys alphabetically, so the nested `authorized_user`
# comes FIRST — and reading it would call the safest shape this stack supports
# the operator's own identity, on every deployment that uses it. Found by
# running this against a real ~/.config/gcloud ADC rather than a fixture.
#
# So: track brace depth, ignore anything inside a string, report `type` only at
# depth 1. awk rather than a JSON parser because this must keep working on a
# deployment with nothing installed.
_inv_adc_type() {
  awk '
    {
      line = $0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { i++; continue }
          if (c == "\"") { instr = 0; buf = buf "\"" }
          else buf = buf c
          continue
        }
        if (c == "\"") { instr = 1; buf = buf "\"" ; continue }
        if (c == "{" || c == "[") { depth++; buf = buf c; continue }
        if (c == "}" || c == "]") { depth--; buf = buf c; continue }
        # Record depth alongside the text so the match below can be scoped.
        buf = buf c
        if (c == ":") buf = buf "\001" depth "\002"
      }
    }
    END {
      # "type"<:><depth 1><"value">
      if (match(buf, /"type"[ \t]*:\001 ?1\002[ \t]*"[a-z_]+"/)) {
        seg = substr(buf, RSTART, RLENGTH)
        sub(/.*"/, "", seg)
        n2 = match(buf, /"type"[ \t]*:\001 ?1\002[ \t]*"[a-z_]+"/)
        seg = substr(buf, RSTART, RLENGTH)
        gsub(/.*\002[ \t]*"/, "", seg); gsub(/".*/, "", seg)
        print seg
      }
    }
  ' "$1" 2>/dev/null
}

# _inv_classify <file> — machine | human | unknown | none, on stdout.
# `none` means "a credential with no machine identity to compare against".
_inv_classify() {
  local f="$1" adc
  adc=$(_inv_adc_type "$f")
  case "$adc" in
    # A bare authorized_user IS the operator: their own Google identity, with
    # no service account in front of it.
    authorized_user) printf 'human'; return ;;
    service_account|impersonated_service_account|external_account)
      printf 'machine'; return ;;
  esac

  # A GitHub App key, or a service-account key. Either way a machine.
  if grep -q 'BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null; then
    printf 'machine'; return
  fi

  # GitHub personal tokens. ghp_/github_pat_ are a user's own; gho_/ghu_ are
  # OAuth-user tokens, equally the human. ghs_ is a server-to-server
  # installation token — a machine, but short-lived and not a thing to store
  # here, so it is left to `unknown` rather than blessed.
  if grep -qE '(^|[^A-Za-z0-9_])(ghp_|github_pat_|gho_|ghu_)[A-Za-z0-9_]{20,}' "$f" 2>/dev/null; then
    printf 'human'; return
  fi

  # Anthropic has no machine identity at all — no App, no service account, no
  # impersonation. There is nothing to check, and saying so is the point.
  if grep -qE 'sk-ant-' "$f" 2>/dev/null; then
    printf 'none'; return
  fi

  printf 'unknown'
}

# inv_credential_principal <dir> — credentials whose principal is the operator.
# Directory-level, like inv_policy_addon_first, so it is called directly rather
# than through the registry.
inv_credential_principal() {
  local d="$1" f out=""
  [ -d "$d" ] || return 0
  # -maxdepth 1 and no -L: never follow a path out of the directory given.
  for f in $(find "$d" -maxdepth 1 -type f 2>/dev/null | sort); do
    [ "$(_inv_classify "$f")" = human ] || continue
    out="${out}0: $(basename "$f") — the principal is the operator, not a machine"$'\n'
  done
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$d" "$out"
}

# inv_credential_unclassified <dir> — everything this cannot vouch for.
# Separate function, and a note rather than a failure, because "I do not
# recognise this shape" and "this is the human" are different claims and only
# one of them is a finding. A clean run of the first with several of these is
# exactly the situation where a clean result must not read as a pass.
inv_credential_unclassified() {
  local d="$1" f kind out=""
  [ -d "$d" ] || return 0
  for f in $(find "$d" -maxdepth 1 -type f 2>/dev/null | sort); do
    kind=$(_inv_classify "$f")
    case "$kind" in
      none)
        out="${out}0: $(basename "$f") — this provider has no machine identity, so nothing here can be checked"$'\n' ;;
      unknown)
        out="${out}0: $(basename "$f") — shape not recognised; check by hand whose credential this is"$'\n' ;;
    esac
  done
  out=$(printf '%s' "$out" | grep -v '^$' || true)
  _inv_report "$d" "$out"
}

# ------------------------------------------------------- directory-level check

# 000_policy.py must run before any addon can act on a request; entrypoint.sh
# globs alphabetically. Not per-file, so it takes a directory.
inv_policy_addon_first() {
  local d="$1" first
  first=$(ls "$d"/*.py 2>/dev/null | head -1)
  [ -n "$first" ] || return 0
  first=$(basename "$first")
  [ "$first" = "000_policy.py" ] && return 0
  printf '0: first addon is %s, not 000_policy.py\n' "$first"
  return 1
}

# -------------------------------------------------------------- the registry
#
# Both callers dispatch from here, so neither can quietly check a different set.
# Fields: name|severity|applies-to|one-line description

INV_REGISTRY='raw_path_logged|fail|proxy_py|logs a raw request path, query string included
raw_path_split|fail|proxy_py|splits a raw path on "/", so the last segment holds the query string
pretty_host|fail|proxy_py|decides on the client-supplied Host header
header_selector|fail|proxy_py|binds a client-supplied request header to a name the addon acts on
injection_wildcard_multitenant|fail|proxy_py|injects a credential for a wildcard suffix anyone can register under
injection_wildcard|note|proxy_py|injects a credential for a wildcard host suffix — is the whole suffix single-tenant?
github_com_matched|fail|proxy_py|matches github.com, which the credential helper owns
exception_quoted|fail|proxy_py broker_js|audit event quotes an exception beyond .code/.name
location_prefix|fail|gateway_conf|prefix-match location exposes every route beneath it
raw_cred_endpoint|fail|gateway_conf|exposes a raw-credential broker route to the lab
real_credential|fail|compose|env var holds something other than the inert placeholder
env_value_credential|note|broker_js|credential read from an env value rather than a *_PATH file
observer_port|note|compose|observer port is not bound to loopback
credential_material|fail|proxy_py broker_js gateway_conf compose|credential-shaped string in a deployment file
egress_unmediated|fail|compose|lab network is not internal, so the proxy can be bypassed
proxy_env_case|fail|compose|sets only uppercase proxy vars, which gRPC ignores'

# inv_field <name> <1=severity|2=applies|3=description>
inv_field() {
  printf '%s\n' "$INV_REGISTRY" | awk -F'|' -v n="$1" -v i="$2" '$1 == n { print $(i+1); exit }'
}

# inv_checks_for <kind> — check names applying to a file kind, in registry order.
inv_checks_for() {
  printf '%s\n' "$INV_REGISTRY" | awk -F'|' -v k="$1" '
    { split($3, a, " "); for (i in a) if (a[i] == k) { print $1; break } }'
}

# inv_kind <path> — classify by directory and extension, the way a deployment
# is laid out. Prints nothing for a file we have no checks for.
inv_kind() {
  local f="$1" b d
  b=$(basename "$f"); d=$(basename "$(dirname "$f")")
  case "$b" in
    compose.yaml|compose.yml|docker-compose.yaml|docker-compose.yml) printf 'compose'; return ;;
  esac
  case "$d/$b" in
    proxy/*.py)         printf 'proxy_py' ;;
    broker/*.js)        printf 'broker_js' ;;
    cred-gateway/*.conf) printf 'gateway_conf' ;;
  esac
}
