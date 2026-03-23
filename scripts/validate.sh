#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
K8S_MANIFEST_DIR="${ROOT_DIR}/scripts/k8s/manifests"
RENDERER="${ROOT_DIR}/scripts/k8s/render-openclaw-manifests.js"

require_tool() {
  local tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
}

render_manifests() {
  local instrumentation_ref="${1:-}"

  kubectl kustomize "${K8S_MANIFEST_DIR}" | env \
    OPENCLAW_STORAGE_CLASS="standard" \
    OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:latest" \
    OPENCLAW_NODE_OPTIONS="--max-old-space-size=1536" \
    OPENCLAW_SERVICE_NAME="openclaw" \
    OPENCLAW_RESOURCE_ATTRIBUTES="deployment.environment=Openclaw" \
    OPENCLAW_SECRET_NAME="openclaw-secrets" \
    OPENCLAW_MEMORY_REQUEST="1Gi" \
    OPENCLAW_MEMORY_LIMIT="2Gi" \
    OPENCLAW_INSTRUMENTATION_REF="${instrumentation_ref}" \
    node "${RENDERER}"
}

require_tool kubectl
require_tool node
require_tool zsh

cd "${ROOT_DIR}"

echo "Checking shell syntax"
zsh -n scripts/k8s/*.sh scripts/local/*.sh scripts/validate.sh

echo "Checking Node.js syntax"
node --check scripts/k8s/*.js
node --check scripts/local/*.js

echo "Checking local policy preset merge idempotence"
node - <<'NODE'
const fs = require("fs");
const {
  extractPresetEntries,
  mergePresetEntries,
} = require("./scripts/local/apply-policy-preset.js");

const presetContent = fs.readFileSync("./scripts/local/presets/otel-collector.yaml", "utf8");
const presetEntries = extractPresetEntries(presetContent);
if (!presetEntries) {
  throw new Error("Could not extract network_policies from the OTEL preset");
}

const currentPolicy = [
  "version: 1",
  "",
  "network_policies:",
  "  npm_registry_node:",
  "    name: npm_registry_node",
  "    endpoints:",
  "      - host: stale.example.com",
  "        port: 443",
  "        access: full",
  "",
  "inference_policy:",
  "  mode: suggest",
].join("\n");

const mergedOnce = mergePresetEntries(currentPolicy, presetEntries);
const mergedTwice = mergePresetEntries(mergedOnce, presetEntries);
const npmRegistryNodeCount = (mergedTwice.match(/^  npm_registry_node:/gm) || []).length;
const otelForwarderCount = (mergedTwice.match(/^  otel_forwarder:/gm) || []).length;

if (npmRegistryNodeCount !== 1 || otelForwarderCount !== 1) {
  throw new Error("Policy preset merge duplicated network policy entries");
}
if (!mergedTwice.includes("inference_policy:\n  mode: suggest")) {
  throw new Error("Policy preset merge dropped unrelated top-level policy sections");
}
NODE

echo "Checking demo emitter OTLP normalization and span kinds"
node - <<'NODE'
const { execFileSync } = require("child_process");

const output = execFileSync("node", ["scripts/k8s/demo-emitter.js"], {
  cwd: process.cwd(),
  encoding: "utf8",
  env: {
    ...process.env,
    DEMO_PRINT_ONLY: "true",
    DEMO_SCENARIO: "normal",
    DEMO_GATEWAY_MODE: "none",
    DEMO_COLLECTOR_URL: "http://collector.example:4318/v1/traces",
  },
});

const payload = JSON.parse(output);
if (payload.normalizedCollectorUrl !== "http://collector.example:4318") {
  throw new Error(`Unexpected normalized collector URL: ${payload.normalizedCollectorUrl}`);
}

const spans =
  payload.payloads.traces.resourceSpans[0].scopeSpans[0].spans;
if (spans.some((span) => span.kind === 2)) {
  throw new Error("Synthetic demo spans should not be emitted as SERVER spans");
}
NODE

echo "Rendering Kubernetes manifests without instrumentation"
rendered_without_instrumentation="$(mktemp)"
rendered_with_instrumentation="$(mktemp)"
trap 'rm -f "${rendered_without_instrumentation}" "${rendered_with_instrumentation}"' EXIT

render_manifests > "${rendered_without_instrumentation}"
grep -q 'image: "ghcr.io/openclaw/openclaw:latest"' "${rendered_without_instrumentation}"
grep -q 'value: "openclaw"' "${rendered_without_instrumentation}"
grep -q 'value: "deployment.environment=Openclaw"' "${rendered_without_instrumentation}"
if grep -q 'instrumentation.opentelemetry.io/inject-nodejs' "${rendered_without_instrumentation}"; then
  echo "Rendered manifests unexpectedly include instrumentation annotations" >&2
  exit 1
fi

echo "Rendering Kubernetes manifests with instrumentation"
render_manifests "splunk-o11y/splunk-otel" > "${rendered_with_instrumentation}"
grep -q 'instrumentation.opentelemetry.io/inject-nodejs: "splunk-o11y/splunk-otel"' "${rendered_with_instrumentation}"
grep -q 'instrumentation.opentelemetry.io/container-names: "openclaw"' "${rendered_with_instrumentation}"

echo "Validation passed"
