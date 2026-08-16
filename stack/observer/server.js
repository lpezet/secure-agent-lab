// Tails the shared audit-logs volume and serves a live view of it. Read-only
// consumer of what broker/proxy/cred-gateway wrote — this process never
// touches /secrets and holds no credentials itself.
//
// Deliberately dependency-free (Node's http + fs only), same as the broker.
const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = 9000;
const AUDIT_DIR = process.env.AUDIT_DIR || "/var/log/audit";
const POLL_MS = 500;
const BACKLOG_MAX = 200;

const offsets = new Map(); // filename -> byte offset already read
const backlog = [];        // ring buffer so a new client sees recent history
const clients = new Set(); // connected SSE response objects

function broadcast(event) {
  backlog.push(event);
  if (backlog.length > BACKLOG_MAX) backlog.shift();
  const data = `data: ${JSON.stringify(event)}\n\n`;
  for (const res of clients) res.write(data);
}

// Only exact `*.jsonl` names — rotated history lands as `name.jsonl-YYYY-MM-DD`
// (see stack/log-rotator) and is deliberately not tailed here.
function isLiveAuditFile(name) {
  return name.endsWith(".jsonl");
}

function pollFile(name) {
  const full = path.join(AUDIT_DIR, name);
  let stat;
  try {
    stat = fs.statSync(full);
  } catch {
    offsets.delete(name);
    return;
  }

  let offset = offsets.get(name) || 0;
  // log-rotator uses copytruncate: the file shrinks in place on rotation
  // rather than being replaced, so a smaller size means "start over".
  if (stat.size < offset) offset = 0;
  if (stat.size === offset) return;

  const length = stat.size - offset;
  const buf = Buffer.alloc(length);
  const fd = fs.openSync(full, "r");
  fs.readSync(fd, buf, 0, length, offset);
  fs.closeSync(fd);
  offsets.set(name, stat.size);

  for (const line of buf.toString("utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      broadcast(JSON.parse(line));
    } catch {
      // A writer emitted something that isn't valid JSON. Surface that fact
      // rather than silently dropping it or crashing the poll loop.
      broadcast({
        ts: new Date().toISOString(),
        service: "observer",
        event: "unparseable_line",
        source: name,
        raw: line.slice(0, 200),
      });
    }
  }
}

function pollAll() {
  let names;
  try {
    names = fs.readdirSync(AUDIT_DIR).filter(isLiveAuditFile);
  } catch {
    return; // volume not mounted yet, or briefly unavailable
  }
  for (const name of names) pollFile(name);
}

setInterval(pollAll, POLL_MS);

const DASHBOARD = fs.readFileSync(path.join(__dirname, "dashboard.html"), "utf8");

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (url.pathname === "/healthz") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ ok: true }));
  }

  if (url.pathname === "/events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    // Node buffers headers until the first write, and an empty backlog writes
    // nothing — so on a deployment that has not logged yet the client gets no
    // response at all, not even headers, and the dashboard sits on
    // "connecting…" forever. "No events" and "not receiving events" are the two
    // states an audit trail exists to distinguish, so send the headers now.
    res.flushHeaders();
    for (const event of backlog) res.write(`data: ${JSON.stringify(event)}\n\n`);
    clients.add(res);
    req.on("close", () => clients.delete(res));
    return;
  }

  if (url.pathname === "/") {
    res.writeHead(200, { "Content-Type": "text/html" });
    return res.end(DASHBOARD);
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "not found" }));
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[observer] listening on :${PORT}`);
  console.log(`[observer] watching ${AUDIT_DIR}`);
});
