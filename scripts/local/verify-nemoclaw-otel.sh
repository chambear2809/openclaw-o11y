#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

export PATH="${HOME}/.local/bin:${PATH}"

load_lab_env

sandbox_name="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
gateway_name="$(local_openshell_gateway_name)"
forwarder_name="$(local_gateway_otel_forwarder_name)"
forwarder_namespace="$(local_gateway_otel_forwarder_namespace)"
forwarder_service_fqdn="$(local_gateway_otel_forwarder_service_fqdn)"
forwarder_http_port="$(local_gateway_otel_forwarder_http_port)"
agent_sandbox_namespace="$(local_agent_sandbox_namespace)"
agent_sandbox_service_name="$(local_agent_sandbox_controller_service_name)"
agent_sandbox_metrics_bridge_port="$(local_agent_sandbox_metrics_bridge_port)"
agent_sandbox_metrics_target="$(local_agent_sandbox_metrics_target)"
agent_sandbox_metrics_url="http://${agent_sandbox_metrics_target}/metrics"
expected_agent_sandbox_service_name="$(local_agent_sandbox_metrics_service_name)"
collector_port="$(local_collector_host_port)"
relay_port="$(local_openai_relay_host_port)"
expected_model="$(local_openai_model)"
stub_smoke_model="$(local_openai_smoke_stub_model)"
relay_service_name="$(local_openai_relay_service_name)"
expected_deployment_environment="$(local_deployment_environment)"
expected_python_otel_version="$(local_splunk_otel_python_version)"
expected_otlp_endpoint="http://${forwarder_service_fqdn}:${forwarder_http_port}"
smoke_agent_stub="false"
smoke_agent_real="false"

usage() {
  cat <<EOF
Usage: scripts/local/verify-nemoclaw-otel.sh [--smoke-agent] [--smoke-agent-real]

Checks:
  - A local collector container is exposing OTLP HTTP on the configured host port (${collector_port})
  - The local OpenAI relay is healthy on localhost
  - The OpenShell gateway container and OTLP forwarder deployment exist
  - The repo-managed collector scrapes agent-sandbox-controller Prometheus metrics from the embedded k3s cluster
  - Gateway and system inference are routed to openai-direct
  - The sandboxed OpenClaw gateway process is running with OTEL + OpenShell proxy env
  - The sandboxed OpenClaw runtime carries the Python OTEL bootstrap for NemoClaw helper processes
  - The sandbox can POST OTLP to the in-gateway forwarder via the OpenShell proxy
  - Optional: a stubbed or real OpenClaw agent prompt succeeds through the gateway
EOF
}

ok() {
  printf '[ok] %s\n' "$1"
}

fail() {
  printf '[fail] %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke-agent)
      smoke_agent_stub="true"
      ;;
    --smoke-agent-real)
      smoke_agent_real="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

require_tool docker
require_tool curl
require_tool openshell
require_tool ssh

collector_host_endpoint="$("${SCRIPT_DIR}/ensure-collector.sh" --print-host-endpoint)" || fail "Could not start or reuse the local OTEL collector."
collector_info="$(find_local_otel_collector "${collector_port}" || true)"
[[ -n "${collector_info}" ]] || fail "No local OTEL collector is exposing host port ${collector_port}."
collector_name="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $1}')"
collector_image="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $2}')"
local_otel_collector_supports_traces "${collector_name}" || fail "Collector ${collector_name} does not expose a traces pipeline, so NemoClaw OTEL data will be dropped."
ok "Collector ${collector_name} (${collector_image}) exposes OTLP HTTP on ${collector_port}"

if [[ -n "${LOCAL_OPENAI_BASE_URL:-}" ]]; then
  ok "Using explicit OpenAI base URL override: ${LOCAL_OPENAI_BASE_URL}"
else
  relay_endpoint="$("${SCRIPT_DIR}/ensure-openai-relay.sh" --print-endpoint)" || fail "Could not start or reuse the local OpenAI relay."
  relay_health_url="http://127.0.0.1:${relay_port}/healthz"
  relay_health="$(curl -fsS "${relay_health_url}")" || fail "OpenAI relay is not healthy on ${relay_health_url}."
  printf '%s\n' "${relay_health}" | grep -Fq "\"otelServiceName\":\"${relay_service_name}\"" || fail "OpenAI relay is not instrumented as ${relay_service_name}."
  printf '%s\n' "${relay_health}" | grep -Fq "\"otelExporterEndpoint\":\"${collector_host_endpoint}\"" || fail "OpenAI relay is not exporting OTLP to ${collector_host_endpoint}."
  printf '%s\n' "${relay_health}" | grep -Fq "\"deploymentEnvironment\":\"${expected_deployment_environment}\"" || fail "OpenAI relay is not tagged with deployment.environment=${expected_deployment_environment}."
  ok "OpenAI relay is healthy on localhost:${relay_port} and advertised to the gateway as ${relay_endpoint}"
  ok "OpenAI relay is instrumented as ${relay_service_name} in deployment.environment=${expected_deployment_environment}"
