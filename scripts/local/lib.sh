#!/bin/zsh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ENV_FILE="${LAB_ENV_FILE:-${SCRIPT_DIR}/lab.env}"

load_lab_env() {
  if [[ -f "${LAB_ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${LAB_ENV_FILE}"
    set +a
  fi
}

require_tool() {
  local tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  local value="${(P)name:-}"
  if [[ -z "${value}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

find_local_otel_collector() {
  local port="${1:-${LOCAL_OTEL_COLLECTOR_HOST_PORT:-4318}}"
  local match=""

  match="$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' | awk -F'\t' -v port="${port}" 'index($3, ":" port "->") { print; exit }')"
  if [[ -n "${match}" ]]; then
    printf '%s\n' "${match}"
    return 0
  fi

  return 1
}

local_otel_collector_config_paths() {
  printf '%s\n' "/etc/otel/collector/gateway_config.yaml"
  printf '%s\n' "/etc/otel/collector/config.yaml"
  printf '%s\n' "/etc/otelcol-contrib/config.yaml"
  printf '%s\n' "/etc/otelcol/config.yaml"
  printf '%s\n' "/otel-local-config.yaml"
}

read_local_otel_collector_config() {
  local container_name="$1"
  local config_path=""
  local config=""

  config="$(docker exec "${container_name}" sh -lc 'if [ -n "${SPLUNK_CONFIG_YAML:-}" ]; then printf "%s\n" "$SPLUNK_CONFIG_YAML"; fi' 2>/dev/null || true)"
  if [[ -n "${config}" ]]; then
    printf '%s\n' "${config}"
    return 0
  fi

  while IFS= read -r config_path; do
    [[ -n "${config_path}" ]] || continue
    config="$(docker exec "${container_name}" sh -lc "if [ -f '${config_path}' ]; then cat '${config_path}'; fi" 2>/dev/null || true)"
    if [[ -n "${config}" ]]; then
      printf '%s\n' "${config}"
      return 0
    fi
  done < <(local_otel_collector_config_paths)

  return 1
}

local_otel_collector_supports_traces() {
  local container_name="$1"
  local config=""

  config="$(read_local_otel_collector_config "${container_name}" 2>/dev/null || true)"
  [[ -n "${config}" ]] || return 1
  printf '%s\n' "${config}" | grep -Eq '^[[:space:]]*traces:([[:space:]]|$)'
}

local_otel_collector_supports_metrics() {
  local container_name="$1"
  local config=""

  config="$(read_local_otel_collector_config "${container_name}" 2>/dev/null || true)"
  [[ -n "${config}" ]] || return 1
  printf '%s\n' "${config}" | grep -Eq '^[[:space:]]*metrics(/[^:]+)?:([[:space:]]|$)'
}

local_otel_collector_supports_agent_sandbox_metrics() {
  local container_name="$1"
  local scrape_target="$2"
  local config=""

  config="$(read_local_otel_collector_config "${container_name}" 2>/dev/null || true)"
  [[ -n "${config}" ]] || return 1
  printf '%s\n' "${config}" | grep -Fq 'job_name: agent-sandbox-controller' || return 1
  if printf '%s\n' "${config}" | grep -Fq "${scrape_target}"; then
    return 0
  fi
  printf '%s\n' "${config}" | grep -Fq '${OPENCLAW_AGENT_SANDBOX_METRICS_TARGET}'
}

docker_container_env_value() {
  local container_name="$1"
  local env_name="$2"

  docker inspect "${container_name}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
    awk -F= -v env_name="${env_name}" '$1 == env_name {print substr($0, index($0, "=") + 1); exit}'
}

local_collector_host_port() {
  printf '%s\n' "${LOCAL_OTEL_COLLECTOR_HOST_PORT:-4318}"
}

local_otel_collector_image() {
  printf '%s\n' "${LOCAL_OTEL_COLLECTOR_IMAGE:-quay.io/signalfx/splunk-otel-collector:0.126.0}"
}

format_host_for_url() {
  local host="$1"

  if [[ "${host}" == \[*\] ]]; then
    printf '%s\n' "${host}"
    return 0
  fi

  if [[ "${host}" == *:* ]]; then
    printf '[%s]\n' "${host}"
    return 0
  fi

  printf '%s\n' "${host}"
}

local_gateway_host_alias() {
  printf '%s\n' "${LOCAL_GATEWAY_HOST_ALIAS:-}"
}

local_gateway_host_ip() {
  printf '%s\n' "${LOCAL_GATEWAY_HOST_IP:-}"
}

local_openshell_gateway_name() {
  printf '%s\n' "${LOCAL_OPENSHELL_GATEWAY_NAME:-nemoclaw}"
}

local_gateway_otel_forwarder_name() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_NAME:-openclaw-otlp-forwarder}"
}

local_gateway_otel_forwarder_namespace() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_NAMESPACE:-openshell}"
}

local_gateway_otel_forwarder_http_port() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_HTTP_PORT:-4318}"
}

