const fs = require("fs");
const { logEvent } = require("../audit");

function tryReadFile(path) {
  if (!path) return null;
  try {
    return fs.readFileSync(path, "utf8").trim();
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
}

module.exports = {
  // Reachable only from the proxy on the `secure` network.
  // cred-gateway does not whitelist this path, so dev cannot reach it.
  // Returns whichever credential file exists, preferring auth token over API key.
  // type: "auth_token" → inject as Authorization: Bearer <value>
  // type: "api_key"    → inject as x-api-key: <value>
  "/anthropic/cred": async (url, send) => {
    const authToken = tryReadFile(process.env.ANTHROPIC_AUTH_TOKEN_PATH);
    if (authToken) {
      console.log("[broker] issued anthropic auth token to proxy");
      logEvent("cred_issued", { provider: "anthropic", cred_type: "auth_token" });
      return send(200, { type: "auth_token", value: authToken });
    }
    const apiKey = tryReadFile(process.env.ANTHROPIC_API_KEY_PATH);
    if (apiKey) {
      console.log("[broker] issued anthropic api key to proxy");
      logEvent("cred_issued", { provider: "anthropic", cred_type: "api_key" });
      return send(200, { type: "api_key", value: apiKey });
    }
    send(500, { error: "no Anthropic credential configured" });
  },
};
