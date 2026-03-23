#!/usr/bin/env node

const crypto = require("crypto");
const http = require("http");
const https = require("https");

function env(name, fallback = "") {
  return process.env[name] || fallback;
}

function envInt(name, fallback) {
  const raw = env(name, "");
  if (raw === "") {
    return fallback;
  }
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value)) {
    throw new Error(`Invalid integer for ${name}: ${raw}`);
  }
  return value;
}

function randomHex(bytes) {
  return crypto.randomBytes(bytes).toString("hex");
}

function nowUnixNano() {
  return (BigInt(Date.now()) * 1000000n).toString();
}

function offsetUnixNano(base, deltaMillis) {
  return (BigInt(base) + BigInt(Math.round(deltaMillis * 1000000))).toString();
}

function toAnyValue(value) {
  if (typeof value === "boolean") {
    return { boolValue: value };
  }
  if (typeof value === "number") {
    if (Number.isInteger(value)) {
      return { intValue: String(value) };
    }
    return { doubleValue: value };
  }
  return { stringValue: String(value) };
}

function attributesFromObject(values) {
  return Object.entries(values)
    .filter(([, value]) => value !== undefined && value !== null && value !== "")
    .map(([key, value]) => ({
      key,
      value: toAnyValue(value),
    }));
}

async function postJson(urlString, payload) {
  const url = new URL(urlString);
  const client = url.protocol === "https:" ? https : http;
  const body = JSON.stringify(payload);

  return new Promise((resolve, reject) => {
    const request = client.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (url.protocol === "https:" ? 443 : 80),
        path: `${url.pathname}${url.search}`,
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
        },
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          resolve({
            statusCode: response.statusCode || 0,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );

    request.on("error", reject);
    request.write(body);
    request.end();
  });
}

function normalizeTraceEndpoint(endpoint) {
  const trimmed = endpoint.replace(/\/+$/, "");
  if (trimmed.endsWith("/v1/traces")) {
    return trimmed;
  }
  return `${trimmed}/v1/traces`;
}

function buildTracePayload(index) {
  const traceId = randomHex(16);
  const spanId = randomHex(8);
  const endedAt = nowUnixNano();
  const durationMs = Math.max(envInt("TRACE_DURATION_MS", 25), 1);
  const startedAt = offsetUnixNano(endedAt, -durationMs);
  const serviceName = env("TRACE_SERVICE_NAME", "openclaw-manual");
  const spanNameBase = env("TRACE_SPAN_NAME", "openclaw.manual.test");
  const spanName =
    envInt("TRACE_COUNT", 1) > 1 ? `${spanNameBase}.${index}` : spanNameBase;

  return {
    resourceSpans: [
      {
        resource: {
          attributes: attributesFromObject({
            "service.name": serviceName,
            "service.namespace": "openclaw-o11y",
            "deployment.environment": env(
              "TRACE_DEPLOYMENT_ENVIRONMENT",
              "nemolaw",
            ),
            "demo.synthetic": true,
            "demo.runtime": "manual-local",
            "service.instance.id": env("TRACE_INSTANCE_ID", `manual-${process.pid}`),
          }),
        },
        scopeSpans: [
          {
            scope: {
              name: "openclaw-o11y-local-emitter",
              version: "1.0.0",
            },
            spans: [
              {
                traceId,
                spanId,
                name: spanName,
                kind: 1,
                startTimeUnixNano: startedAt,
                endTimeUnixNano: endedAt,
                attributes: attributesFromObject({
                  "demo.source": "scripts/local/emit-test-trace.js",
                  "demo.sequence": index,
                  "workflow.outcome": "success",
                }),
              },
            ],
          },
        ],
      },
    ],
  };
}

async function main() {
  const endpoint = env("OTLP_HTTP_ENDPOINT");
  if (!endpoint) {
    throw new Error("Missing OTLP_HTTP_ENDPOINT");
  }

  const traceCount = Math.max(envInt("TRACE_COUNT", 1), 1);
  const targetEndpoint = normalizeTraceEndpoint(endpoint);
  let sent = 0;

  for (let i = 1; i <= traceCount; i += 1) {
    const response = await postJson(targetEndpoint, buildTracePayload(i));
    if (response.statusCode !== 200) {
      throw new Error(
        `OTLP endpoint ${targetEndpoint} returned HTTP ${response.statusCode}: ${response.body}`,
      );
    }
    sent += 1;
  }

  process.stdout.write(`sent ${sent} synthetic trace(s)\n`);
  process.stdout.write(`otlp_endpoint=${targetEndpoint}\n`);
  process.stdout.write(`service.name=${env("TRACE_SERVICE_NAME", "openclaw-manual")}\n`);
  process.stdout.write(
    `deployment.environment=${env("TRACE_DEPLOYMENT_ENVIRONMENT", "nemolaw")}\n`,
  );
}

main().catch((error) => {
  process.stderr.write(
    `${error instanceof Error ? error.stack || error.message : String(error)}\n`,
  );
  process.exit(1);
});
