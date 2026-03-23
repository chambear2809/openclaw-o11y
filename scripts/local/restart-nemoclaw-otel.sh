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

require_env OPENAI_API_KEY

run_smoke="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke)
      run_smoke="true"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: scripts/local/restart-nemoclaw-otel.sh [--smoke]" >&2
      exit 1
      ;;
  esac
done

sandbox_name="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
collector_host_endpoint="$("${SCRIPT_DIR}/ensure-collector.sh" --print-host-endpoint)"
openai_model="${LOCAL_OPENAI_MODEL:-gpt-4.1-mini}"
if [[ -n "${LOCAL_OPENAI_BASE_URL:-}" ]]; then
  openai_base_url="${LOCAL_OPENAI_BASE_URL}"
else
  openai_base_url="$("${SCRIPT_DIR}/ensure-openai-relay.sh" --print-endpoint)"
fi
deployment_environment="${OPENCLAW_DEPLOYMENT_ENVIRONMENT:-Openclaw}"
gateway_name="$(local_openshell_gateway_name)"
extra_ca_pem="$(resolve_host_extra_ca_pem || true)"
extra_ca_b64=""
if [[ -n "${extra_ca_pem}" ]]; then
  extra_ca_b64="$(printf '%s' "${extra_ca_pem}" | base64 | tr -d '\n')"
fi

echo "Configuring OpenShell gateway inference for OpenAI"
openshell provider create -g "${gateway_name}" \
  --name openai-direct \
  --type openai \
  --credential "OPENAI_API_KEY" \
  --config "OPENAI_BASE_URL=${openai_base_url}" >/dev/null 2>&1 || \
  openshell provider update -g "${gateway_name}" \
    openai-direct \
    --credential "OPENAI_API_KEY" \
    --config "OPENAI_BASE_URL=${openai_base_url}" >/dev/null
openshell inference set -g "${gateway_name}" --no-verify --provider openai-direct --model "${openai_model}" >/dev/null
openshell inference set -g "${gateway_name}" --system --no-verify --provider openai-direct --model "${openai_model}" >/dev/null

echo "Syncing NemoClaw status metadata to the direct OpenAI route"
onboarded_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
sandbox_onboard_config="$(node -e '
const config = {
  endpointType: "custom",
  endpointUrl: process.argv[1],
  ncpPartner: null,
  model: process.argv[2],
  profile: "openai-direct",
  credentialEnv: "OPENAI_API_KEY",
  provider: "openai-direct",
  providerLabel: "OpenAI API",
  onboardedAt: process.argv[3],
};
process.stdout.write(JSON.stringify(config, null, 2));
' "${openai_base_url}" "${openai_model}" "${onboarded_at}")"
sync_script="$(mktemp)"
cat > "${sync_script}" <<EOF
set -euo pipefail
command -v stty >/dev/null 2>&1 && stty -echo || true
mkdir -p ~/.nemoclaw
cat > ~/.nemoclaw/config.json <<'EOF_CFG'
${sandbox_onboard_config}
EOF_CFG
EOF
run_sandbox_script "${sandbox_name}" "${sync_script}"
rm -f "${sync_script}"

nemoclaw_dir="$(resolve_nemoclaw_repo_dir)"
collector_endpoint="$("${SCRIPT_DIR}/ensure-gateway-otlp-forwarder.sh" --print-endpoint)"
collector_forwarder_cluster_ip="$("${SCRIPT_DIR}/ensure-gateway-otlp-forwarder.sh" --print-cluster-ip)"
collector_forwarder_http_port="$(local_gateway_otel_forwarder_http_port)"
collector_forwarder_service_host="$(local_gateway_otel_forwarder_service_host)"
collector_forwarder_service_fqdn="$(local_gateway_otel_forwarder_service_fqdn)"
if [[ -d "${nemoclaw_dir}/bin" ]]; then
  echo "Applying OTEL collector policy preset"
  preset_file="$(mktemp)"
  sed \
    -e "s/__LOCAL_OTEL_FORWARDER_SERVICE_HOST__/${collector_forwarder_service_host}/g" \
    -e "s/__LOCAL_OTEL_FORWARDER_SERVICE_FQDN__/${collector_forwarder_service_fqdn}/g" \
    -e "s/__LOCAL_OTEL_FORWARDER_CLUSTER_IP__/${collector_forwarder_cluster_ip}/g" \
    -e "s/__LOCAL_OTEL_FORWARDER_HTTP_PORT__/${collector_forwarder_http_port}/g" \
    "${SCRIPT_DIR}/presets/otel-collector.yaml" > "${preset_file}"
  cp "${preset_file}" "${nemoclaw_dir}/nemoclaw-blueprint/policies/presets/otel-collector.yaml"
  node -e "const policies = require('${nemoclaw_dir}/bin/lib/policies'); policies.applyPreset('${sandbox_name}', 'otel-collector');"
  rm -f "${preset_file}"
