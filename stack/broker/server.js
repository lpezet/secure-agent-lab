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

// Null-prototype so a lookup can only ever find a route a provider actually
// registered. Route keys start with "/", which is what keeps `constructor` and
// `__proto__` out of reach today — this stops that safety resting on a naming
// convention, given providers/ is bind-mounted and written per deployment.
const routes = Object.create(null);
for (const file of providerFiles) {
  Object.assign(routes, require(path.join(PROVIDERS_DIR, file)));
}

// The namespaces this server defines, e.g. "github" from "/github/token".
// A 404 event names one of these or says nothing — see the 404 branch below.
const ROUTE_NAMESPACES = new Set(
  Object.keys(routes)
    .map((r) => r.split("/")[1])
    .filter(Boolean),
);

const server = http.createServer(async (req, res) => {
  const send = (status, obj, contentType = "application/json") => {
    res.writeHead(status, { "Content-Type": contentType });
    res.end(typeof obj === "string" ? obj : JSON.stringify(obj));
  };

  // Outside the try so the catch can still name the route when URL parsing is
  // what threw, and only ever assigned from a key of our own route table —
  // never from the request. See the 404 branch for why that distinction is
  // the whole point.
  let route = "?";

  try {
    const url = new URL(req.url, `http://localhost:${PORT}`);

    if (url.pathname === "/healthz") return send(200, { ok: true });

    const handler = routes[url.pathname];
    if (!handler) {
      // The unmatched path is caller-supplied, so it never reaches the trail:
      // a provider that carries its credential in the URL (Telegram's
      // /bot<TOKEN>/<method>) would write a live secret into a file observer
      // serves over HTTP. Truncating to n segments cannot help — the secret is
      // as likely to be in the first segment as any other. Matching against
      // the namespaces we defined ourselves can, and still answers the
      // question a 404 usually raises: which provider was this aimed at?
      const ns = url.pathname.split("/")[1];
      console.error(`[broker] no route for ${url.pathname}`);
      logEvent("route_not_found", ROUTE_NAMESPACES.has(ns) ? { namespace: ns } : {});
      return send(404, { error: "not found" });
    }

    route = url.pathname;
    await handler(url, send);
  } catch (err) {
    console.error("[broker] error:", err);
    // err.code, then err.name — both are symbolic constants this codebase or
    // node defines (ENOENT, ECONNREFUSED, TypeError). Never err.message: it is
    // provider-supplied free text and may quote a credential, e.g.
    // cloudflare.js interpolating an API error body. Full detail goes to
    // stdout above, which is not the volume observer serves.
    logEvent("request_failed", { route, error: err.code || err.name || "Error" });
    // Generic, for the same reason: err.message on a missing credential file is
    // `ENOENT ... open '/secrets/anthropic.key'`, which hands the caller the
    // /secrets layout. The useful part is already in the trail and on stdout.
    send(500, { error: "internal error" });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[broker] listening on :${PORT}`);
  console.log(`[broker] GITHUB_APP_ID=${process.env.GITHUB_APP_ID || "(not set)"}`);
  console.log(`[broker] GITHUB_APP_INSTALLATION_ID=${process.env.GITHUB_APP_INSTALLATION_ID || "(not set)"}`);
  console.log(`[broker] GITHUB_APP_PRIVATE_KEY_PATH=${process.env.GITHUB_APP_PRIVATE_KEY_PATH || "(not set)"}`);
  console.log(`[broker] providers loaded: ${providerFiles.join(", ")}`);
});
