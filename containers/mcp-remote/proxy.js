#!/usr/bin/env node
// proxy.js — MCP proxy with OAuth (sidecar for agent-airlock).
//
// Two modes, transparent to the harness:
//   Token exists → inject Bearer, forward requests (zero interaction).
//   No token    → OAuth discovery + PKCE flow → save token → forward.
//
// Usage: node proxy.js <target-url> <token-file> <listen-port> [callback-port]
//   ex : node proxy.js https://mcp.atlassian.com/v1/mcp /home/node/.mcp-auth/jira.token 9000 9910

const http = require("http");
const https = require("https");
const fs = require("fs");
const crypto = require("crypto");
const { URL, URLSearchParams } = require("url");

// ─── CLI args ────────────────────────────────────────────────────────────────
const targetUrl = process.argv[2];
const tokenFile = process.argv[3];
const listenPort = parseInt(process.argv[4], 10);
const callbackPort = parseInt(process.argv[5], 10) || 0;

if (!targetUrl || !tokenFile || !listenPort) {
  console.error("Usage: node proxy.js <target-url> <token-file> <listen-port> [callback-port]");
  process.exit(1);
}

const target = new URL(targetUrl);
const isTls = target.protocol === "https:";
const targetOpts = {
  hostname: target.hostname,
  port: target.port || (isTls ? 443 : 80),
};
const NAME = tokenFile.split("/").pop().replace(/\.token$/, "");

function log(msg) {
  console.error(`[proxy:${NAME}] ${msg}`);
}

// ─── Token helpers ───────────────────────────────────────────────────────────
function readToken() {
  try {
    const t = fs.readFileSync(tokenFile, "utf8").trim();
    if (t) return t;
  } catch (_) { /* not found */ }
  return null;
}

function saveToken(t) {
  const dir = require("path").dirname(tokenFile);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(tokenFile, t, { mode: 0o644 });
  log("token saved");
}

// ─── OAuth helpers ───────────────────────────────────────────────────────────
function base64url(buf) {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function sha256(str) {
  return crypto.createHash("sha256").update(str).digest();
}

function randomHex(len) {
  return crypto.randomBytes(len).toString("hex");
}

function httpsRequest(opts, body) {
  return new Promise((resolve, reject) => {
    const transport = opts.protocol === "https:" ? https : http;
    const req = transport.request(opts, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: data }));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

// ─── OAuth discovery ─────────────────────────────────────────────────────────
// Sends an MCP initialize request. If the server wants OAuth, it responds
// with HTTP 401 + WWW-Authenticate containing the authorization URL.
async function discoverOAuth() {
  log("probing server for OAuth metadata…");
  const initReq = JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "airlock-proxy", version: "1.0" } },
  });

  let res;
  try {
    res = await httpsRequest({
      protocol: target.protocol,
      hostname: targetOpts.hostname,
      port: targetOpts.port,
      path: target.pathname,
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
    }, initReq);
  } catch (e) {
    log(`OAuth discovery failed: ${e.message}`);
    return null;
  }

  // Check for WWW-Authenticate header (RFC 6750 / MCP spec).
  const authHeader = res.headers["www-authenticate"];
  if (!authHeader) {
    log(`server returned ${res.status}, no WWW-Authenticate header — OAuth not supported`);
    return null;
  }

  // Parse: Bearer authorization_url="https://...", token_url="https://...", ...
  const authUrlMatch = authHeader.match(/authorization_url="([^"]+)"/);
  const tokenUrlMatch = authHeader.match(/token_url="([^"]+)"/);
  const resourceMatch = authHeader.match(/resource="([^"]+)"/);

  if (!authUrlMatch) {
    log(`WWW-Authenticate present but no authorization_url — unsupported format: ${authHeader}`);
    return null;
  }

  const result = {
    authorizationUrl: authUrlMatch[1],
    tokenUrl: tokenUrlMatch ? tokenUrlMatch[1] : authUrlMatch[1].replace(/\/authorize.*$/, "/token"),
  };
  if (resourceMatch) result.resource = resourceMatch[1];
  log(`OAuth discovered: auth=${result.authorizationUrl} token=${result.tokenUrl}`);
  return result;
}

