
## Commands

**Bring up the full stack (from repo root, outside the container):**
```bash
docker compose -f compose.yaml up --build
```

**Smoke test — run inside the lab container after opening in VSCode:**
```bash
./scripts/smoke-test.sh
```

**Logs:**
```bash
docker compose -f compose.yaml logs -f broker proxy cred-gateway
```

**Smoke-test the audit-log/observer plumbing (no real credentials needed):**

`stack/compose.yaml`'s `broker` service needs an `env_file: .env` to exist — with `broker/providers/` empty (reference skeleton, by design) nothing actually reads it, so a couple of placeholders are enough:
```bash
cat > .env <<'EOF'
GITHUB_APP_ID=0
GITHUB_APP_INSTALLATION_ID=0
EOF
docker compose -f compose.yaml up --build -d
```
Open the dashboard from the host — it's loopback-only, not reachable from inside the stack:
```
http://localhost:9000
```
Nothing will show up until something writes an audit line. With no providers or gateway.d snippets mounted, broker itself never gets the chance to call `logEvent`, but cred-gateway and the policy addon do, so these two generate visible rows from inside `lab`:
```bash
# service: cred-gateway, event: request — access_log fires on every path but /healthz,
# even a 403 from the default-deny.
docker compose -f compose.yaml exec lab curl -s http://cred-gateway/anything

# service: proxy, event: blocked — 000_policy.py intercepts a request aimed at broker.
# --proxy is explicit here: curl only honors lowercase http_proxy for plain HTTP URLs,
# not the container's HTTP_PROXY env var, so it would silently skip the proxy otherwise.
docker compose -f compose.yaml exec lab curl -s --proxy http://proxy:8080 http://broker:8080/github/token
```
If the dashboard header is stuck on "connecting…", check `docker compose -f compose.yaml logs observer` and `docker compose -f compose.yaml ps observer` — the SSE connection should flip to "connected" as soon as `/events`' response headers land, independent of whether the backlog has anything in it yet.

**Teardown (removes named volumes including the mitmproxy CA cert and the audit-logs history):**
```bash
docker compose -f compose.yaml down -v
```

**Rebuild and test a single service image:**
```bash
# From repo root (stack/ directory)
docker build -t test-broker broker
docker build -t test-proxy proxy
docker build -t test-cred-gateway cred-gateway
docker build -t test-lab lab
```

**Validate nginx config (config is baked into the image):**
```bash
docker build -t test-cred-gateway cred-gateway
docker run --rm test-cred-gateway nginx -t
```

**Recovery if setup.sh failed mid-run (idempotent, run inside lab container):**
```bash
/workspace/lab/setup.sh
```

**Restart a service after rotating a credential:**
```bash
docker compose -f compose.yaml up -d --force-recreate broker
docker compose -f compose.yaml up -d --force-recreate broker proxy  # for Anthropic key rotation
```

**Restart the proxy after editing the allowlist file:**
```bash
docker compose -f compose.yaml up -d --force-recreate proxy
```

**Force-regenerate the mitmproxy CA cert:**
```bash
docker compose -f compose.yaml down
docker volume rm agent-lab_proxy-certs
docker compose -f compose.yaml up -d
# Then: Dev Containers: Rebuild Container in VSCode
```

**Debug the proxy with a web UI (swap into proxy/Dockerfile CMD temporarily):**
```
mitmweb --web-host 0.0.0.0 --web-port 8081 --listen-host 0.0.0.0 --listen-port 8080 ...
```
And publish port 8081 in compose.yaml.