fi

gateway_container="openshell-cluster-${gateway_name}"
docker ps --format '{{.Names}}' | grep -qx "${gateway_container}" || fail "OpenShell gateway container is not running: ${gateway_container}."
ok "Gateway container ${gateway_container} is running"

forwarder_cluster_ip="$(docker exec "${gateway_container}" sh -lc "kubectl get svc ${forwarder_name} -n ${forwarder_namespace} -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || true)"
[[ -n "${forwarder_cluster_ip}" && "${forwarder_cluster_ip}" != "None" ]] || fail "OTLP forwarder service ${forwarder_name} is missing in namespace ${forwarder_namespace}."
forwarder_ready="$(docker exec "${gateway_container}" sh -lc "kubectl get deploy ${forwarder_name} -n ${forwarder_namespace} -o jsonpath='{.status.readyReplicas}'" 2>/dev/null || true)"
[[ -n "${forwarder_ready}" && "${forwarder_ready}" != "0" ]] || fail "OTLP forwarder deployment ${forwarder_name} has no ready replicas."
ok "Forwarder service ${forwarder_service_fqdn}:${forwarder_http_port} resolves to ${forwarder_cluster_ip}"

agent_sandbox_cluster_ip="$(docker exec "${gateway_container}" sh -lc "kubectl get svc ${agent_sandbox_service_name} -n ${agent_sandbox_namespace} -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || true)"
[[ -n "${agent_sandbox_cluster_ip}" && "${agent_sandbox_cluster_ip}" != "None" ]] || fail "Agent-sandbox metrics service ${agent_sandbox_service_name} is missing in namespace ${agent_sandbox_namespace}."
if [[ "${collector_name}" == "${LOCAL_OTEL_COLLECTOR_CONTAINER_NAME:-openclaw-local-otel-collector}" ]]; then
  local_otel_collector_supports_metrics "${collector_name}" || fail "Collector ${collector_name} does not expose a metrics pipeline for agent-sandbox-controller."
  local_otel_collector_supports_agent_sandbox_metrics "${collector_name}" "${agent_sandbox_metrics_target}" || fail "Collector ${collector_name} is not configured to scrape agent-sandbox-controller metrics from ${agent_sandbox_metrics_target}."
  [[ "$(docker_container_env_value "${collector_name}" "OPENCLAW_AGENT_SANDBOX_METRICS_TARGET")" == "${agent_sandbox_metrics_target}" ]] || fail "Collector ${collector_name} is scraping the wrong agent-sandbox metrics target."
  [[ "$(docker_container_env_value "${collector_name}" "OPENCLAW_AGENT_SANDBOX_METRICS_SERVICE_NAME")" == "${expected_agent_sandbox_service_name}" ]] || fail "Collector ${collector_name} is tagging agent-sandbox metrics with the wrong service.name."
  [[ "$(docker_container_env_value "${collector_name}" "OPENCLAW_DEPLOYMENT_ENVIRONMENT")" == "${expected_deployment_environment}" ]] || fail "Collector ${collector_name} is tagging agent-sandbox metrics with the wrong deployment.environment."
  docker exec -i "${collector_name}" /usr/lib/splunk-otel-collector/agent-bundle/bin/python - "${agent_sandbox_metrics_url}" <<'PY' >/dev/null || \
    fail "Collector ${collector_name} cannot scrape agent-sandbox-controller metrics from ${agent_sandbox_metrics_url}."
import sys
import urllib.request

url = sys.argv[1]
with urllib.request.urlopen(url, timeout=10) as response:
    body = response.read().decode("utf-8", "replace")

if response.status != 200:
    raise SystemExit(f"unexpected status {response.status}")
required_metrics = (
    "controller_runtime_reconcile_total",
    "controller_runtime_reconcile_errors_total",
)
for metric in required_metrics:
    if metric not in body:
        raise SystemExit(f"missing metric {metric}")
PY
fi
ok "Collector ${collector_name} scrapes agent-sandbox-controller metrics from ${agent_sandbox_metrics_target} via bridge port ${agent_sandbox_metrics_bridge_port}"