// ─── OAuth PKCE flow ─────────────────────────────────────────────────────────
async function oauthFlow(oauthMeta) {
  if (!callbackPort || callbackPort === 0) {
    log("no callback port configured — OAuth impossible (add CALLBACK_PORT to servers.d/<name>.env)");
    return null;
  }

  const redirectUri = `http://localhost:${callbackPort}/callback`;
  const codeVerifier = base64url(crypto.randomBytes(32));
  const codeChallenge = base64url(sha256(codeVerifier));
  const state = randomHex(16);

  const authParams = new URLSearchParams({
    response_type: "code",
    client_id: process.env.OAUTH_CLIENT_ID || "airlock-mcp-proxy",
    redirect_uri: redirectUri,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
    state,
  });

  // Add scope if configured or discovered.
  const scope = process.env.OAUTH_SCOPE || "";
  if (scope) authParams.set("scope", scope);

  const authUrl = `${oauthMeta.authorizationUrl}?${authParams.toString()}`;

  // Start callback server BEFORE printing URL (avoid race).
  const code = await new Promise((resolve, reject) => {
    const srv = http.createServer((req, res) => {
      const u = new URL(req.url, `http://localhost:${callbackPort}`);
      if (u.pathname !== "/callback") {
        res.writeHead(404);
        return res.end("not found");
      }
      const gotState = u.searchParams.get("state");
      const gotCode = u.searchParams.get("code");
      const gotError = u.searchParams.get("error");

      if (gotState !== state) {
        res.writeHead(400, { "content-type": "text/plain" });
        res.end("state mismatch — possible CSRF attack");
        return;
      }
      if (gotError) {
        res.writeHead(200, { "content-type": "text/html" });
        res.end(`<h1>Authorization failed</h1><p>${gotError}</p>`);
        reject(new Error(`OAuth error: ${gotError}`));
        return;
      }
      if (!gotCode) {
        res.writeHead(400, { "content-type": "text/plain" });
        res.end("missing authorization code");
        return;
      }

      res.writeHead(200, { "content-type": "text/html" });
      res.end("<h1>Authorization complete</h1><p>You can close this tab.</p>");
      srv.close();
      resolve(gotCode);
    });

    srv.on("error", (e) => reject(new Error(`callback server: ${e.message}`)));
    srv.listen(callbackPort, "0.0.0.0", () => {
      log("──────────────────────────────────────────");
      log("OAUTH REQUIRED — open this URL in your browser:");
      log("");
      log(`  ${authUrl}`);
      log("");
      log("──────────────────────────────────────────");
      log(`waiting for callback on port ${callbackPort}…`);
    });

    // Timeout after 2 minutes.
    setTimeout(() => {
      srv.close();
      reject(new Error("OAuth timed out (2 min)"));
    }, 120_000);
  });

  log("callback received, exchanging code for token…");

  // Exchange code for token.
  const tokenParams = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri,
    client_id: process.env.OAUTH_CLIENT_ID || "airlock-mcp-proxy",
    code_verifier: codeVerifier,
  });

  let tokenRes;
  try {
    const tokenUrl = new URL(oauthMeta.tokenUrl);
    tokenRes = await httpsRequest({
      protocol: tokenUrl.protocol,
      hostname: tokenUrl.hostname,
      port: tokenUrl.port || (tokenUrl.protocol === "https:" ? 443 : 80),
      path: tokenUrl.pathname + tokenUrl.search,
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
    }, tokenParams.toString());
  } catch (e) {
    log(`token exchange failed: ${e.message}`);
    return null;
  }

  if (tokenRes.status !== 200) {
    log(`token endpoint returned ${tokenRes.status}: ${tokenRes.body.slice(0, 200)}`);
    return null;
  }

  let tokenData;
  try {
    tokenData = JSON.parse(tokenRes.body);
  } catch (_) {
    log(`token endpoint returned non-JSON: ${tokenRes.body.slice(0, 100)}`);
    return null;
  }

  const accessToken = tokenData.access_token;
  if (!accessToken) {
    log("token response missing access_token");
    return null;
  }

  return accessToken;
}

// ─── HTTP proxy ──────────────────────────────────────────────────────────────
const STRIP_REQ = new Set(["host", "authorization", "proxy-authorization"]);

function cleanReqHeaders(h) {
  const out = {};
  for (const [k, v] of Object.entries(h)) {
    if (!STRIP_REQ.has(k.toLowerCase())) out[k] = v;
  }
  return out;
}

function startProxy(token) {
  const server = http.createServer((clientReq, clientRes) => {
    const opts = {
      ...targetOpts,
      path: target.pathname + target.search,
      method: clientReq.method,
      headers: {
        ...cleanReqHeaders(clientReq.headers),
        host: targetOpts.hostname,
        authorization: `Bearer ${token}`,
      },
    };

    const transport = isTls ? https : http;
    const proxyReq = transport.request(opts, (proxyRes) => {
      clientRes.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(clientRes);
    });

    proxyReq.on("error", (err) => {
      log(`upstream error: ${err.message}`);
      if (!clientRes.headersSent) {
        clientRes.writeHead(502, { "content-type": "text/plain" });
      }
      clientRes.end(`proxy error: ${err.message}`);
    });

    clientReq.pipe(proxyReq);
  });

  server.on("error", (err) => {
    log(`server error: ${err.message}`);
    process.exit(1);
  });

  server.listen(listenPort, "0.0.0.0", () => {
    log(`ready — ${targetUrl} → 0.0.0.0:${listenPort}`);
  });
}

// ─── Main ────────────────────────────────────────────────────────────────────
async function main() {
  let token = readToken();

  if (!token) {
    log("no token — starting OAuth flow");

    const oauthMeta = await discoverOAuth();
    if (oauthMeta) {
      token = await oauthFlow(oauthMeta);
      if (token) {
        saveToken(token);
      }
    }

    // If still no token (discovery failed, OAuth failed, or timed out),
    // poll for a manually imported token.
    if (!token) {
      log("Automatic OAuth not available for this server.");
      log("To connect:");
      log("  1. Login on your host: pi -> /mcp:auth <name> -> open URL -> authorize");
      log(`  2. Import: agent-import-auth.sh --profile pi --mcp ${NAME}`);
      log("(polling every 5s for the token file — no restart needed)");
      token = await new Promise((resolve) => {
        const iv = setInterval(() => {
          const t = readToken();
          if (t) { clearInterval(iv); log("token detected, starting proxy…"); resolve(t); }
        }, 5000);
      });
    }
  }

  startProxy(token);
}

main().catch((err) => {
  log(`fatal: ${err.message}`);
  process.exit(1);
});
