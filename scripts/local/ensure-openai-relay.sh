#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env

require_tool node
require_tool npm
require_tool curl
require_tool lsof

print_endpoint="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-endpoint)
      print_endpoint="true"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: scripts/local/ensure-openai-relay.sh [--print-endpoint]" >&2
      exit 1
      ;;
  esac
done

relay_port="$(local_openai_relay_host_port)"
relay_health_url="http://127.0.0.1:${relay_port}/healthz"
relay_log_file="/tmp/openclaw-openai-relay.log"
relay_pid_file="/tmp/openclaw-openai-relay.pid"
relay_smoke_stub_model="$(local_openai_smoke_stub_model)"
relay_service_name="$(local_openai_relay_service_name)"
deployment_environment="$(local_deployment_environment)"
collector_host_endpoint="$("${SCRIPT_DIR}/ensure-collector.sh" --print-host-endpoint)"
relay_ca_file="/tmp/openclaw-openai-relay-extra-ca.pem"

ensure_host_splunk_otel_js() {
  export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
  mkdir -p "${NPM_CONFIG_PREFIX}"

  local npm_root=""
  local desired_otel_version=""
  local current_otel_version=""
  local instrument_path=""

  npm_root="$(npm root -g)"
  desired_otel_version="$(local_splunk_otel_js_version)"
  current_otel_version="$(node -e 'try { process.stdout.write(require(process.argv[1]).version); } catch (error) { process.exit(1); }' "${npm_root}/@splunk/otel/package.json" 2>/dev/null || true)"
  if [[ "${current_otel_version}" != "${desired_otel_version}" ]]; then
    npm install -g "@splunk/otel@${desired_otel_version}" >/tmp/openclaw-host-otel-install.log 2>&1
    npm_root="$(npm root -g)"
  fi

  instrument_path="${npm_root}/@splunk/otel/instrument.js"
  [[ -e "${instrument_path}" ]] || {
    echo "Missing OTEL bootstrap at ${instrument_path}" >&2
    exit 1
  }

  printf '%s\n' "${instrument_path}"
}

relay_pid_command() {
  local relay_pid="$1"
  ps -o command= -p "${relay_pid}" 2>/dev/null || true
}

relay_pid_matches() {
  local relay_pid="$1"
  local command=""

  command="$(relay_pid_command "${relay_pid}")"
  [[ -n "${command}" && "${command}" == *"openai-relay.js"* ]]
}