local_gateway_otel_forwarder_host_port() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_HOST_PORT:-43181}"
}

local_gateway_otel_forwarder_health_port() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_HEALTH_PORT:-13181}"
}

local_gateway_otel_forwarder_image() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_IMAGE:-otel/opentelemetry-collector-contrib:0.126.0}"
}

local_gateway_otel_forwarder_service_host() {
  printf '%s.%s.svc\n' "$(local_gateway_otel_forwarder_name)" "$(local_gateway_otel_forwarder_namespace)"
}

local_gateway_otel_forwarder_service_fqdn() {
  printf '%s.%s.svc.cluster.local\n' "$(local_gateway_otel_forwarder_name)" "$(local_gateway_otel_forwarder_namespace)"
}

local_gateway_otel_forwarder_endpoint() {
  printf 'http://%s:%s\n' "$(local_gateway_otel_forwarder_service_fqdn)" "$(local_gateway_otel_forwarder_http_port)"
}

local_collector_sandbox_endpoint() {
  local_gateway_otel_forwarder_endpoint
}

local_collector_host_endpoint() {
  printf 'http://127.0.0.1:%s\n' "$(local_collector_host_port)"
}

local_openai_relay_host_port() {
  printf '%s\n' "${LOCAL_OPENAI_RELAY_PORT:-8787}"
}

local_openai_relay_host_endpoint() {
  printf 'http://127.0.0.1:%s/v1\n' "$(local_openai_relay_host_port)"
}

local_openai_model() {
  printf '%s\n' "${LOCAL_OPENAI_MODEL:-gpt-4.1-mini}"
}

local_openai_smoke_stub_model() {
  printf '%s\n' "${LOCAL_OPENAI_SMOKE_STUB_MODEL:-openclaw-smoke-stub}"
}

local_openai_smoke_timeout_seconds() {
  printf '%s\n' "${LOCAL_OPENAI_SMOKE_TIMEOUT_SECONDS:-45}"
}

local_splunk_otel_js_version() {
  printf '%s\n' "${LOCAL_SPLUNK_OTEL_JS_VERSION:-4.0.0}"
}

local_splunk_otel_python_version() {
  printf '%s\n' "${LOCAL_SPLUNK_OTEL_PYTHON_VERSION:-2.9.0}"
}

local_deployment_environment() {
  printf '%s\n' "${OPENCLAW_DEPLOYMENT_ENVIRONMENT:-nemolaw}"
}

local_agent_sandbox_namespace() {
  printf '%s\n' "${LOCAL_AGENT_SANDBOX_NAMESPACE:-agent-sandbox-system}"
}

local_agent_sandbox_controller_service_name() {
  printf '%s\n' "${LOCAL_AGENT_SANDBOX_CONTROLLER_SERVICE_NAME:-agent-sandbox-controller}"
}

local_agent_sandbox_metrics_bridge_port() {
  printf '%s\n' "${LOCAL_AGENT_SANDBOX_METRICS_BRIDGE_PORT:-19090}"
}

local_agent_sandbox_metrics_service_name() {
  printf '%s\n' "${LOCAL_AGENT_SANDBOX_METRICS_SERVICE_NAME:-agent-sandbox-controller}"
}

local_openai_relay_service_name() {
  printf '%s\n' "${LOCAL_OPENAI_RELAY_SERVICE_NAME:-openai-relay}"
}

