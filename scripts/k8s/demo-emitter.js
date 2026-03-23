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

function envFloat(name, fallback) {
  const raw = env(name, "");
  if (raw === "") {
    return fallback;
  }
  const value = Number.parseFloat(raw);
  if (!Number.isFinite(value)) {
    throw new Error(`Invalid float for ${name}: ${raw}`);
  }
  return value;
}

function envBool(name, fallback = false) {
  const raw = env(name, "");
  if (raw === "") {
    return fallback;
  }
  return raw === "true";
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

function randomHex(bytes) {
  return crypto.randomBytes(bytes).toString("hex");
}

function nowUnixNano() {
  return (BigInt(Date.now()) * 1000000n).toString();
}

function offsetUnixNano(base, deltaMillis) {
  return (BigInt(base) + BigInt(Math.round(deltaMillis * 1000000))).toString();
}

async function httpRequest(urlString, options = {}) {
  const url = new URL(urlString);
  const client = url.protocol === "https:" ? https : http;
  const body = options.body || "";
  const headers = {
    ...options.headers,
  };

  if (body && headers["content-type"] === "application/json") {
    headers["content-length"] = Buffer.byteLength(body);
  }

  return new Promise((resolve, reject) => {
    const request = client.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (url.protocol === "https:" ? 443 : 80),
        path: `${url.pathname}${url.search}`,
        method: options.method || "GET",
        headers,
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

    if (body) {
      request.write(body);
    }

    request.end();
  });
}

async function gatewayRequest({ token, port }) {
  const validToken = env("DEMO_GATEWAY_TOKEN", env("OPENCLAW_GATEWAY_TOKEN", ""));
  const url = new URL(`http://127.0.0.1:${port}/__openclaw__/canvas/`);
  const startedAt = Date.now();
  try {
    const response = await httpRequest(url.toString(), {
      method: "GET",
      headers: token
        ? {
            Authorization: `Bearer ${token}`,
          }
        : {},
    });
    return {
      statusCode: response.statusCode,
      latencyMs: Date.now() - startedAt,
      tokenMode: token === validToken ? "valid" : "invalid",
      error: "",
    };
  } catch (error) {
    return {
      statusCode: 0,
      latencyMs: Date.now() - startedAt,
      tokenMode: token === validToken ? "valid" : "invalid",
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function driveGatewayTraffic() {
  const mode = env("DEMO_GATEWAY_MODE", "none");
  const validToken = env("DEMO_GATEWAY_TOKEN", env("OPENCLAW_GATEWAY_TOKEN", ""));
  const invalidToken = env("DEMO_INVALID_GATEWAY_TOKEN", "denied-demo-token");
  const port = envInt("DEMO_GATEWAY_PORT", 18789);
  const requestCount = Math.max(envInt("DEMO_REQUEST_COUNT", 1), 1);
  const results = [];

  if (mode === "none") {
    return results;
  }

  if (mode === "valid") {
    for (let i = 0; i < requestCount; i += 1) {
      results.push(await gatewayRequest({ token: validToken, port }));
    }
    return results;
  }

  if (mode === "invalid") {
    for (let i = 0; i < requestCount; i += 1) {
      results.push(await gatewayRequest({ token: invalidToken, port }));
    }
    return results;
  }

  if (mode === "mixed") {
    results.push(await gatewayRequest({ token: validToken, port }));
    for (let i = 1; i < Math.max(requestCount, 2); i += 1) {
      results.push(await gatewayRequest({ token: invalidToken, port }));
    }
    return results;
  }

  throw new Error(`Unsupported DEMO_GATEWAY_MODE: ${mode}`);
}

function summarizeGatewayResults(results) {
  const requestTotal = results.length;
  const errorCount = results.filter(
    (result) => result.statusCode === 0 || result.statusCode >= 400,
  ).length;
  const avgLatencyMs =
    requestTotal === 0
      ? 0
      : Math.round(
          results.reduce((total, result) => total + result.latencyMs, 0) /
            requestTotal,
        );
  const statusSummary = {};

  for (const result of results) {
    const key = String(result.statusCode);
    statusSummary[key] = (statusSummary[key] || 0) + 1;
  }

  return {
    requestTotal,
    errorCount,
    avgLatencyMs,
    statusSummary: Object.entries(statusSummary)
      .map(([statusCode, count]) => `${statusCode}:${count}`)
      .join(","),
  };
}

function buildResourceAttributes() {
  return attributesFromObject({
    "service.name": env("DEMO_SERVICE_NAME", "openshell-demo-control-plane"),
    "service.namespace": "openclaw-o11y",
    "deployment.environment": env(
      "DEMO_DEPLOYMENT_ENVIRONMENT",
      "Openclaw",
    ),
    "k8s.namespace.name": env("DEMO_NAMESPACE", "openclaw"),
    "k8s.cluster.name": env("DEMO_CLUSTER_NAME", "openclaw-lab"),
    "demo.synthetic": true,
  });
}

function buildScenarioAttributes(summary) {
  return {
    "demo.scenario": env("DEMO_SCENARIO", "normal"),
    "workflow.outcome": env("DEMO_WORKFLOW_OUTCOME", "success"),
    "openshell.policy.decision": env("DEMO_POLICY_DECISION", "allow"),
    "openshell.policy.name": env("DEMO_POLICY_NAME", "default"),
    "http.request.method": env("DEMO_HTTP_METHOD", "GET"),
    "server.address": env("DEMO_TARGET_HOST", "127.0.0.1"),
    "url.path": env("DEMO_TARGET_PATH", "/"),
    "agent.action.count": envInt("DEMO_ACTION_COUNT", 1),
    "security.suspicion_score": envFloat("DEMO_SUSPICION_SCORE", 0),
    "gateway.request_total": summary.requestTotal,
    "gateway.error_count": summary.errorCount,
    "gateway.avg_latency_ms": summary.avgLatencyMs,
    "gateway.status_summary": summary.statusSummary,
  };
}

function buildTracePayload(summary, traceId, spanIds, endedAtNano) {
  const scenarioAttributes = buildScenarioAttributes(summary);
  const durationMs = Math.max(summary.avgLatencyMs, 1);
  const rootStartNano = offsetUnixNano(endedAtNano, -(durationMs + 25));
  const policyStartNano = offsetUnixNano(rootStartNano, 5);
  const policyEndNano = offsetUnixNano(policyStartNano, 8);
  const gatewayStartNano = offsetUnixNano(policyEndNano, 2);
  const gatewayEndNano = offsetUnixNano(
    gatewayStartNano,
    Math.max(durationMs, 1),
  );
  const securityStartNano = offsetUnixNano(gatewayEndNano, 1);
  const securityEndNano = offsetUnixNano(securityStartNano, 6);
  const statusCode =
    env("DEMO_WORKFLOW_OUTCOME", "success") === "success" ? 1 : 2;
  const internalSpanKind = 1;

  const spans = [
    {
      traceId,
      spanId: spanIds.root,
      name: "nemoclaw.workflow.run",
      kind: internalSpanKind,
      startTimeUnixNano: rootStartNano,
      endTimeUnixNano: offsetUnixNano(securityEndNano, 1),
      attributes: attributesFromObject({
        ...scenarioAttributes,
        "telemetry.phase": "root",
      }),
      events: [
        {
          timeUnixNano: policyEndNano,
          name: "policy.decision",
          attributes: attributesFromObject({
            "openshell.policy.decision": env("DEMO_POLICY_DECISION", "allow"),
            "openshell.policy.name": env("DEMO_POLICY_NAME", "default"),
          }),
        },
        {
          timeUnixNano: gatewayEndNano,
          name: "gateway.summary",
          attributes: attributesFromObject({
            "gateway.request_total": summary.requestTotal,
            "gateway.error_count": summary.errorCount,
            "gateway.status_summary": summary.statusSummary,
          }),
        },
      ],
      status: {
        code: statusCode,
        message: env("DEMO_SUMMARY_MESSAGE", "demo scenario"),
      },
    },
    {
      traceId,
      spanId: spanIds.policy,
      parentSpanId: spanIds.root,
      name: "openshell.policy.evaluate",
      kind: internalSpanKind,
      startTimeUnixNano: policyStartNano,
      endTimeUnixNano: policyEndNano,
      attributes: attributesFromObject({
        "openshell.policy.decision": env("DEMO_POLICY_DECISION", "allow"),
        "openshell.policy.name": env("DEMO_POLICY_NAME", "default"),
        "http.request.method": env("DEMO_HTTP_METHOD", "GET"),
        "server.address": env("DEMO_TARGET_HOST", "127.0.0.1"),
        "url.path": env("DEMO_TARGET_PATH", "/"),
      }),
      status: {
        code: env("DEMO_POLICY_DECISION", "allow") === "deny" ? 2 : 1,
      },
    },
    {
      traceId,
      spanId: spanIds.gateway,
      parentSpanId: spanIds.root,
      name: "openclaw.gateway.exercise",
      kind: internalSpanKind,
      startTimeUnixNano: gatewayStartNano,
      endTimeUnixNano: gatewayEndNano,
      attributes: attributesFromObject({
        "gateway.mode": env("DEMO_GATEWAY_MODE", "none"),
        "gateway.request_total": summary.requestTotal,
        "gateway.error_count": summary.errorCount,
        "gateway.avg_latency_ms": summary.avgLatencyMs,
        "gateway.status_summary": summary.statusSummary,
      }),
      status: {
        code: summary.errorCount > 0 ? 2 : 1,
      },
    },
    {
      traceId,
      spanId: spanIds.security,
      parentSpanId: spanIds.root,
      name: "security.agent_assessment",
      kind: internalSpanKind,
      startTimeUnixNano: securityStartNano,
      endTimeUnixNano: securityEndNano,
      attributes: attributesFromObject({
        "workflow.outcome": env("DEMO_WORKFLOW_OUTCOME", "success"),
        "security.suspicion_score": envFloat("DEMO_SUSPICION_SCORE", 0),
        "agent.action.count": envInt("DEMO_ACTION_COUNT", 1),
      }),
      status: {
        code: statusCode,
      },
    },
  ];

  return {
    resourceSpans: [
      {
        resource: {
          attributes: buildResourceAttributes(),
        },
        scopeSpans: [
          {
            scope: {
              name: "openclaw-o11y.demo",
              version: "0.1.0",
            },
            spans,
          },
        ],
      },
    ],
  };
}

function buildMetricPayload(summary, endedAtNano, startedAtNano) {
  const scenarioAttributes = buildScenarioAttributes(summary);
  const metricAttributes = attributesFromObject(scenarioAttributes);

  return {
    resourceMetrics: [
      {
        resource: {
          attributes: buildResourceAttributes(),
        },
        scopeMetrics: [
          {
            scope: {
              name: "openclaw-o11y.demo",
              version: "0.1.0",
            },
            metrics: [
              {
                name: "openshell.demo.scenario_runs",
                unit: "1",
                sum: {
                  aggregationTemporality: 1,
                  isMonotonic: true,
                  dataPoints: [
                    {
                      attributes: metricAttributes,
                      startTimeUnixNano: startedAtNano,
                      timeUnixNano: endedAtNano,
                      asInt: "1",
                    },
                  ],
                },
              },
              {
                name: "openshell.demo.policy_decisions",
                unit: "1",
                sum: {
                  aggregationTemporality: 1,
                  isMonotonic: true,
                  dataPoints: [
                    {
                      attributes: attributesFromObject({
                        ...scenarioAttributes,
                        "openshell.policy.decision": env(
                          "DEMO_POLICY_DECISION",
                          "allow",
                        ),
                      }),
                      startTimeUnixNano: startedAtNano,
                      timeUnixNano: endedAtNano,
                      asInt: "1",
                    },
                  ],
                },
              },
              {
                name: "openshell.demo.gateway_errors",
                unit: "1",
                sum: {
                  aggregationTemporality: 1,
                  isMonotonic: true,
                  dataPoints: [
                    {
                      attributes: metricAttributes,
                      startTimeUnixNano: startedAtNano,
                      timeUnixNano: endedAtNano,
                      asInt: String(summary.errorCount),
                    },
                  ],
                },
              },
              {
                name: "openshell.demo.action_count",
                unit: "1",
                sum: {
                  aggregationTemporality: 1,
                  isMonotonic: true,
                  dataPoints: [
                    {
                      attributes: metricAttributes,
                      startTimeUnixNano: startedAtNano,
                      timeUnixNano: endedAtNano,
                      asInt: String(envInt("DEMO_ACTION_COUNT", 1)),
                    },
                  ],
                },
              },
              {
                name: "openshell.demo.workflow_latency_ms",
                unit: "ms",
                gauge: {
                  dataPoints: [
                    {
                      attributes: metricAttributes,
                      timeUnixNano: endedAtNano,
                      asDouble: summary.avgLatencyMs,
                    },
                  ],
                },
              },
              {
                name: "openshell.demo.suspicion_score",
                unit: "1",
                gauge: {
                  dataPoints: [
                    {
                      attributes: metricAttributes,
                      timeUnixNano: endedAtNano,
                      asDouble: envFloat("DEMO_SUSPICION_SCORE", 0),
                    },
                  ],
                },
              },
            ],
          },
        ],
      },
    ],
  };
}

function buildLogPayload(summary, traceId, spanId, endedAtNano) {
  const severityText = env("DEMO_LOG_SEVERITY", "INFO").toUpperCase();
  const severityMap = {
    TRACE: 1,
    DEBUG: 5,
    INFO: 9,
    WARN: 13,
    ERROR: 17,
    FATAL: 21,
  };

  return {
    resourceLogs: [
      {
        resource: {
          attributes: buildResourceAttributes(),
        },
        scopeLogs: [
          {
            scope: {
              name: "openclaw-o11y.demo",
              version: "0.1.0",
            },
            logRecords: [
              {
                timeUnixNano: endedAtNano,
                severityNumber: severityMap[severityText] || 9,
                severityText,
                body: {
                  stringValue: env(
                    "DEMO_SUMMARY_MESSAGE",
                    "OpenShell demo scenario emitted",
                  ),
                },
                attributes: attributesFromObject(buildScenarioAttributes(summary)),
                traceId,
                spanId,
              },
            ],
          },
        ],
      },
    ],
  };
}

function normalizeCollectorBaseUrl(urlString) {
  const trimmed = urlString.replace(/\/+$/, "");
  return trimmed.replace(/\/v1\/(?:traces|metrics|logs)$/i, "");
}

async function postPayload(baseUrl, path, payload) {
  const response = await httpRequest(`${normalizeCollectorBaseUrl(baseUrl)}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw new Error(
      `Collector rejected ${path} with status ${response.statusCode}: ${response.body}`,
    );
  }
}

async function main() {
  const startedAtNano = nowUnixNano();
  const gatewayResults = await driveGatewayTraffic();
  const summary = summarizeGatewayResults(gatewayResults);
  const endedAtNano = nowUnixNano();
  const traceId = randomHex(16);
  const spanIds = {
    root: randomHex(8),
    policy: randomHex(8),
    gateway: randomHex(8),
    security: randomHex(8),
  };
  const traces = buildTracePayload(summary, traceId, spanIds, endedAtNano);
  const metrics = buildMetricPayload(summary, endedAtNano, startedAtNano);
  const logs = buildLogPayload(summary, traceId, spanIds.security, endedAtNano);
  const printOnly = envBool("DEMO_PRINT_ONLY", false);
  const collectorUrl = env("DEMO_COLLECTOR_URL", "").replace(/\/$/, "");
  const normalizedCollectorUrl = collectorUrl ? normalizeCollectorBaseUrl(collectorUrl) : "";

  if (!printOnly) {
    if (!normalizedCollectorUrl) {
      throw new Error("DEMO_COLLECTOR_URL must be set when DEMO_PRINT_ONLY=false");
    }
    await postPayload(normalizedCollectorUrl, "/v1/traces", traces);
    await postPayload(normalizedCollectorUrl, "/v1/metrics", metrics);
    await postPayload(normalizedCollectorUrl, "/v1/logs", logs);
  }

  const output = {
    scenario: env("DEMO_SCENARIO", "normal"),
    collectorUrl: printOnly ? "(print-only)" : collectorUrl,
    normalizedCollectorUrl: normalizedCollectorUrl || "(unset)",
    gatewayResults,
    summary,
    resourceServiceName: env(
      "DEMO_SERVICE_NAME",
      "openshell-demo-control-plane",
    ),
  };

  if (printOnly) {
    output.payloads = {
      traces,
      metrics,
      logs,
    };
  }

  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
}

main().catch((error) => {
  process.stderr.write(
    `${error instanceof Error ? error.stack || error.message : String(error)}\n`,
  );
  process.exit(1);
});
