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
collector_port="$(local_collector_host_port)"
relay_port="$(local_openai_relay_host_port)"
expected_model="${LOCAL_OPENAI_MODEL:-gpt-4.1-mini}"
expected_otlp_endpoint="http://${forwarder_service_fqdn}:${forwarder_http_port}"
expected_proxy="http://10.200.0.1:3128"
smoke_agent="false"

usage() {
  cat <<'EOF'
Usage: scripts/local/verify-nemoclaw-otel.sh [--smoke-agent]

Checks:
  - A local collector container is exposing OTLP HTTP on port 4318
  - The local OpenAI relay is healthy on localhost
  - The OpenShell gateway container and OTLP forwarder deployment exist
  - Gateway and system inference are routed to openai-direct
  - The sandboxed OpenClaw gateway process is running with OTEL + OpenShell proxy env
  - The sandbox can POST OTLP to the in-gateway forwarder via the OpenShell proxy
  - Optional: an OpenClaw agent prompt succeeds through the gateway
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
      smoke_agent="true"
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

collector_info="$(find_local_otel_collector "${collector_port}" || true)"
[[ -n "${collector_info}" ]] || fail "No local OTEL collector is exposing host port ${collector_port}."
collector_name="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $1}')"
collector_image="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $2}')"
ok "Collector ${collector_name} (${collector_image}) exposes OTLP HTTP on ${collector_port}"

if [[ -n "${LOCAL_OPENAI_BASE_URL:-}" ]]; then
  ok "Using explicit OpenAI base URL override: ${LOCAL_OPENAI_BASE_URL}"
else
  relay_endpoint="$("${SCRIPT_DIR}/ensure-openai-relay.sh" --print-endpoint)" || fail "Could not start or reuse the local OpenAI relay."
  relay_health_url="http://127.0.0.1:${relay_port}/healthz"
  relay_health="$(curl -fsS "${relay_health_url}")" || fail "OpenAI relay is not healthy on ${relay_health_url}."
  ok "OpenAI relay is healthy on localhost:${relay_port} and advertised to the gateway as ${relay_endpoint}"
fi

gateway_container="openshell-cluster-${gateway_name}"
docker ps --format '{{.Names}}' | grep -qx "${gateway_container}" || fail "OpenShell gateway container is not running: ${gateway_container}."
ok "Gateway container ${gateway_container} is running"

forwarder_cluster_ip="$(docker exec "${gateway_container}" sh -lc "kubectl get svc ${forwarder_name} -n ${forwarder_namespace} -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || true)"
[[ -n "${forwarder_cluster_ip}" && "${forwarder_cluster_ip}" != "None" ]] || fail "OTLP forwarder service ${forwarder_name} is missing in namespace ${forwarder_namespace}."
forwarder_ready="$(docker exec "${gateway_container}" sh -lc "kubectl get deploy ${forwarder_name} -n ${forwarder_namespace} -o jsonpath='{.status.readyReplicas}'" 2>/dev/null || true)"
[[ -n "${forwarder_ready}" && "${forwarder_ready}" != "0" ]] || fail "OTLP forwarder deployment ${forwarder_name} has no ready replicas."
ok "Forwarder service ${forwarder_service_fqdn}:${forwarder_http_port} resolves to ${forwarder_cluster_ip}"

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
printf '%s\n' "\${env_dump}" | grep -qx 'HTTP_PROXY=${expected_proxy}' || {
  echo "gateway process is not using the OpenShell CONNECT proxy" >&2
  exit 13
}
printf '%s\n' "\${env_dump}" | grep -Eq '^NODE_OPTIONS=.*@splunk/otel/instrument\.js' || {
  echo "gateway process is missing the Splunk OTel JS bootstrap" >&2
  exit 14
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

if [[ "${smoke_agent}" == "true" ]]; then
  smoke_script="$(mktemp)"
  cat > "${smoke_script}" <<'EOF'
set -euo pipefail
openclaw agent --agent main -m "reply with the single word ok" --session-id o11y-smoke
EOF
  smoke_output="$(run_sandbox_script "${sandbox_name}" "${smoke_script}")" || {
    rm -f "${smoke_script}"
    fail "OpenClaw smoke agent call failed."
  }
  rm -f "${smoke_script}"
  ok "OpenClaw smoke agent call succeeded: ${smoke_output}"
fi

ok "Local NemoClaw/OpenShell OTEL path is configured for repeatable use"
