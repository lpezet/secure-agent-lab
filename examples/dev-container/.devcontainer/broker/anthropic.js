const fs = require("fs");
const { logEvent } = require("../audit");

function getAnthropicKey() {
  return fs.readFileSync(process.env.ANTHROPIC_API_KEY_PATH, "utf8").trim();
}

module.exports = {
  // Reachable only from the proxy on the `secure` network.
  // cred-gateway does not whitelist this path, so dev cannot reach it.
  "/anthropic/key": async (url, send) => {
    console.log("[broker] issued anthropic key to proxy");
    logEvent("key_issued", { provider: "anthropic" });
    send(200, { key: getAnthropicKey() });
  },
};