local_openai_provider_api_key() {
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    printf '%s\n' "${OPENAI_API_KEY}"
    return 0
  fi

  printf '%s\n' "${LOCAL_OPENAI_STUB_API_KEY:-openclaw-local-stub-key}"
}

gateway_container_name() {
  printf 'openshell-cluster-%s\n' "$(local_openshell_gateway_name)"
}

local_agent_sandbox_metrics_target() {
  printf '%s:%s\n' "$(gateway_container_name)" "$(local_agent_sandbox_metrics_bridge_port)"
}

local_gateway_host_alias_candidates() {
  local explicit_alias="$(local_gateway_host_alias)"
  if [[ -n "${explicit_alias}" ]]; then
    printf '%s\n' "${explicit_alias}"
    return 0
  fi

  printf '%s\n' "host.docker.internal"
  printf '%s\n' "host.containers.internal"
}

gateway_container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$(gateway_container_name)"
}

resolve_gateway_alias_ipv4() {
  local gateway_container="$1"
  local alias="$2"
  local resolved_ip=""

  resolved_ip="$(docker exec "${gateway_container}" sh -lc "if command -v getent >/dev/null 2>&1; then getent ahostsv4 '${alias}' 2>/dev/null | awk 'NR==1 {print \$1; exit}'; fi" 2>/dev/null || true)"
  if [[ -n "${resolved_ip}" ]]; then
    printf '%s\n' "${resolved_ip}"
    return 0
  fi

  resolved_ip="$(docker exec "${gateway_container}" sh -lc "awk 'index(\$1, \":\")==0 && \$2 == \"${alias}\" {print \$1; exit}' /etc/hosts 2>/dev/null" 2>/dev/null || true)"
  if [[ -n "${resolved_ip}" ]]; then
    printf '%s\n' "${resolved_ip}"
    return 0
  fi

  resolved_ip="$(docker exec "${gateway_container}" sh -lc "if command -v busybox >/dev/null 2>&1; then busybox nslookup '${alias}' 2>/dev/null | awk '/^Address: / && index(\$2, \":\")==0 {print \$2; exit}'; fi" 2>/dev/null || true)"
  if [[ -n "${resolved_ip}" ]]; then
    printf '%s\n' "${resolved_ip}"
    return 0
  fi

  return 1
}

resolve_gateway_host_ip() {
  local explicit_ip="$(local_gateway_host_ip)"
  local gateway_container=""
  local alias=""
  local resolved_ip=""

  if [[ -n "${explicit_ip}" ]]; then
    printf '%s\n' "${explicit_ip}"
    return 0
  fi

  gateway_container="$(gateway_container_name)"
  if ! gateway_container_running; then
    echo "OpenShell gateway container is not running: ${gateway_container}" >&2
    return 1
  fi

  while IFS= read -r alias; do
    [[ -n "${alias}" ]] || continue
    resolved_ip="$(resolve_gateway_alias_ipv4 "${gateway_container}" "${alias}" 2>/dev/null || true)"
    if [[ -n "${resolved_ip}" ]]; then
      printf '%s\n' "${resolved_ip}"
      return 0
    fi
  done < <(local_gateway_host_alias_candidates)

  resolved_ip="$(docker exec "${gateway_container}" sh -lc "if command -v ip >/dev/null 2>&1; then ip route show default | awk 'NR==1 {print \$3; exit}'; elif command -v route >/dev/null 2>&1; then route -n | awk '\$1 == \"0.0.0.0\" {print \$2; exit}'; fi" 2>/dev/null || true)"
  if [[ -n "${resolved_ip}" ]]; then
    printf '%s\n' "${resolved_ip}"
    return 0
  fi

  echo "Unable to resolve the host gateway IP from inside ${gateway_container}. Set LOCAL_GATEWAY_HOST_IP explicitly." >&2
  return 1
}

local_openai_relay_gateway_endpoint() {
  local host=""

  if gateway_container_running; then
    host="$(resolve_gateway_host_ip 2>/dev/null || true)"
  fi

  if [[ -z "${host}" ]]; then
    host="$(local_gateway_host_alias)"
  fi

  if [[ -z "${host}" ]]; then
    host="host.docker.internal"
  fi

  printf 'http://%s:%s/v1\n' "$(format_host_for_url "${host}")" "$(local_openai_relay_host_port)"
}

