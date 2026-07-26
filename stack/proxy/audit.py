"""Shared audit-log writer for proxy addons.

Baked into the image at /opt/agent-proxy and put on PYTHONPATH (see
Dockerfile), so any addon in the bind-mounted /addons directory can
`import audit` regardless of which addon file it lives next to.

Emits one JSON line per event to AUDIT_LOG — never a credential value, only
the shape of what happened (which host, which provider, blocked or injected).
A no-op when AUDIT_LOG is unset, so addons that call this keep working in
deployments that haven't wired up the audit-logs volume.
"""
import json
import os
import time

_AUDIT_LOG = os.environ.get("AUDIT_LOG")


def log_event(event: str, **fields) -> None:
    if not _AUDIT_LOG:
        return
    line = json.dumps({
        # +00:00, not a "Z" suffix — matches cred-gateway's nginx
        # $time_iso8601, which has no "Z"-suffixed form.
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
        "service": "proxy",
        "event": event,
        **fields,
    })
    try:
        with open(_AUDIT_LOG, "a") as f:
            f.write(line + "\n")
    except OSError as e:
        print(f"[proxy] audit log write failed: {e}")
