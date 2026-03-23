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

function buildResource(serviceName, serviceInstanceId, spans) {
  return {
    resource: {
      attributes: attributesFromObject({
        "service.name": serviceName,
        "service.namespace": "openclaw-o11y",
        "service.instance.id": serviceInstanceId,
        "deployment.environment": env("TRACE_DEPLOYMENT_ENVIRONMENT", "nemolaw"),
        "demo.synthetic": true,
        "demo.runtime": "manual-service-map",
      }),
    },
    scopeSpans: [
      {
        scope: {
          name: "openclaw-o11y-service-map-emitter",
          version: "1.0.0",
        },
        spans,
      },
    ],
  };
}

function buildTracePayload(index) {
  const traceId = randomHex(16);
  const baseEndedAt = nowUnixNano();
  const serviceNames = {
    nemoclaw: env("TRACE_SERVICE_NAME_NEMOCLAW", "nemoclaw"),
    policy: env("TRACE_SERVICE_NAME_POLICY", "nemoclaw-policy"),
    gateway: env("TRACE_SERVICE_NAME_GATEWAY", "openclaw"),
    relay: env("TRACE_SERVICE_NAME_RELAY", "openai-relay"),
  };
  const serviceInstances = {
    nemoclaw: `${serviceNames.nemoclaw}-${index}`,
    policy: `${serviceNames.policy}-${index}`,
    gateway: `${serviceNames.gateway}-${index}`,
    relay: `${serviceNames.relay}-${index}`,
  };
  const spans = {
    root: randomHex(8),
    policyClient: randomHex(8),
    policyServer: randomHex(8),
    gatewayClient: randomHex(8),
    gatewayServer: randomHex(8),
    relayClient: randomHex(8),
    relayServer: randomHex(8),
  };

  const workflowStart = offsetUnixNano(baseEndedAt, -120);
  const policyClientStart = offsetUnixNano(workflowStart, 5);
  const policyServerStart = offsetUnixNano(policyClientStart, 1);
  const policyEnd = offsetUnixNano(policyServerStart, 12);
  const gatewayClientStart = offsetUnixNano(policyEnd, 2);
  const gatewayServerStart = offsetUnixNano(gatewayClientStart, 1);
  const gatewayEnd = offsetUnixNano(gatewayServerStart, 45);
  const relayClientStart = offsetUnixNano(gatewayServerStart, 8);
  const relayServerStart = offsetUnixNano(relayClientStart, 1);
  const relayEnd = offsetUnixNano(relayServerStart, 18);
  const workflowEnd = offsetUnixNano(gatewayEnd, 6);

  return {
    resourceSpans: [
      buildResource(serviceNames.nemoclaw, serviceInstances.nemoclaw, [
        {
          traceId,
          spanId: spans.root,
          name: "nemoclaw.workflow.run",
          kind: 1,
          startTimeUnixNano: workflowStart,
          endTimeUnixNano: workflowEnd,
          attributes: attributesFromObject({
            "demo.sequence": index,
            "workflow.outcome": "success",
          }),
          status: { code: 1 },
        },
        {
          traceId,
          spanId: spans.policyClient,
          parentSpanId: spans.root,
          name: "nemoclaw.policy.check",
          kind: 3,
          startTimeUnixNano: policyClientStart,
          endTimeUnixNano: policyEnd,
          attributes: attributesFromObject({
            "peer.service": serviceNames.policy,
            "server.address": serviceNames.policy,
            "rpc.system": "nemoclaw",
            "rpc.service": "policy",
          }),
          status: { code: 1 },
        },
        {
          traceId,
          spanId: spans.gatewayClient,
          parentSpanId: spans.root,
          name: "nemoclaw.gateway.dispatch",
          kind: 3,
          startTimeUnixNano: gatewayClientStart,
          endTimeUnixNano: gatewayEnd,
          attributes: attributesFromObject({
            "peer.service": serviceNames.gateway,
            "server.address": serviceNames.gateway,
            "http.request.method": "POST",
            "url.path": "/v1/chat/completions",
          }),
          status: { code: 1 },
        },
      ]),
      buildResource(serviceNames.policy, serviceInstances.policy, [
        {
          traceId,
          spanId: spans.policyServer,
          parentSpanId: spans.policyClient,
          name: "policy.evaluate",
          kind: 2,
          startTimeUnixNano: policyServerStart,
          endTimeUnixNano: policyEnd,
          attributes: attributesFromObject({
            "server.address": serviceNames.policy,
            "nemoclaw.policy.name": "sandbox-default",
            "nemoclaw.policy.decision": "allow",
          }),
          status: { code: 1 },
        },
      ]),
      buildResource(serviceNames.gateway, serviceInstances.gateway, [
        {
          traceId,
          spanId: spans.gatewayServer,
          parentSpanId: spans.gatewayClient,
          name: "openclaw.gateway.request",
          kind: 2,
          startTimeUnixNano: gatewayServerStart,
          endTimeUnixNano: gatewayEnd,
          attributes: attributesFromObject({
            "server.address": serviceNames.gateway,
            "http.request.method": "POST",
            "url.path": "/v1/chat/completions",
          }),
          status: { code: 1 },
        },
        {
          traceId,
          spanId: spans.relayClient,
          parentSpanId: spans.gatewayServer,
          name: "openclaw.provider.forward",
          kind: 3,
          startTimeUnixNano: relayClientStart,
          endTimeUnixNano: relayEnd,
          attributes: attributesFromObject({
            "peer.service": serviceNames.relay,
            "server.address": serviceNames.relay,
            "http.request.method": "POST",
            "url.path": "/v1/chat/completions",
          }),
          status: { code: 1 },
        },
      ]),
      buildResource(serviceNames.relay, serviceInstances.relay, [
        {
          traceId,
          spanId: spans.relayServer,
          parentSpanId: spans.relayClient,
          name: "relay.forward.request",
          kind: 2,
          startTimeUnixNano: relayServerStart,
          endTimeUnixNano: relayEnd,
          attributes: attributesFromObject({
            "server.address": serviceNames.relay,
            "upstream.provider": "openai",
          }),
          status: { code: 1 },
        },
      ]),
    ],
  };
}