sandbox_ssh_host() {
  local sandbox_name="$1"
  printf 'openshell-%s\n' "${sandbox_name}"
}

write_sandbox_ssh_config() {
  local sandbox_name="$1"
  local config_file="$2"
  local openshell_bin=""

  openshell_bin="$(command -v openshell)"
  cat > "${config_file}" <<EOF
Host $(sandbox_ssh_host "${sandbox_name}")
    User sandbox
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /dev/null
    LogLevel ERROR
    ProxyCommand ${openshell_bin} ssh-proxy --gateway-name $(local_openshell_gateway_name) --name ${sandbox_name}
EOF
}

run_sandbox_script() {
  local sandbox_name="$1"
  local script_file="$2"
  local config_file=""
  local exit_code=0

  config_file="$(mktemp)"
  write_sandbox_ssh_config "${sandbox_name}" "${config_file}"
  if ssh -F "${config_file}" "$(sandbox_ssh_host "${sandbox_name}")" 'bash -s' < "${script_file}"; then
    exit_code=0
  else
    exit_code=$?
  fi
  rm -f "${config_file}"
  return "${exit_code}"
}

run_sandbox_kubectl_script() {
  local sandbox_name="$1"
  local script_file="$2"
  local gateway_container=""

  gateway_container="$(gateway_container_name)"
  docker exec -i "${gateway_container}" sh -lc "kubectl exec -i -n openshell ${sandbox_name} -- bash -s" < "${script_file}"
}

ensure_sandbox_python_otel_packages() {
  local sandbox_name="$1"
  local splunk_otel_python_version="$2"
  local extra_ca_b64="$3"
  local install_script=""
  local output=""

  install_script="$(mktemp)"
  cat > "${install_script}" <<EOF
set -euo pipefail

node_extra_certs_file="/etc/openshell-tls/openshell-ca.pem"
python_install_ca_file=""
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

python_install_ca_file="\${node_extra_certs_file}"
if [ -f "/etc/ssl/certs/ca-certificates.crt" ]; then
  cat /etc/ssl/certs/ca-certificates.crt "\${node_extra_certs_file}" > /tmp/openclaw-python-otel-install-ca.pem
  chmod 600 /tmp/openclaw-python-otel-install-ca.pem
  python_install_ca_file="/tmp/openclaw-python-otel-install-ca.pem"
fi

python_otel_packages_dir="/tmp/openclaw-python-otel/site-packages"
desired_python_otel_version="${splunk_otel_python_version}"
current_python_otel_version="\$(PYTHONPATH="\${python_otel_packages_dir}" python3 - <<'PY'
try:
    from splunk_otel.__about__ import __version__
except Exception:
    print("")
else:
    print(__version__)
PY
)"

if [ "\${current_python_otel_version}" != "\${desired_python_otel_version}" ]; then
  rm -rf "\${python_otel_packages_dir}"
  mkdir -p "\${python_otel_packages_dir}"
  env \\
    HTTP_PROXY="" \\
    HTTPS_PROXY="" \\
    ALL_PROXY="" \\
    http_proxy="" \\
    https_proxy="" \\
    all_proxy="" \\
    grpc_proxy="" \\
    NO_PROXY="" \\
    no_proxy="" \\
    PIP_CERT="\${python_install_ca_file}" \\
    python3 -m pip install --no-input --disable-pip-version-check --target "\${python_otel_packages_dir}" "splunk-opentelemetry==\${desired_python_otel_version}" >/tmp/openclaw-python-otel-install.log 2>&1 || {
      cat /tmp/openclaw-python-otel-install.log >&2
      exit 1
    }
fi

[ -e "\${python_otel_packages_dir}/splunk_otel/__init__.py" ] || {
  echo "Missing Python OTEL bootstrap at \${python_otel_packages_dir}/splunk_otel/__init__.py" >&2
  exit 1
}

