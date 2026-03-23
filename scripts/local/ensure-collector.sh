#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env
require_tool docker
require_tool curl

print_host_endpoint="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-endpoint|--print-host-endpoint)
      print_host_endpoint="true"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: scripts/local/ensure-collector.sh [--print-host-endpoint]" >&2
      exit 1
      ;;
  esac
done

port="$(local_collector_host_port)"
grpc_port="${LOCAL_OTEL_COLLECTOR_GRPC_PORT:-4317}"
health_port="${LOCAL_OTEL_COLLECTOR_HEALTH_PORT:-13133}"
name="${LOCAL_OTEL_COLLECTOR_CONTAINER_NAME:-openclaw-local-otel-collector}"
image="${LOCAL_OTEL_COLLECTOR_IMAGE:-quay.io/signalfx/splunk-otel-collector:latest}"

if collector_info="$(find_local_otel_collector "${port}")"; then
  if [[ "${print_host_endpoint}" == "true" ]]; then
    local_collector_host_endpoint
    exit 0
  fi

  collector_name="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $1}')"
  collector_image="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $2}')"
  echo "Reusing local OTEL collector container: ${collector_name}"
  echo "Image: ${collector_image}"
  echo "Host OTLP endpoint: $(local_collector_host_endpoint)"
  exit 0
fi

require_env SPLUNK_REALM
require_env SPLUNK_ACCESS_TOKEN

if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
  echo "Removing stopped collector container with reserved name: ${name}"
  docker rm -f "${name}" >/dev/null
fi

collector_config="$(cat <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:

exporters:
  otlp:
    endpoint: ingest.${SPLUNK_REALM}.signalfx.com:443
    headers:
      X-SF-Token: ${SPLUNK_ACCESS_TOKEN}

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp]
YAML
)"

echo "Starting local OTEL collector container: ${name}"
docker run -d \
  --name "${name}" \
  --restart unless-stopped \
  -p "${port}:4318" \
  -p "${grpc_port}:4317" \
  -p "${health_port}:13133" \
  -e SPLUNK_REALM="${SPLUNK_REALM}" \
  -e SPLUNK_ACCESS_TOKEN="${SPLUNK_ACCESS_TOKEN}" \
  -e SPLUNK_CONFIG_YAML="${collector_config}" \
  "${image}" >/dev/null

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${health_port}/" >/dev/null 2>&1; then
    if [[ "${print_host_endpoint}" == "true" ]]; then
      local_collector_host_endpoint
      exit 0
    fi

    echo "Started local OTEL collector container: ${name}"
    echo "Host OTLP endpoint: $(local_collector_host_endpoint)"
    exit 0
  fi
  sleep 2
done

echo "Collector container did not become healthy on port ${health_port}." >&2
docker logs "${name}" --tail 50 >&2 || true
exit 1
