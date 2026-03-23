#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env

require_tool node
require_tool curl
require_env OPENAI_API_KEY

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

if ! curl -fsS "${relay_health_url}" >/dev/null 2>&1; then
  echo "Starting local OpenAI relay on port ${relay_port}" >&2
  nohup env \
    OPENAI_API_KEY="${OPENAI_API_KEY}" \
    LOCAL_OPENAI_RELAY_PORT="${relay_port}" \
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
fi

if [[ "${print_endpoint}" == "true" ]]; then
  local_openai_relay_gateway_endpoint
fi
