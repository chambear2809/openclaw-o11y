#!/usr/bin/env node

const http = require("http");
const { URL } = require("url");

const relayPort = Number(process.env.LOCAL_OPENAI_RELAY_PORT || "8787");
const upstreamBase = process.env.LOCAL_OPENAI_RELAY_UPSTREAM || "https://api.openai.com";
const defaultApiKey = process.env.OPENAI_API_KEY || "";

const hopByHopHeaders = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "host",
  "content-length",
]);

function collectBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function filterHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers)) {
    if (value == null) continue;
    if (hopByHopHeaders.has(name.toLowerCase())) continue;
    out[name] = value;
  }
  return out;
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.url === "/healthz") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, upstreamBase }));
      return;
    }

    const upstreamUrl = new URL(req.url || "/", upstreamBase);
    const body = await collectBody(req);
    const headers = filterHeaders(req.headers);

    if (!headers.authorization && defaultApiKey) {
      headers.authorization = `Bearer ${defaultApiKey}`;
    }

    const upstreamResponse = await fetch(upstreamUrl, {
      method: req.method,
      headers,
      body: body.length > 0 ? body : undefined,
      duplex: body.length > 0 ? "half" : undefined,
    });

    const responseHeaders = filterHeaders(Object.fromEntries(upstreamResponse.headers.entries()));
    res.writeHead(upstreamResponse.status, responseHeaders);
    const upstreamBody = Buffer.from(await upstreamResponse.arrayBuffer());
    res.end(upstreamBody);
  } catch (error) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        error: "relay_request_failed",
        message: error instanceof Error ? error.message : String(error),
      })
    );
  }
});

server.listen(relayPort, "0.0.0.0", () => {
  process.stdout.write(`openai relay listening on 0.0.0.0:${relayPort}\n`);
});
