const fs = require("fs");
const { logEvent } = require("../audit");

function getAnthropicKey() {
  return fs.readFileSync(process.env.ANTHROPIC_API_KEY_PATH, "utf8").trim();
}

module.exports = {
  // Reachable only from the proxy on the `secure` network.
  // cred-gateway does not whitelist this path, so dev cannot reach it.
  "/anthropic/key": async (url, send) => {
    // Read before logging, not after: logging first recorded a key_issued for
    // a request that then threw on a missing file, so the trail claimed a
    // credential had been handed out when none was.
    let key;
    try {
      key = getAnthropicKey();
    } catch (err) {
      console.error(
        "[broker] no Anthropic key file at ANTHROPIC_API_KEY_PATH:",
        err.message,
      );
      logEvent("cred_unavailable", { provider: "anthropic" });
      return send(500, { error: "no Anthropic credential configured" });
    }
    console.log("[broker] issued anthropic key to proxy");
    logEvent("key_issued", { provider: "anthropic" });
    send(200, { key });
  },
};