fi

instrument_script="$(mktemp)"
cat > "${instrument_script}" <<EOF
set -euo pipefail
command -v stty >/dev/null 2>&1 && stty -echo || true

export NPM_CONFIG_PREFIX="\$HOME/.npm-global"
mkdir -p "\${NPM_CONFIG_PREFIX}"

if ! npm list -g @splunk/otel >/dev/null 2>&1; then
  npm install -g @splunk/otel >/tmp/otel-install.log 2>&1
fi

npm_root="\$(npm root -g)"
instrument_path="\${npm_root}/@splunk/otel/instrument.js"
if [ ! -e "\${instrument_path}" ]; then
  echo "Missing OTEL bootstrap at \${instrument_path}" >&2
  exit 1
fi

node_extra_certs_file="/etc/openshell-tls/openshell-ca.pem"
if [ -n "${extra_ca_b64}" ]; then
  cat > /tmp/openclaw-host-extra-ca.b64 <<'CERT'
${extra_ca_b64}
CERT
  if base64 --decode >/dev/null 2>&1 <<<""; then
    base64 --decode /tmp/openclaw-host-extra-ca.b64 > /tmp/openclaw-host-extra-ca.pem
  else
    base64 -d /tmp/openclaw-host-extra-ca.b64 > /tmp/openclaw-host-extra-ca.pem
  fi
  cat /etc/openshell-tls/openshell-ca.pem /tmp/openclaw-host-extra-ca.pem > /tmp/openclaw-node-extra-ca.pem
  chmod 600 /tmp/openclaw-node-extra-ca.pem
  node_extra_certs_file="/tmp/openclaw-node-extra-ca.pem"
fi

gateway_pid="\$(ss -ltnp '( sport = :18789 )' 2>/dev/null | awk -F'pid=' 'NR>1 && NF>1 {split(\$2, parts, ","); print parts[1]; exit}')"
if [ -n "\${gateway_pid}" ]; then
  kill "\${gateway_pid}" >/dev/null 2>&1 || true
  sleep 2
fi

node_opts="--require \${instrument_path}"
if [ -n "${OPENCLAW_NODE_OPTIONS_BASE:-}" ]; then
  node_opts="${OPENCLAW_NODE_OPTIONS_BASE:-} \${node_opts}"
fi

nohup env \\
  OTEL_SERVICE_NAME="openclaw" \\
  OTEL_RESOURCE_ATTRIBUTES="deployment.environment=${deployment_environment},demo.runtime=nemoclaw-local,sandbox.name=${sandbox_name}" \\
  OTEL_TRACES_EXPORTER="otlp" \\
  OTEL_METRICS_EXPORTER="none" \\
  OTEL_LOGS_EXPORTER="none" \\
  OTEL_EXPORTER_OTLP_ENDPOINT="${collector_endpoint}" \\
  OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf" \\
  OTEL_PROPAGATORS="tracecontext,baggage" \\
  SPLUNK_TRACE_RESPONSE_HEADER_ENABLED="false" \\
  NODE_EXTRA_CA_CERTS="\${node_extra_certs_file}" \\
  SSL_CERT_FILE="\${node_extra_certs_file}" \\
  REQUESTS_CA_BUNDLE="\${node_extra_certs_file}" \\
  CURL_CA_BUNDLE="\${node_extra_certs_file}" \\
  NODE_OPTIONS="\${node_opts}" \\
  nemoclaw-start >/tmp/nemoclaw-otel-start.log 2>&1 &

sleep 4
ss -ltn '( sport = :18789 )' | grep -q ':18789'
echo "sandbox gateway restarted with OTEL"
EOF

echo "Installing Splunk OTel JS and restarting the sandbox gateway under instrumentation"
run_sandbox_script "${sandbox_name}" "${instrument_script}"
rm -f "${instrument_script}"

echo "Sandbox: ${sandbox_name}"
echo "OpenAI model: ${openai_model}"
echo "Gateway OpenAI base URL: ${openai_base_url}"
echo "Sandbox OTLP endpoint: ${collector_endpoint}"
echo "Host OTLP endpoint: ${collector_host_endpoint}"
echo "Gateway UI: http://127.0.0.1:18789"

if [[ "${run_smoke}" == "true" ]]; then
  smoke_script="$(mktemp)"
  cat > "${smoke_script}" <<'EOF'
set -euo pipefail
openclaw agent --agent main -m "reply with the single word ok" --session-id o11y-smoke
EOF
  echo "Running OpenClaw smoke prompt"
  run_sandbox_script "${sandbox_name}" "${smoke_script}"
  rm -f "${smoke_script}"
fi