inference_output="$(openshell inference get -g "${gateway_name}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
[[ -n "${inference_output}" ]] || fail "Could not read OpenShell inference configuration for gateway ${gateway_name}."
provider_count="$(printf '%s\n' "${inference_output}" | grep -c 'Provider: openai-direct' || true)"
model_count="$(printf '%s\n' "${inference_output}" | grep -c "Model: ${expected_model}" || true)"
[[ "${provider_count}" -ge 2 ]] || fail "Gateway and system inference are not both set to provider openai-direct."
[[ "${model_count}" -ge 2 ]] || fail "Gateway and system inference are not both set to model ${expected_model}."
ok "Gateway and system inference both target openai-direct / ${expected_model}"

sandbox_probe="$(mktemp)"
cat > "${sandbox_probe}" <<EOF
set -euo pipefail

gateway_pid="\$(ss -ltnp '( sport = :18789 )' 2>/dev/null | awk -F'pid=' 'NR>1 && NF>1 {split(\$2, parts, ","); print parts[1]; exit}')"
[[ -n "\${gateway_pid}" ]] || { echo "missing gateway listener on 18789" >&2; exit 10; }

env_dump="\$(tr '\0' '\n' < "/proc/\${gateway_pid}/environ")"
printf '%s\n' "\${env_dump}" | grep -qx 'OTEL_EXPORTER_OTLP_ENDPOINT=${expected_otlp_endpoint}' || {
  echo "unexpected OTLP endpoint in gateway process env" >&2
  exit 11
}
printf '%s\n' "\${env_dump}" | grep -qx 'NODE_USE_ENV_PROXY=1' || {
  echo "gateway process is not opting Node into proxy env support" >&2
  exit 12
}
printf '%s\n' "\${env_dump}" | grep -Eq '^HTTP_PROXY=.+' || {
  echo "gateway process is not exporting an HTTP proxy setting" >&2
  exit 13
}
printf '%s\n' "\${env_dump}" | grep -Eq '^NODE_OPTIONS=.*@splunk/otel/instrument\.js' || {
  echo "gateway process is missing the Splunk OTel JS bootstrap" >&2
  exit 14
}
printf '%s\n' "\${env_dump}" | grep -qx 'OPENCLAW_PYTHON_OTEL_BOOTSTRAP=1' || {
  echo "gateway process is missing the Python OTEL bootstrap marker" >&2
  exit 15
}
printf '%s\n' "\${env_dump}" | grep -qx 'OPENCLAW_PYTHON_OTEL_VERSION=${expected_python_otel_version}' || {
  echo "gateway process is missing the expected Python OTEL version" >&2
  exit 16
}
printf '%s\n' "\${env_dump}" | grep -Eq '^PYTHONPATH=/tmp/openclaw-python-otel/bootstrap:/tmp/openclaw-python-otel/site-packages(:.*)?$' || {
  echo "gateway process is missing the Python OTEL bootstrap path" >&2
  exit 17
}
[ -s /tmp/openclaw-python-otel.marker.log ] || {
  echo "Python OTEL marker file was not written by NemoClaw helper processes" >&2
  exit 18
}

node - "${expected_otlp_endpoint}/v1/traces" <<'NODE'
(async () => {
  const response = await fetch(process.argv[2], {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ resourceSpans: [] }),
  });
  const body = await response.text();
  console.log("otlp_status=" + response.status);
  console.log("otlp_body=" + body);
  if (response.status !== 200) {
    process.exit(21);
  }
})().catch((error) => {
  console.error(error instanceof Error ? error.stack : String(error));
  process.exit(20);
});
NODE
EOF

sandbox_output="$(run_sandbox_script "${sandbox_name}" "${sandbox_probe}")" || {
  rm -f "${sandbox_probe}"
  fail "Sandbox OTLP verification failed for ${sandbox_name}."
}
rm -f "${sandbox_probe}"

printf '%s\n' "${sandbox_output}" | grep -q '^otlp_status=200$' || fail "Sandbox OTLP probe did not return HTTP 200."
ok "Sandboxed OpenClaw gateway exports to ${expected_otlp_endpoint} through the OpenShell proxy"
ok "Sandboxed OpenClaw runtime includes Python OTEL bootstrap ${expected_python_otel_version}"

if [[ "${smoke_agent_stub}" == "true" ]]; then
  smoke_output="$(run_openclaw_smoke_agent_with_model "${sandbox_name}" "${stub_smoke_model}" "${expected_model}" "o11y-smoke-stub" "${gateway_name}")" || \
    fail "OpenClaw stub smoke agent call failed."
  ok "OpenClaw stub smoke agent call succeeded: ${smoke_output}"
fi

if [[ "${smoke_agent_real}" == "true" ]]; then
  smoke_output="$(run_openclaw_smoke_agent "${sandbox_name}" "o11y-smoke-real")" || fail "OpenClaw real smoke agent call failed."
  ok "OpenClaw real smoke agent call succeeded: ${smoke_output}"
fi

ok "Local NemoClaw/OpenShell OTEL path is configured for repeatable use"