echo "sandbox python otel ready"
EOF

  if output="$(run_sandbox_kubectl_script "${sandbox_name}" "${install_script}")"; then
    :
  else
    rm -f "${install_script}"
    return 1
  fi

  rm -f "${install_script}"
  printf '%s\n' "${output}"
}

write_sandbox_otel_restart_script() {
  local output_path="$1"
  local splunk_otel_js_version="$2"
  local splunk_otel_python_version="$3"
  local extra_ca_b64="$4"
  local deployment_environment="$5"
  local sandbox_name="$6"
  local collector_endpoint="$7"
  local python_sitecustomize_source="${SCRIPT_DIR}/python-sitecustomize.py"

  [[ -f "${python_sitecustomize_source}" ]] || {
    echo "Missing Python OTEL bootstrap source: ${python_sitecustomize_source}" >&2
    return 1
  }

  cat > "${output_path}" <<EOF
set -euo pipefail
command -v stty >/dev/null 2>&1 && stty -echo || true

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

export NPM_CONFIG_PREFIX="\$HOME/.npm-global"
mkdir -p "\${NPM_CONFIG_PREFIX}"

npm_root="\$(npm root -g)"
desired_otel_version="${splunk_otel_js_version}"
current_otel_version="\$(node -e 'try { process.stdout.write(require(process.argv[1]).version); } catch (error) { process.exit(1); }' "\${npm_root}/@splunk/otel/package.json" 2>/dev/null || true)"
if [ "\${current_otel_version}" != "\${desired_otel_version}" ]; then
  npm install -g "@splunk/otel@\${desired_otel_version}" >/tmp/otel-install.log 2>&1
fi

npm_root="\$(npm root -g)"
instrument_path="\${npm_root}/@splunk/otel/instrument.js"
if [ ! -e "\${instrument_path}" ]; then
  echo "Missing OTEL bootstrap at \${instrument_path}" >&2
  exit 1
fi

python_otel_root="/tmp/openclaw-python-otel"
python_otel_packages_dir="\${python_otel_root}/site-packages"
python_otel_bootstrap_dir="\${python_otel_root}/bootstrap"
python_otel_marker_file="/tmp/openclaw-python-otel.marker.log"
desired_python_otel_version="${splunk_otel_python_version}"
current_python_otel_version="\$(PYTHONPATH="\${python_otel_packages_dir}" python3 - <<'PY'
try:
    from splunk_otel.__about__ import __version__
except Exception:
    print("")
else:
    print(__version__)
PY
)"
if [ "\${current_python_otel_version}" != "\${desired_python_otel_version}" ] || [ ! -e "\${python_otel_packages_dir}/splunk_otel/__init__.py" ]; then
  echo "Python OTEL bootstrap version \${desired_python_otel_version} is not prepared in \${python_otel_packages_dir}" >&2
  exit 1
fi

mkdir -p "\${python_otel_bootstrap_dir}"
cat > "\${python_otel_bootstrap_dir}/sitecustomize.py" <<'PYOTEL'
EOF
  cat "${python_sitecustomize_source}" >> "${output_path}"
  cat >> "${output_path}" <<EOF
PYOTEL
chmod 0644 "\${python_otel_bootstrap_dir}/sitecustomize.py"
rm -f "\${python_otel_marker_file}"

gateway_pid="\$(ss -ltnp '( sport = :18789 )' 2>/dev/null | awk -F'pid=' 'NR>1 && NF>1 {split(\$2, parts, ","); print parts[1]; exit}')"
if [ -n "\${gateway_pid}" ]; then
  kill "\${gateway_pid}" >/dev/null 2>&1 || true
  sleep 2
fi

node_opts="--require \${instrument_path}"
if [ -n "${OPENCLAW_NODE_OPTIONS_BASE:-}" ]; then
  node_opts="${OPENCLAW_NODE_OPTIONS_BASE:-} \${node_opts}"
fi

