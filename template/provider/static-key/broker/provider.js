// TODO: rename every `provider` in this directory — including the filenames —
// to your provider's name, then work through the TODOs.
//
// Broker side of the static-key shape: hold the long-lived secret, hand it to
// the proxy, and never to the lab. Reachable only from the proxy on the
// `secure` network — cred-gateway does not whitelist this path, which is what
// `"exposed": false` in provider.json declares.
const fs = require("fs");
const { logEvent } = require("../audit");

// Returns the file's contents, or null — never "". An empty credential file is
// absent as far as callers are concerned, and collapsing it here keeps that
// true for a caller that tests `!== null` rather than truthiness.
function tryReadFile(path) {
  if (!path) return null;
  try {
    const value = fs.readFileSync(path, "utf8").trim();
    return value || null;
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
}

module.exports = {
  // Read fresh on every call rather than cached: it is a local file read, and
  // it means rotating the credential needs no broker restart.
  //
  // The env var is the one provider.json declares under `secrets[].env`, and
  // its value is a path INSIDE the container. Never read a credential from
  // anywhere else — a path that came from a request is a path the lab chose.
  "/provider/cred": async (url, send) => {
    const token = tryReadFile(process.env.PROVIDER_TOKEN_PATH);
    if (!token) {
      console.error("[broker] no credential file at PROVIDER_TOKEN_PATH");
      logEvent("cred_unavailable", { provider: "provider" });
      return send(500, { error: "no provider credential configured" });
    }

    // The event records the SHAPE of what happened. Never the value, and
    // never anything derived from it: observer serves this trail over HTTP.
    console.log("[broker] issued provider credential to proxy");
    logEvent("cred_issued", { provider: "provider", cred_type: "static_key" });
    send(200, { type: "static_key", value: token });
  },
};