listening_pid_on_relay_port() {
  lsof -ti tcp:"${relay_port}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

stop_relay() {
  local relay_pid=""
  local relay_command=""

  if [[ -f "${relay_pid_file}" ]]; then
    relay_pid="$(cat "${relay_pid_file}" 2>/dev/null || true)"
  fi

  if [[ -n "${relay_pid}" ]]; then
    relay_command="$(relay_pid_command "${relay_pid}")"
    if [[ -z "${relay_command}" ]]; then
      relay_pid=""
    fi
  fi

  if [[ -z "${relay_pid}" ]]; then
    relay_pid="$(listening_pid_on_relay_port)"
    relay_command="$(relay_pid_command "${relay_pid}")"
  fi

  if [[ -n "${relay_pid}" ]]; then
    if [[ -z "${relay_command}" ]]; then
      relay_command="$(relay_pid_command "${relay_pid}")"
    fi
    if ! relay_pid_matches "${relay_pid}"; then
      echo "Port ${relay_port} is listening with a different process: ${relay_command}" >&2
      return 1
    fi
    kill "${relay_pid}" >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! listening_pid_on_relay_port >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi

  rm -f "${relay_pid_file}"
}

start_relay() {
  local instrument_path=""
  local extra_ca_pem=""
  local listening_pid=""
  local -a relay_env=()
  instrument_path="$(ensure_host_splunk_otel_js)"
  extra_ca_pem="$(resolve_host_extra_ca_pem || true)"

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo "Starting local OpenAI relay on port ${relay_port}" >&2
  else
    echo "Starting local OpenAI relay on port ${relay_port} without a default OpenAI API key; stub traffic and caller-supplied Authorization headers will still work" >&2
  fi

  rm -f "${relay_ca_file}"
  if [[ -n "${extra_ca_pem}" ]]; then
    printf '%s\n' "${extra_ca_pem}" > "${relay_ca_file}"
    chmod 0600 "${relay_ca_file}"
    relay_env+=(
      NODE_EXTRA_CA_CERTS="${relay_ca_file}"
      SSL_CERT_FILE="${relay_ca_file}"
    )
  fi

  relay_env+=(
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    LOCAL_OPENAI_RELAY_PORT="${relay_port}" \
    LOCAL_OPENAI_SMOKE_STUB_MODEL="${relay_smoke_stub_model}" \
    OPENCLAW_DEPLOYMENT_ENVIRONMENT="${deployment_environment}" \
    OTEL_SERVICE_NAME="${relay_service_name}" \
    OTEL_RESOURCE_ATTRIBUTES="deployment.environment=${deployment_environment},demo.runtime=nemoclaw-local,service.component=openai-relay" \
    OTEL_TRACES_EXPORTER="otlp" \
    OTEL_METRICS_EXPORTER="none" \
    OTEL_LOGS_EXPORTER="none" \
    OTEL_EXPORTER_OTLP_ENDPOINT="${collector_host_endpoint}" \
    OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf" \
    OTEL_PROPAGATORS="tracecontext,baggage" \
    SPLUNK_TRACE_RESPONSE_HEADER_ENABLED="false" \
    NODE_OPTIONS="--require ${instrument_path}" \
  )

  listening_pid="$(listening_pid_on_relay_port)"
  if [[ -n "${listening_pid}" ]]; then
    if relay_pid_matches "${listening_pid}"; then
      stop_relay || exit 1
    else
      echo "Port ${relay_port} is already in use by a different process: $(relay_pid_command "${listening_pid}")" >&2
      exit 1
    fi
  fi

  nohup env \
    "${relay_env[@]}" \
    node "${SCRIPT_DIR}/openai-relay.js" >"${relay_log_file}" 2>&1 &
  relay_pid=$!
  printf '%s\n' "${relay_pid}" > "${relay_pid_file}"

  for _ in {1..20}; do
    if curl -fsS "${relay_health_url}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! curl -fsS "${relay_health_url}" >/dev/null 2>&1; then
    echo "Local OpenAI relay failed to become healthy. See ${relay_log_file}" >&2
    exit 1
  fi
}

relay_health_json="$(curl -fsS "${relay_health_url}" 2>/dev/null || true)"

if [[ -n "${relay_health_json}" ]]; then
  if ! printf '%s\n' "${relay_health_json}" | grep -Fq '"relayVersion":4'; then
    echo "Restarting local OpenAI relay to pick up the current relay implementation" >&2
    stop_relay || exit 1
    relay_health_json=""
  elif ! printf '%s\n' "${relay_health_json}" | grep -Fq "\"smokeStubModel\":\"${relay_smoke_stub_model}\""; then
    echo "Restarting local OpenAI relay to apply the configured smoke stub model" >&2
    stop_relay || exit 1
    relay_health_json=""
  elif ! printf '%s\n' "${relay_health_json}" | grep -Fq "\"otelServiceName\":\"${relay_service_name}\""; then
    echo "Restarting local OpenAI relay to apply the configured OTEL service name" >&2
    stop_relay || exit 1
    relay_health_json=""
  elif ! printf '%s\n' "${relay_health_json}" | grep -Fq "\"otelExporterEndpoint\":\"${collector_host_endpoint}\""; then
    echo "Restarting local OpenAI relay to apply the configured OTEL exporter endpoint" >&2
    stop_relay || exit 1
    relay_health_json=""
  elif ! printf '%s\n' "${relay_health_json}" | grep -Fq "\"deploymentEnvironment\":\"${deployment_environment}\""; then
    echo "Restarting local OpenAI relay to apply the configured deployment environment" >&2
    stop_relay || exit 1
    relay_health_json=""
  fi
fi

if [[ -z "${relay_health_json}" ]]; then
  start_relay
fi

if [[ "${print_endpoint}" == "true" ]]; then
  local_openai_relay_gateway_endpoint
fi
