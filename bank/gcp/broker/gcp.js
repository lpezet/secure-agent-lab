const fs = require("fs");
const https = require("https");
const { logEvent } = require("../audit");

const SAFETY_WINDOW_MS = 5 * 60 * 1000;

// Which service account this deployment issues for. Deployment configuration,
// never request data — same rule as CLOUDFLARE_PROFILE, for the same reason:
// an agent that picks its own identity makes a ladder of service accounts
// decorative, and the audit line records the escalation as authorised.
const CONFIGURED_SA = process.env.GCP_SERVICE_ACCOUNT || "";

// One SA per deployment, so one entry. Keyed anyway, so the shape does not have
// to change if that ever stops being true.
const tokenCache = new Map();

// Read fresh rather than at load: the ADC file is bind-mounted read-only and a
// human rotating it should not need a broker restart to take effect.
function readAdc() {
  const path = process.env.GCP_ADC_PATH;
  if (!path) throw new Error("GCP_ADC_PATH is not set");
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

function postForm(url, form, headers = {}) {
  const body = new URLSearchParams(form).toString();
  return postRaw(url, body, {
    "Content-Type": "application/x-www-form-urlencoded",
    ...headers,
  });
}

function postJson(url, obj, headers = {}) {
  return postRaw(url, JSON.stringify(obj), {
    "Content-Type": "application/json",
    ...headers,
  });
}

// The broker calls Google directly, not through the proxy — routing through it
// would be circular, since the proxy asks this route for the credential it
// injects.
function postRaw(url, body, headers) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      url,
      {
        method: "POST",
        headers: { ...headers, "Content-Length": Buffer.byteLength(body) },
      },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          let parsed;
          try {
            parsed = JSON.parse(data);
          } catch (e) {
            return reject(new Error(`non-JSON response from ${new URL(url).host}`));
          }
          if (res.statusCode < 200 || res.statusCode >= 300) {
            // The vendor's error body can quote back what was sent. Keep the
            // status, drop the body — PLAYBOOK "What is safe to log".
            return reject(
              new Error(`${new URL(url).host} returned HTTP ${res.statusCode}`),
            );
          }
          resolve(parsed);
        });
      },
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

// The user's refresh token buys a user access token, which is the thing
// entitled to impersonate. This is the step that makes the long-lived secret a
// refresh token rather than a service-account key: revocable, and visible in
// Google's session management.
async function userAccessToken(source) {
  const r = await postForm("https://oauth2.googleapis.com/token", {
    grant_type: "refresh_token",
    client_id: source.client_id,
    client_secret: source.client_secret,
    refresh_token: source.refresh_token,
  });
  if (!r.access_token) throw new Error("no access_token in refresh response");
  return r.access_token;
}

// The service account named by the ADC file, cross-checked against config.
// Taking it from the file alone would let a swapped file change which identity
// the deployment issues without anything saying so.
function targetServiceAccount(adc) {
  const url = adc.service_account_impersonation_url || "";
  const m = url.match(/serviceAccounts\/([^:/]+):generateAccessToken/);
  const fromFile = m ? decodeURIComponent(m[1]) : "";
  if (!fromFile) throw new Error("ADC has no service_account_impersonation_url");
  if (CONFIGURED_SA && fromFile !== CONFIGURED_SA) {
    const err = new Error("configured service account does not match the ADC file");
    err.code = "sa_mismatch";
    err.detail = { configured: CONFIGURED_SA, adc: fromFile };
    throw err;
  }
  return fromFile;
}

async function mintAccessToken() {
  const adc = readAdc();

  // A bare authorized_user IS the human operator, which is the thing this
  // provider exists to avoid handing an agent. Refused here as well as in
  // check-invariants, because a setup mistake should fail at the boundary
  // rather than only in a scan someone has to remember to run. See #42.
  if (adc.type === "authorized_user") {
    const err = new Error("ADC is a bare authorized_user — that is the operator's own identity");
    err.code = "human_principal";
    throw err;
  }
  if (adc.type !== "impersonated_service_account") {
    const err = new Error(`unsupported ADC type: ${adc.type}`);
    err.code = "unsupported_adc_type";
    throw err;
  }

  const sa = targetServiceAccount(adc);
  const cached = tokenCache.get(sa);
  if (cached && new Date(cached.expiresAt) - Date.now() > SAFETY_WINDOW_MS) {
    return cached;
  }

  const source = adc.source_credentials || {};
  if (source.type !== "authorized_user") {
    // The nesting matters: impersonated_service_account wraps the credential
    // entitled to impersonate. A service_account key nested here would put a
    // key back on the broker, which is what this provider avoids.
    const err = new Error(`unsupported source_credentials type: ${source.type}`);
    err.code = "unsupported_source_type";
    throw err;
  }

  const userToken = await userAccessToken(source);
  const scopes = adc.delegates && adc.delegates.length
    ? undefined
    : ["https://www.googleapis.com/auth/cloud-platform"];
  const r = await postJson(
    adc.service_account_impersonation_url,
    {
      scope: scopes,
      lifetime: "3600s",
      delegates: adc.delegates || undefined,
    },
    { Authorization: `Bearer ${userToken}` },
  );
  if (!r.accessToken) throw new Error("no accessToken in impersonation response");

  const entry = {
    token: r.accessToken,
    expiresAt: r.expireTime || new Date(Date.now() + 3600 * 1000).toISOString(),
    serviceAccount: sa,
  };
  tokenCache.set(sa, entry);
  return entry;
}

module.exports = {
  "/gcp/token": async (url, send) => {
    // Same cross-check as cloudflare's `profile`: a param is a consistency
    // check against configuration, never an input that selects authority.
    const requested = url.searchParams.get("service_account");
    if (requested && CONFIGURED_SA && requested !== CONFIGURED_SA) {
      logEvent("request_rejected", {
        provider: "gcp",
        reason: "service_account_mismatch",
        requested,
        configured: CONFIGURED_SA,
      });
      return send(403, { error: "service account not permitted" });
    }

    let t;
    try {
      t = await mintAccessToken();
    } catch (e) {
      // Only .code, never the message — an exception from the vendor path can
      // carry back what was sent to it. inv_exception_quoted enforces this.
      logEvent("token_denied", { provider: "gcp", reason: e.code || "mint_failed" });
      const status = e.code === "human_principal" || e.code === "sa_mismatch" ? 403 : 502;
      return send(status, { error: "could not mint a gcp token" });
    }

    console.log(
      `[broker] issued gcp token sa=${t.serviceAccount} (expires ${t.expiresAt})`,
    );
    // The SA email and expiry describe the authority issued; the token itself
    // never reaches the trail. Same shape as github's permissions/scope line.
    logEvent("token_issued", {
      provider: "gcp",
      service_account: t.serviceAccount,
      expires_at: t.expiresAt,
    });
    send(200, { token: t.token, expiresAt: t.expiresAt });
  },
};
