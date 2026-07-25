// Shared audit-log writer for provider files. Baked into the image (unlike
// providers/, which is bind-mounted) so every provider gets it via a plain
// relative require, e.g. `require("../audit")` from /app/providers/foo.js.
//
// Emits one JSON line per event to AUDIT_LOG — never a credential value, only
// the shape of what happened (which provider, which route, cache hit/miss).
// A no-op when AUDIT_LOG is unset, so deployments that don't mount the
// audit-logs volume (e.g. the stack/compose.yaml reference skeleton, unless
// wired up) keep working unchanged.
const fs = require("fs");

const AUDIT_LOG = process.env.AUDIT_LOG;

function logEvent(event, fields = {}) {
  if (!AUDIT_LOG) return;
  const line = JSON.stringify({
    // +00:00 and no milliseconds — matches cred-gateway's nginx
    // $time_iso8601 and the proxy's audit.py exactly, rather than
    // toISOString()'s "...ssZ".
    ts: new Date().toISOString().replace(/\.\d+Z$/, "+00:00"),
    service: "broker",
    event,
    ...fields,
  });
  fs.appendFile(AUDIT_LOG, line + "\n", (err) => {
    if (err) console.error("[broker] audit log write failed:", err.message);
  });
}

module.exports = { logEvent };
