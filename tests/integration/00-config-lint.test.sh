#!/usr/bin/env bash
# Static checks on committed config. No docker, no network — runs in ~1s.
# These guard invariants documented in CLAUDE.md that are easy to break in a
# hurry and expensive to notice: a prefix-match location, a real credential
# pasted into a compose file, an addon widened to match github.com.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT"

SNIPPETS=(examples/claude-code/cred-gateway/*.conf examples/dev-container/.devcontainer/cred-gateway/*.conf)
COMPOSES=(stack/compose.yaml examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml)

suite "cred-gateway snippets use exact-match locations"
# A prefix match like `location /github/` exposes every broker route under it,
# including /github/token. tests/integration/10 proves that leak is real.
for f in "${SNIPPETS[@]}"; do
  bad=$(grep -nE '^[[:space:]]*location[[:space:]]+[^=]' "$f" || true)
  if [ -z "$bad" ]; then ok "$f — all locations exact-match"
  else ko "$f — non-exact location" "$bad"; fi
done

suite "snippets do not expose raw-credential endpoints"
# These hand the dev container a usable secret rather than spending it on
# dev's behalf. They belong in a proxy addon, never in the gateway.
for f in "${SNIPPETS[@]}"; do
  for path in /github/token /anthropic/key /anthropic/cred /cloudflare/token; do
    if grep -q "location[[:space:]]*=[[:space:]]*$path\b" "$f"; then
      ko "$f — exposes $path" "raw credential reachable from dev"
    else
      ok "$f — does not expose $path"
    fi
  done
done

suite "snippets do not redeclare the rate-limit zone"
for f in "${SNIPPETS[@]}"; do
  if grep -q 'limit_req_zone' "$f"; then
    ko "$f — redeclares limit_req_zone" "declared at http level in stack/cred-gateway/nginx.conf"
  else
    ok "$f — references the shared creds zone only"
  fi
done

suite "cred-gateway base image ships no provider endpoints"
conf=stack/cred-gateway/nginx.conf
prov=$(grep -nE '^[[:space:]]*location[[:space:]]*=[[:space:]]*/(github|anthropic|cloudflare)' "$conf" || true)
if [ -z "$prov" ]; then ok "base nginx.conf has no provider locations"
else ko "base nginx.conf has provider locations" "$prov"; fi

check_contains "base nginx.conf includes gateway.d" "$(cat $conf)" 'include /etc/nginx/gateway.d/*.conf;'
if grep -qE '^[[:space:]]*location[[:space:]]*/[[:space:]]*\{' "$conf" && grep -q 'return 403' "$conf"; then
  ok "base nginx.conf keeps the default-deny location"
else
  ko "base nginx.conf default-deny missing" "location / { return 403; } is the backstop"
fi

suite "each example mounts its snippets read-only"
# Matches the container target and :ro, not the host directory name — the
# source path is the deployment's to choose, and pinning it here made this
# fail on a pure rename rather than on anything that weakened the boundary.
for c in examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml; do
  if grep -qE ':/etc/nginx/gateway\.d:ro( |$)' "$c"; then
    ok "$c — snippets mounted read-only at /etc/nginx/gateway.d"
  else
    ko "$c — snippet mount missing or writable" "snippets are the whitelist; dev must not be able to edit them"
  fi
done

suite "dev-container shadows .devcontainer as read-only"
# This example mounts ../ (the parent of .devcontainer) read-write at
# /workspace, so without the nested mount the agent can rewrite proxy/,
# broker/ and cred-gateway/ and wait for a restart. tests/integration/50 proves the
# shadow works at runtime.
c=examples/dev-container/.devcontainer/compose.yaml
if grep -q '\.\./\.devcontainer:/workspace/\.devcontainer:ro' "$c"; then
  ok "$c — nested read-only bind present"
else
  ko "$c — nested read-only bind missing" "agent could widen the proxy allowlist or gateway whitelist"
fi

suite "dev containers hold no real credentials"
# CLAUDE.md invariant: these are dummy values that satisfy client-side "am I
# authenticated?" checks. The proxy strips and replaces them at the wire level.
for c in "${COMPOSES[@]}"; do
  for var in GH_TOKEN CLOUDFLARE_API_TOKEN ANTHROPIC_API_KEY; do
    line=$(grep -E "^[[:space:]]*$var:" "$c" || true)
    [ -z "$line" ] && continue
    val=$(printf '%s' "$line" | sed 's/.*: *//' | tr -d '"'"'"' ')
    if [ "$val" = "proxy-injected" ]; then
      ok "$c — $var is the dummy placeholder"
    else
      ko "$c — $var is not 'proxy-injected'" "found: $val"
    fi
  done
done

suite "no credential material committed"
# Length-bounded so `.env.example` placeholders (sk-ant-..., ghp_xxx) do not
# trip the check while a real key still would.
for pat in 'sk-ant-[A-Za-z0-9_-]{20,}' 'ghp_[A-Za-z0-9]{20,}' 'github_pat_[A-Za-z0-9_]{20,}' \
           'BEGIN RSA PRIVATE KEY' 'BEGIN PRIVATE KEY' 'BEGIN OPENSSH PRIVATE KEY'; do
  hits=$(git grep -lE "$pat" -- . ':!tests/integration/00-config-lint.test.sh' 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "no match for /$pat/"
  else ko "credential-shaped string committed: /$pat/" "$hits"; fi
done

suite "audit events reference an exception only via .code or .name"
# Not the security control. The audit trail is written entirely by whatever
# provider and addon files a deployment mounts, and this suite cannot see
# those — PLAYBOOK.md's "What is safe to log" is what reaches them. What this
# guards is the files people copy: every generated stack starts by vendoring
# an example, so the anti-pattern must not ship in one.
#
# An exception message is free text from whoever raised it, and providers
# interpolate vendor responses into theirs (cloudflare.js: `Cloudflare API
# error: ${JSON.stringify(result.errors)}`). Detail belongs on stdout, which
# observer does not read.
#
# Allowlist, not blocklist. Enumerating the ways of writing "the error" loses
# to the next one invented — String(err), `${err}`, err.toString(), err.cause,
# str(exc), f"{e}" are all the same leak, and String(err) is what
# stack/broker/server.js itself used before this suite existed. So: inside a
# logEvent()/log_event() call, strip the field *names*, strip the two permitted
# references, and flag any mention of the exception variable that survives.
for f in stack/broker/*.js stack/proxy/*.py examples/*/broker/*.js \
         examples/*/.devcontainer/broker/*.js examples/*/proxy/*.py \
         examples/*/.devcontainer/proxy/*.py stack/proxy/addons/*.py; do
  [ -f "$f" ] || continue
  bad=$(awk '
    # Comments are prose (these files explain the anti-pattern in their own).
    { line = $0; sub(/[[:space:]]*(\/\/|#).*$/, "", line) }
    !inside && line ~ /log_?[Ee]vent\(/ { inside = 1; start = NR; buf = ""; depth = 0 }
    inside {
      buf = buf " " line
      n = gsub(/\(/, "(", line); depth += n
      n = gsub(/\)/, ")", line); depth -= n
      if (depth > 0) next
      inside = 0
      t = buf
      # Quoted literals are values, not references — "Error" is fine. Only
      # brace-free ones though: an f-string is a reference wearing a literal
      # and f"{e}" leaks exactly like str(e). Backticks are never stripped, so
      # a template literal interpolating ${err} stays visible too.
      gsub(/"[^"{}]*"/, "", t); gsub(/'"'"'[^'"'"'{}]*'"'"'/, "", t)
      # Field names: `error:` in JS, error= in Python. A key is not a reference.
      gsub(/(err|error|e|ex|exc)[[:space:]]*[:=]/, "", t)
      # The two permitted references.
      gsub(/(err|error|e|ex|exc)\.(code|name)/, "", t)
      # Anything left that names the exception is the violation, whatever the
      # syntax around it.
      if (t ~ /(^|[^[:alnum:]_.])(err|error|e|ex|exc)([^[:alnum:]_]|$)/) print start ": " buf
    }' "$f")
  if [ -z "$bad" ]; then ok "$(basename "$f") — exception referenced safely or not at all"
  else ko "$f — audit event can carry exception text" "$bad"; fi
done

suite "github addon does not match github.com"
# Documented invariant: git push/pull authenticates through the credential
# helper. Matching github.com here collides with git's Basic auth handshake
# inside the MITMed tunnel.
for f in examples/*/proxy/010_github.py examples/*/.devcontainer/proxy/010_github.py; do
  [ -f "$f" ] || continue
  bad=$(grep -nE '"github\.com"|'\''github\.com'\''' "$f" || true)
  if [ -z "$bad" ]; then ok "$f — matches api./uploads. hosts only"
  else ko "$f — matches github.com" "$bad"; fi
done

suite "policy addon loads before provider addons"
# 000_policy.py must run first; entrypoint.sh globs alphabetically.
for d in examples/*/proxy examples/*/.devcontainer/proxy stack/proxy/addons; do
  [ -d "$d" ] || continue
  first=$(ls "$d"/*.py 2>/dev/null | head -1 | xargs -r basename)
  check "$d — first addon is 000_policy.py" "000_policy.py" "$first"
done

suite "examples build from a release tag, not a branch"
# Tracking #main means a rebuild silently picks up whatever landed on main
# since, while the bind-mounted addons stay frozen at whatever was copied —
# the image moves and the security-relevant files do not. That split is
# exactly what the 0.1.0 upgrade notes warn about, so the examples must not
# reproduce it. Bump these when cutting a release.
for c in examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml; do
  refs=$(grep -oE 'secure-agent-lab\.git#[^:]+' "$c" | cut -d'#' -f2 | sort -u)
  if [ -z "$refs" ]; then
    skip "$c — no git-URL builds" ""
  else
    bad=$(printf '%s\n' "$refs" | grep -vE '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [ -z "$bad" ]; then
      ok "$c — builds pinned to $(printf '%s' "$refs" | tr '\n' ' ')"
    else
      ko "$c — build ref is not a release tag" "found: $(printf '%s' "$bad" | tr '\n' ' ')"
    fi
  fi
done

suite "dev mounts land in the container's HOME"
# When examples/claude-code stopped running as root, HOME moved to /home/agent
# but the compose mounts stayed at /root/. Nothing failed loudly: Claude Code
# read $HOME, found an empty directory, and quietly lost its settings and auth
# on every recreate. Derive HOME from the Dockerfile rather than hardcoding it,
# so this keeps working if the user is renamed again.
CC_DOCKERFILE=examples/claude-code/dev/Dockerfile
CC_COMPOSE=examples/claude-code/compose.yaml
if [ -f "$CC_DOCKERFILE" ] && [ -f "$CC_COMPOSE" ]; then
  home=$(grep -oP '^ENV HOME=\K\S+' "$CC_DOCKERFILE" | tail -1)
  if [ -z "$home" ]; then
    skip "claude-code dev HOME" "no ENV HOME in $CC_DOCKERFILE — image uses the base default"
  else
    ok "claude-code dev HOME is $home"
    # Every state mount the agent needs to write must sit under it.
    for m in .claude .claude.json .config; do
      target=$(grep -oE "\./workspace/${m//./\\.}:[^:[:space:]]+" "$CC_COMPOSE" | head -1 | cut -d: -f2)
      if [ -z "$target" ]; then
        skip "workspace/$m is not mounted" ""
      else
        check "workspace/$m mounts under $home" "$home/$m" "$target"
      fi
    done
    check_not_contains "no dev mount targets /root" "$(grep -A20 '^  dev:' "$CC_COMPOSE")" ":/root/"
  fi
fi

suite "audit-logs volume is wired wherever observer/log-rotator are present"
# stack/compose.yaml always has this wiring; examples pick it up one at a
# time as they're repinned (see the audit-helper suite below) — check
# whichever composes actually declare an observer service, rather than a
# fixed list that goes stale as more examples upgrade.
AUDIT_COMPOSES=()
for c in stack/compose.yaml examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml; do
  grep -q '^  observer:' "$c" && AUDIT_COMPOSES+=("$c")
done
for conf in "${AUDIT_COMPOSES[@]}"; do
  check_contains "$conf — audit-logs volume declared" "$(cat "$conf")" $'  audit-logs:'
  for svc in broker proxy cred-gateway; do
    block=$(awk -v s="  $svc:" 'index($0,s)==1{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
    check_contains "$conf — $svc mounts audit-logs at /var/log/audit" "$block" "audit-logs:/var/log/audit"
  done
  for svc in broker proxy; do
    block=$(awk -v s="  $svc:" 'index($0,s)==1{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
    check_contains "$conf — $svc sets AUDIT_LOG" "$block" "AUDIT_LOG:"
  done
done

suite "observer and log-rotator stay off secure/dev"
# Deliberately no `networks:` key for either — see CLAUDE.md. They still land
# on Compose's implicit `default` network, but every other service declares
# an explicit `networks:` list and never joins `default`, so that network
# ends up containing only these two with no route to anything else.
for conf in "${AUDIT_COMPOSES[@]}"; do
  for svc in observer log-rotator; do
    block=$(awk -v s="  $svc:" 'index($0,s)==1{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
    check_not_contains "$conf — $svc has no explicit networks: key" "$block" "networks:"
  done
done

suite "observer's dashboard port is loopback-only"
for conf in "${AUDIT_COMPOSES[@]}"; do
  obs_block=$(awk '/^  observer:/{f=1;next} f&&/^  [a-zA-Z-]+:/{exit} f' "$conf")
  check_contains "$conf — observer port bound to 127.0.0.1" "$obs_block" '"127.0.0.1:9000:9000"'
done

suite "cred-gateway bakes an empty /var/log/audit"
# Unlike AUDIT_LOG (opt-in, no-op if unset), nginx fails to start if a
# configured access_log's directory is missing — this must exist unmounted.
check_contains "cred-gateway Dockerfile creates /var/log/audit" \
  "$(cat stack/cred-gateway/Dockerfile)" "mkdir -p /var/log/audit"

suite "examples only depend on the stack audit helpers when their pin can back it"
# examples/*/broker and examples/*/proxy are bind-mounted into an image built
# from a pinned release tag (see "examples build from a release tag" above).
# audit.js/audit.py were introduced in the stack image at 1.1.0 — an example
# pinned below that would MODULE_NOT_FOUND on require("../audit")/import audit,
# and one pinned at or above it should actually be using the helper, not
# silently missing the audit trail. Derived from each example's own pin
# rather than hardcoded per example, so this keeps working unattended as
# examples upgrade one at a time instead of needing a manual edit here.
AUDIT_MIN="1.1.0"
EXAMPLE_COMPOSES=(examples/claude-code/compose.yaml examples/dev-container/.devcontainer/compose.yaml)
EXAMPLE_DIRS=(examples/claude-code examples/dev-container/.devcontainer)
for i in "${!EXAMPLE_COMPOSES[@]}"; do
  c="${EXAMPLE_COMPOSES[$i]}"
  dir="${EXAMPLE_DIRS[$i]}"
  tag=$(grep -oE 'secure-agent-lab\.git#v[0-9]+\.[0-9]+\.[0-9]+' "$c" | head -1 | sed 's/.*#v//')
  if [ -z "$tag" ]; then skip "$dir — no pinned tag found" ""; continue; fi

  higher=$(printf '%s\n%s\n' "$AUDIT_MIN" "$tag" | sort -V | tail -1)
  if [ "$higher" = "$tag" ]; then
    for f in "$dir"/broker/*.js; do
      [ -f "$f" ] || continue
      check_contains "$f (pinned v$tag) uses the audit helper" "$(cat "$f")" 'require("../audit")'
    done
    for f in "$dir"/proxy/*.py; do
      [ -f "$f" ] || continue
      check_contains "$f (pinned v$tag) uses the audit helper" "$(cat "$f")" "import audit"
    done
  else
    for f in "$dir"/broker/*.js; do
      [ -f "$f" ] || continue
      check_not_contains "$f (pinned v$tag, predates audit.js) does not require it" "$(cat "$f")" 'require("../audit")'
    done
    for f in "$dir"/proxy/*.py; do
      [ -f "$f" ] || continue
      check_not_contains "$f (pinned v$tag, predates audit.py) does not import it" "$(cat "$f")" "import audit"
    done
  fi
done

finish
