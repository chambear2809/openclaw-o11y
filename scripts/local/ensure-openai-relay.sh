#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env

require_tool node
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

stop_relay() {
  local relay_pid=""

  if [[ -f "${relay_pid_file}" ]]; then
    relay_pid="$(cat "${relay_pid_file}" 2>/dev/null || true)"
  fi

  if [[ -z "${relay_pid}" ]]; then
    relay_pid="$(lsof -ti tcp:"${relay_port}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "${relay_pid}" ]]; then
    kill "${relay_pid}" >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! lsof -ti tcp:"${relay_port}" -sTCP:LISTEN >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi

  rm -f "${relay_pid_file}"
}

start_relay() {
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo "Starting local OpenAI relay on port ${relay_port}" >&2
  else
    echo "Starting local OpenAI relay on port ${relay_port} without a default OpenAI API key; stub traffic and caller-supplied Authorization headers will still work" >&2
  fi
  nohup env \
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    LOCAL_OPENAI_RELAY_PORT="${relay_port}" \
    LOCAL_OPENAI_SMOKE_STUB_MODEL="${relay_smoke_stub_model}" \
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
  if ! printf '%s\n' "${relay_health_json}" | grep -Fq '"relayVersion":3'; then
    echo "Restarting local OpenAI relay to pick up the current relay implementation" >&2
    stop_relay
    relay_health_json=""
  elif ! printf '%s\n' "${relay_health_json}" | grep -Fq "\"smokeStubModel\":\"${relay_smoke_stub_model}\""; then
    echo "Restarting local OpenAI relay to apply the configured smoke stub model" >&2
    stop_relay
    relay_health_json=""
  fi
fi

if [[ -z "${relay_health_json}" ]]; then
  start_relay
fi

if [[ "${print_endpoint}" == "true" ]]; then
  local_openai_relay_gateway_endpoint
fi
