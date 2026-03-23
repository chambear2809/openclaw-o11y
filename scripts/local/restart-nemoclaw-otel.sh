#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

export PATH="${HOME}/.local/bin:${PATH}"

load_lab_env

require_tool node
require_tool npm
require_tool openshell
require_tool ssh

run_stub_smoke="false"
run_real_smoke="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke)
      run_stub_smoke="true"
      shift
      ;;
    --smoke-real)
      run_real_smoke="true"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: scripts/local/restart-nemoclaw-otel.sh [--smoke] [--smoke-real]" >&2
      exit 1
      ;;
  esac
done

if [[ "${run_real_smoke}" == "true" ]]; then
  require_env OPENAI_API_KEY
fi

sandbox_name="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
collector_host_endpoint="$("${SCRIPT_DIR}/ensure-collector.sh" --print-host-endpoint)"
openai_model="$(local_openai_model)"
stub_smoke_model="$(local_openai_smoke_stub_model)"
splunk_otel_js_version="$(local_splunk_otel_js_version)"
splunk_otel_python_version="$(local_splunk_otel_python_version)"
deployment_environment="$(local_deployment_environment)"
gateway_name="$(local_openshell_gateway_name)"
provider_api_key="$(local_openai_provider_api_key)"
extra_ca_pem="$(resolve_host_extra_ca_pem || true)"
extra_ca_b64=""
if [[ -n "${extra_ca_pem}" ]]; then
  extra_ca_b64="$(printf '%s' "${extra_ca_pem}" | base64 | tr -d '\n')"
fi

if [[ -n "${LOCAL_OPENAI_BASE_URL:-}" ]]; then
  openai_base_url="${LOCAL_OPENAI_BASE_URL}"
else
  openai_base_url="$("${SCRIPT_DIR}/ensure-openai-relay.sh" --print-endpoint)"
fi

echo "Configuring OpenShell gateway inference for OpenAI"
env OPENAI_API_KEY="${provider_api_key}" \
  openshell provider create -g "${gateway_name}" \
    --name openai-direct \
    --type openai \
    --credential "OPENAI_API_KEY" \
    --config "OPENAI_BASE_URL=${openai_base_url}" >/dev/null 2>&1 || \
  env OPENAI_API_KEY="${provider_api_key}" \
    openshell provider update -g "${gateway_name}" \
      openai-direct \
      --credential "OPENAI_API_KEY" \
      --config "OPENAI_BASE_URL=${openai_base_url}" >/dev/null
set_openai_direct_inference_model "${openai_model}" "${gateway_name}"

collector_endpoint="$("${SCRIPT_DIR}/ensure-gateway-otlp-forwarder.sh" --print-endpoint)"
collector_forwarder_cluster_ip="$("${SCRIPT_DIR}/ensure-gateway-otlp-forwarder.sh" --print-cluster-ip)"
collector_forwarder_http_port="$(local_gateway_otel_forwarder_http_port)"
collector_forwarder_service_host="$(local_gateway_otel_forwarder_service_host)"
collector_forwarder_service_fqdn="$(local_gateway_otel_forwarder_service_fqdn)"
echo "Applying OTEL collector policy preset"
preset_file="$(mktemp)"
sed \
  -e "s/__LOCAL_OTEL_FORWARDER_SERVICE_HOST__/${collector_forwarder_service_host}/g" \
  -e "s/__LOCAL_OTEL_FORWARDER_SERVICE_FQDN__/${collector_forwarder_service_fqdn}/g" \
  -e "s/__LOCAL_OTEL_FORWARDER_CLUSTER_IP__/${collector_forwarder_cluster_ip}/g" \
  -e "s/__LOCAL_OTEL_FORWARDER_HTTP_PORT__/${collector_forwarder_http_port}/g" \
  "${SCRIPT_DIR}/presets/otel-collector.yaml" > "${preset_file}"
node "${SCRIPT_DIR}/apply-policy-preset.js" "${sandbox_name}" "${preset_file}"
rm -f "${preset_file}"

echo "Preparing pinned Splunk OTel Python bootstrap inside the sandbox"
ensure_sandbox_python_otel_packages "${sandbox_name}" "${splunk_otel_python_version}" "${extra_ca_b64}" >/dev/null

instrument_script="$(mktemp)"
write_sandbox_otel_restart_script \
  "${instrument_script}" \
  "${splunk_otel_js_version}" \
  "${splunk_otel_python_version}" \
  "${extra_ca_b64}" \
  "${deployment_environment}" \
  "${sandbox_name}" \
  "${collector_endpoint}"

echo "Installing Splunk OTel JS/Python and restarting the sandbox gateway under instrumentation"
run_sandbox_script "${sandbox_name}" "${instrument_script}"
rm -f "${instrument_script}"

echo "Sandbox: ${sandbox_name}"
echo "OpenAI model: ${openai_model}"
echo "Gateway OpenAI base URL: ${openai_base_url}"
echo "Sandbox OTLP endpoint: ${collector_endpoint}"
echo "Host OTLP endpoint: ${collector_host_endpoint}"
echo "Gateway UI: http://127.0.0.1:18789"

if [[ "${run_stub_smoke}" == "true" ]]; then
  echo "Running default OpenClaw stub smoke prompt via ${stub_smoke_model}"
  run_openclaw_smoke_agent_with_model "${sandbox_name}" "${stub_smoke_model}" "${openai_model}" "o11y-smoke-stub" "${gateway_name}"
fi

if [[ "${run_real_smoke}" == "true" ]]; then
  echo "Running secondary OpenClaw real-provider smoke prompt via ${openai_model}"
  run_openclaw_smoke_agent "${sandbox_name}" "o11y-smoke-real"
fi