python_path="\${python_otel_bootstrap_dir}:\${python_otel_packages_dir}"
if [ -n "\${PYTHONPATH:-}" ]; then
  python_path="\${python_path}:\${PYTHONPATH}"
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
  OPENCLAW_PYTHON_OTEL_BOOTSTRAP="1" \\
  OPENCLAW_PYTHON_OTEL_VERSION="\${desired_python_otel_version}" \\
  OPENCLAW_PYTHON_OTEL_MARKER_FILE="\${python_otel_marker_file}" \\
  NODE_EXTRA_CA_CERTS="\${node_extra_certs_file}" \\
  SSL_CERT_FILE="\${node_extra_certs_file}" \\
  REQUESTS_CA_BUNDLE="\${node_extra_certs_file}" \\
  CURL_CA_BUNDLE="\${node_extra_certs_file}" \\
  PIP_CERT="\${node_extra_certs_file}" \\
  PYTHONPATH="\${python_path}" \\
  NODE_OPTIONS="\${node_opts}" \\
  nemoclaw-start >/tmp/nemoclaw-otel-start.log 2>&1 &

sleep 4
ss -ltn '( sport = :18789 )' | grep -q ':18789'
echo "sandbox gateway restarted with OTEL"
EOF
}

set_openai_direct_inference_model() {
  local model="$1"
  local gateway_name="${2:-$(local_openshell_gateway_name)}"

  openshell inference set -g "${gateway_name}" --no-verify --provider openai-direct --model "${model}" >/dev/null
  openshell inference set -g "${gateway_name}" --system --no-verify --provider openai-direct --model "${model}" >/dev/null
}

run_openclaw_smoke_agent() {
  local sandbox_name="$1"
  local session_id="${2:-o11y-smoke}"
  local smoke_timeout="$(local_openai_smoke_timeout_seconds)"
  local smoke_script=""
  local smoke_output=""
  local exit_code=0

  smoke_script="$(mktemp)"
  cat > "${smoke_script}" <<EOF
set -euo pipefail
if command -v timeout >/dev/null 2>&1; then
  timeout "${smoke_timeout}" openclaw agent --agent main -m "reply with the single word ok" --session-id "${session_id}"
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout "${smoke_timeout}" openclaw agent --agent main -m "reply with the single word ok" --session-id "${session_id}"
else
  openclaw agent --agent main -m "reply with the single word ok" --session-id "${session_id}"
fi
EOF

  if smoke_output="$(run_sandbox_script "${sandbox_name}" "${smoke_script}")"; then
    exit_code=0
  else
    exit_code=$?
  fi

  rm -f "${smoke_script}"
  [[ "${exit_code}" -eq 0 ]] || return "${exit_code}"
  printf '%s\n' "${smoke_output}"
}

run_openclaw_smoke_agent_with_model() {
  local sandbox_name="$1"
  local smoke_model="$2"
  local restore_model="$3"
  local session_id="${4:-o11y-smoke}"
  local gateway_name="${5:-$(local_openshell_gateway_name)}"
  local smoke_output=""
  local restore_status_file=""
  local restore_status=""
  local exit_code=0

  restore_status_file="$(mktemp)"
  if smoke_output="$(
    (
      restore_gateway_model() {
        if set_openai_direct_inference_model "${restore_model}" "${gateway_name}" >/dev/null 2>&1; then
          printf '0\n' > "${restore_status_file}"
        else
          printf '%s\n' "$?" > "${restore_status_file}"
        fi
      }

      trap 'restore_gateway_model' EXIT INT TERM HUP
      set_openai_direct_inference_model "${smoke_model}" "${gateway_name}"
      run_openclaw_smoke_agent "${sandbox_name}" "${session_id}"
    )
  )"; then
    exit_code=0
  else
    exit_code=$?
  fi

  restore_status="$(cat "${restore_status_file}" 2>/dev/null || true)"
  rm -f "${restore_status_file}"
  if [[ -z "${restore_status}" || "${restore_status}" != "0" ]]; then
    echo "Failed to restore OpenShell inference model ${restore_model} after stub smoke." >&2
    return 1
  fi

  [[ "${exit_code}" -eq 0 ]] || return "${exit_code}"
  printf '%s\n' "${smoke_output}"
}

resolve_nemoclaw_repo_dir() {
  printf '%s\n' "${NEMOCLAW_REPO_DIR:-/tmp/NemoClaw}"
}

