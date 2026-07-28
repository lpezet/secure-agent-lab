const http = require("http");
const fs = require("fs");
const path = require("path");
const { logEvent } = require("./audit");

const PORT = 8080;
const PROVIDERS_DIR = process.env.PROVIDERS_DIR || path.join(__dirname, "providers");

// Load providers in sorted order (numeric prefix controls load order)
const providerFiles = fs
  .readdirSync(PROVIDERS_DIR)
  .filter((f) => f.endsWith(".js"))
  .sort();

const routes = {};
for (const file of providerFiles) {
  Object.assign(routes, require(path.join(PROVIDERS_DIR, file)));
}

const server = http.createServer(async (req, res) => {
  const send = (status, obj, contentType = "application/json") => {
    res.writeHead(status, { "Content-Type": contentType });
    res.end(typeof obj === "string" ? obj : JSON.stringify(obj));
  };

  // Outside the try so the catch can still name the route when URL parsing is
  // what threw. Pathname only, never the query string — that can carry a
  // credential (PLAYBOOK, "What is safe to log").
  let route = "?";

  try {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    route = url.pathname;

    if (url.pathname === "/healthz") return send(200, { ok: true });

    const handler = routes[url.pathname];
    if (!handler) {
      logEvent("route_not_found", { route });
      return send(404, { error: "not found" });
    }

    await handler(url, send);
  } catch (err) {
    console.error("[broker] error:", err);
    // err.name, not err.message: the message is provider-supplied free text and
    // may quote a credential. Full detail still goes to stdout above.
    logEvent("request_failed", { route, error: err.name || "Error" });
    send(500, { error: String(err.message || err) });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[broker] listening on :${PORT}`);
  console.log(`[broker] GITHUB_APP_ID=${process.env.GITHUB_APP_ID || "(not set)"}`);
  console.log(`[broker] GITHUB_APP_INSTALLATION_ID=${process.env.GITHUB_APP_INSTALLATION_ID || "(not set)"}`);
  console.log(`[broker] GITHUB_APP_PRIVATE_KEY_PATH=${process.env.GITHUB_APP_PRIVATE_KEY_PATH || "(not set)"}`);
  console.log(`[broker] providers loaded: ${providerFiles.join(", ")}`);
});