async function main() {
  const endpoint = env("OTLP_HTTP_ENDPOINT");
  if (!endpoint) {
    throw new Error("Missing OTLP_HTTP_ENDPOINT");
  }

  const traceCount = Math.max(envInt("TRACE_COUNT", 5), 1);
  const targetEndpoint = normalizeTraceEndpoint(endpoint);
  const printOnly = env("TRACE_PRINT_ONLY", "false") === "true";
  const payloads = [];

  for (let i = 1; i <= traceCount; i += 1) {
    const payload = buildTracePayload(i);
    payloads.push(payload);
    if (!printOnly) {
      const response = await postJson(targetEndpoint, payload);
      if (response.statusCode !== 200) {
        throw new Error(
          `OTLP endpoint ${targetEndpoint} returned HTTP ${response.statusCode}: ${response.body}`,
        );
      }
    }
  }

  const services = [
    env("TRACE_SERVICE_NAME_NEMOCLAW", "nemoclaw"),
    env("TRACE_SERVICE_NAME_POLICY", "nemoclaw-policy"),
    env("TRACE_SERVICE_NAME_GATEWAY", "openclaw"),
    env("TRACE_SERVICE_NAME_RELAY", "openai-relay"),
  ];

  if (printOnly) {
    process.stdout.write(
      JSON.stringify(
        {
          otlpEndpoint: targetEndpoint,
          traceCount,
          services,
          deploymentEnvironment: env("TRACE_DEPLOYMENT_ENVIRONMENT", "nemolaw"),
          payloads,
        },
        null,
        2,
      ) + "\n",
    );
    return;
  }

  process.stdout.write(`sent ${traceCount} multi-service trace(s)\n`);
  process.stdout.write(`otlp_endpoint=${targetEndpoint}\n`);
  process.stdout.write(`deployment.environment=${env("TRACE_DEPLOYMENT_ENVIRONMENT", "nemolaw")}\n`);
  process.stdout.write(`services=${services.join(",")}\n`);
}

main().catch((error) => {
  process.stderr.write(
    `${error instanceof Error ? error.stack || error.message : String(error)}\n`,
  );
  process.exit(1);
});