nemoclaw_repo_url() {
  printf '%s\n' "${NEMOCLAW_REPO_URL:-https://github.com/NVIDIA/NemoClaw.git}"
}

nemoclaw_ref() {
  printf '%s\n' "${NEMOCLAW_REF:-b36a673a3f031e490c5348a9061c8e34fa00d26a}"
}

verify_nemoclaw_repo_checkout() {
  local repo_dir="$1"
  local required_paths=(
    "bin/nemoclaw.js"
    "scripts/install-openshell.sh"
    "package.json"
  )
  local required_path=""

  for required_path in "${required_paths[@]}"; do
    if [[ ! -e "${repo_dir}/${required_path}" ]]; then
      echo "Pinned NemoClaw checkout is missing ${required_path}: ${repo_dir}" >&2
      return 1
    fi
  done
}

ensure_nemoclaw_repo_checkout() {
  local repo_dir="$(resolve_nemoclaw_repo_dir)"
  local repo_url="$(nemoclaw_repo_url)"
  local repo_ref="$(nemoclaw_ref)"
  local current_origin=""
  local target_rev=""

  if [[ ! -d "${repo_dir}/.git" ]]; then
    echo "Cloning NVIDIA NemoClaw into ${repo_dir}" >&2
    git clone --no-checkout "${repo_url}" "${repo_dir}" >/dev/null
  fi

  current_origin="$(git -C "${repo_dir}" remote get-url origin 2>/dev/null || true)"
  if [[ -n "${current_origin}" && "${current_origin}" != "${repo_url}" ]]; then
    echo "NEMOCLAW_REPO_DIR points at a different origin (${current_origin}). Expected ${repo_url}." >&2
    return 1
  fi

  if [[ "${repo_ref}" =~ ^[0-9a-f]{40}$ ]] && git -C "${repo_dir}" cat-file -e "${repo_ref}^{commit}" >/dev/null 2>&1; then
    target_rev="${repo_ref}"
  else
    git -C "${repo_dir}" fetch --depth 1 origin "${repo_ref}" >/dev/null
    target_rev="$(git -C "${repo_dir}" rev-parse FETCH_HEAD)"
  fi

  if [[ -z "${target_rev}" ]]; then
    target_rev="$(git -C "${repo_dir}" rev-parse "${repo_ref}^{commit}" 2>/dev/null || true)"
  fi

  [[ -n "${target_rev}" ]] || {
    echo "Unable to resolve NemoClaw ref: ${repo_ref}" >&2
    return 1
  }

  git -C "${repo_dir}" checkout --detach "${target_rev}" >/dev/null
  verify_nemoclaw_repo_checkout "${repo_dir}"
  printf '%s\n' "${repo_dir}"
}

checked_out_nemoclaw_rev() {
  local repo_dir="$1"
  git -C "${repo_dir}" rev-parse HEAD
}

resolve_host_extra_ca_pem() {
  local explicit_file="${LOCAL_EXTRA_CA_FILE:-}"
  local explicit_common_name="${LOCAL_EXTRA_CA_COMMON_NAME:-}"
  local keychains=(
    "/Library/Keychains/System.keychain"
    "${HOME}/Library/Keychains/login.keychain-db"
  )
  local common_names=()
  local keychain=""
  local common_name=""
  local output=""

  if [[ -n "${explicit_file}" ]]; then
    if [[ ! -f "${explicit_file}" ]]; then
      echo "LOCAL_EXTRA_CA_FILE does not exist: ${explicit_file}" >&2
      return 1
    fi
    cat "${explicit_file}"
    return 0
  fi

  if ! command -v security >/dev/null 2>&1; then
    return 1
  fi

  if [[ -n "${explicit_common_name}" ]]; then
    common_names+=("${explicit_common_name}")
  fi
  common_names+=("Cisco Secure Access Root CA")

  for common_name in "${common_names[@]}"; do
    for keychain in "${keychains[@]}"; do
      [[ -f "${keychain}" ]] || continue
      output="$(security find-certificate -a -c "${common_name}" -p "${keychain}" 2>/dev/null || true)"
      if [[ -n "${output}" ]]; then
        printf '%s\n' "${output}"
        return 0
      fi
    done
  done

  return 1
}
