#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env
require_tool docker
require_tool curl

print_host_endpoint="false"

log() {
  printf '%s\n' "$1" >&2
}

collector_ca_bundle_host_path() {
  printf '%s\n' "${LOCAL_OTEL_COLLECTOR_CA_BUNDLE_FILE:-/tmp/openclaw-local-otel-ca-certificates.crt}"
}

write_collector_ca_bundle() {
  local image="$1"
  local bundle_path="$2"
  local extra_ca_pem="$3"
  local base_bundle=""

  base_bundle="$(docker run --rm --entrypoint cat "${image}" /etc/ssl/certs/ca-certificates.crt)"
  [[ -n "${base_bundle}" ]] || {
    echo "Could not read the default CA bundle from ${image}." >&2
    return 1
  }

  {
    printf '%s\n' "${base_bundle}"
    printf '\n'
    printf '%s\n' "${extra_ca_pem}"
  } > "${bundle_path}"
  chmod 0644 "${bundle_path}"
}

collector_tls_ca_mode() {
  local container_name="$1"
  docker_container_env_value "${container_name}" "OPENCLAW_COLLECTOR_TLS_CA_MODE"
}

verify_collector_export_tls() {
  local container_name="$1"
  local realm="$2"
  local host="ingest.${realm}.signalfx.com"

  docker exec -i "${container_name}" \
    /usr/lib/splunk-otel-collector/agent-bundle/bin/python - "${host}" <<'PY' >/dev/null
import socket
import ssl
import sys

host = sys.argv[1]
socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
sock = socket.create_connection((host, 443), 10)
tls = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
tls.close()
PY
}

verify_repo_managed_collector_tls() {
  local container_name="$1"
  local realm="${SPLUNK_REALM:-}"

  [[ -n "${realm}" ]] || return 0
  if verify_collector_export_tls "${container_name}" "${realm}"; then
    log "Collector ${container_name} can verify TLS for ingest.${realm}.signalfx.com:443"
    return 0
  fi

  echo "Collector ${container_name} cannot verify TLS for ingest.${realm}.signalfx.com:443." >&2
  echo "If this machine sits behind TLS interception, set LOCAL_EXTRA_CA_FILE or LOCAL_EXTRA_CA_COMMON_NAME so the repo-managed collector can trust the intercepting CA." >&2
  return 1
}

container_network_names() {
  local container_name="$1"
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${container_name}" 2>/dev/null || true
}

container_has_network() {
  local container_name="$1"
  local network_name="$2"

  [[ -n "${network_name}" ]] || return 1
  container_network_names "${container_name}" | grep -qx "${network_name}"
}

primary_container_network() {
  local container_name="$1"
  container_network_names "${container_name}" | awk 'NF { print; exit }'
}

agent_sandbox_controller_service_exists() {
  local gateway_container="$1"
  local namespace="$(local_agent_sandbox_namespace)"
  local service_name="$(local_agent_sandbox_controller_service_name)"

  docker exec "${gateway_container}" sh -lc "kubectl get svc ${service_name} -n ${namespace} >/dev/null 2>&1"
}

agent_sandbox_metrics_bridge_url() {
  printf 'http://127.0.0.1:%s/metrics\n' "$(local_agent_sandbox_metrics_bridge_port)"
}

ensure_agent_sandbox_metrics_bridge() {
  local gateway_container="$1"
  local namespace="$(local_agent_sandbox_namespace)"
  local service_name="$(local_agent_sandbox_controller_service_name)"
  local bridge_port="$(local_agent_sandbox_metrics_bridge_port)"
  local bridge_url=""

  bridge_url="$(agent_sandbox_metrics_bridge_url)"
  if docker exec "${gateway_container}" sh -lc "wget -qO- --timeout=5 '${bridge_url}' >/dev/null 2>&1"; then
    return 0
  fi

  agent_sandbox_controller_service_exists "${gateway_container}" || return 1

  docker exec "${gateway_container}" sh -lc "(kubectl port-forward --address 0.0.0.0 -n ${namespace} svc/${service_name} ${bridge_port}:80 >/tmp/agent-sandbox-metrics-port-forward.log 2>&1 &)" >/dev/null

  for _ in {1..30}; do
    if docker exec "${gateway_container}" sh -lc "wget -qO- --timeout=5 '${bridge_url}' >/dev/null 2>&1"; then
      return 0
    fi
    sleep 2
  done

  echo "Agent-sandbox metrics bridge did not become reachable on ${gateway_container}:${bridge_port}." >&2
  docker exec "${gateway_container}" sh -lc "tail -n 50 /tmp/agent-sandbox-metrics-port-forward.log" >&2 || true
  return 1
}

ensure_collector_on_gateway_network() {
  local collector_name="$1"
  local gateway_container="$2"
  local gateway_network=""

  gateway_network="$(primary_container_network "${gateway_container}")"
  [[ -n "${gateway_network}" ]] || {
    echo "Could not determine the Docker network for ${gateway_container}." >&2
    return 1
  }

  if container_has_network "${collector_name}" "${gateway_network}"; then
    return 0
  fi

  docker network connect "${gateway_network}" "${collector_name}" >/dev/null
}

verify_collector_http_probe() {
  local container_name="$1"
  local url="$2"
  local required_metric="$3"

  docker exec -i "${container_name}" \
    /usr/lib/splunk-otel-collector/agent-bundle/bin/python - "${url}" "${required_metric}" <<'PY' >/dev/null
import sys
import urllib.request

url = sys.argv[1]
required_metric = sys.argv[2]

with urllib.request.urlopen(url, timeout=10) as response:
    body = response.read().decode("utf-8", "replace")

if response.status != 200:
    raise SystemExit(f"unexpected status {response.status} from {url}")
if required_metric not in body:
    raise SystemExit(f"missing metric {required_metric} in {url}")
PY
}

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
image="$(local_otel_collector_image)"
extra_ca_pem="$(resolve_host_extra_ca_pem || true)"
collector_ca_bundle_host_file=""
collector_tls_ca_mode="system-default"
gateway_container="$(gateway_container_name)"
agent_sandbox_metrics_target=""
agent_sandbox_metrics_enabled="false"

if [[ -n "${extra_ca_pem}" ]]; then
  collector_ca_bundle_host_file="$(collector_ca_bundle_host_path)"
  write_collector_ca_bundle "${image}" "${collector_ca_bundle_host_file}" "${extra_ca_pem}"
  collector_tls_ca_mode="system-plus-extra"
fi

if gateway_container_running && agent_sandbox_controller_service_exists "${gateway_container}"; then
  ensure_agent_sandbox_metrics_bridge "${gateway_container}" || exit 1
  agent_sandbox_metrics_target="$(local_agent_sandbox_metrics_target)"
  agent_sandbox_metrics_enabled="true"
fi

if collector_info="$(find_local_otel_collector "${port}")"; then
  collector_name="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $1}')"
  collector_image="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $2}')"
  recreate_repo_managed_collector="false"

  if ! local_otel_collector_supports_traces "${collector_name}"; then
    echo "Container ${collector_name} exposes host port ${port}, but its collector config does not include a traces pipeline." >&2
    echo "This repo needs an OTLP trace-capable collector for the local NemoClaw/OpenShell flow." >&2
    echo "Stop that container, choose a different LOCAL_OTEL_COLLECTOR_HOST_PORT, or point the repo at a compatible collector." >&2
    exit 1
  fi

  if [[ "${collector_name}" == "${name}" ]]; then
    if [[ "${collector_tls_ca_mode}" == "system-plus-extra" && ( "$(collector_tls_ca_mode "${collector_name}")" != "system-plus-extra" || "$(docker_container_env_value "${collector_name}" "SSL_CERT_FILE")" != "/etc/ssl/certs/ca-certificates.crt" ) ]]; then
      log "Recreating ${collector_name} so the repo-managed collector trusts the configured extra CA"
      recreate_repo_managed_collector="true"
    fi

    if [[ "${agent_sandbox_metrics_enabled}" == "true" ]]; then
      ensure_collector_on_gateway_network "${collector_name}" "${gateway_container}" || exit 1

      if [[ "$(docker_container_env_value "${collector_name}" "OPENCLAW_AGENT_SANDBOX_METRICS_TARGET")" != "${agent_sandbox_metrics_target}" ]]; then
        log "Recreating ${collector_name} so it scrapes agent-sandbox-controller metrics from ${agent_sandbox_metrics_target}"
        recreate_repo_managed_collector="true"
      fi

      if ! local_otel_collector_supports_metrics "${collector_name}" || ! local_otel_collector_supports_agent_sandbox_metrics "${collector_name}" "${agent_sandbox_metrics_target}"; then
        log "Recreating ${collector_name} so it exposes an agent-sandbox metrics pipeline"
        recreate_repo_managed_collector="true"
      fi
    fi
  elif [[ "${agent_sandbox_metrics_enabled}" == "true" ]]; then
    if ! local_otel_collector_supports_agent_sandbox_metrics "${collector_name}" "${agent_sandbox_metrics_target}"; then
      echo "Collector ${collector_name} exposes host port ${port}, but it is not configured to scrape agent-sandbox-controller metrics from ${agent_sandbox_metrics_target}." >&2
      echo "Use the repo-managed collector, point this repo at a collector that already scrapes those metrics, or choose a different LOCAL_OTEL_COLLECTOR_HOST_PORT." >&2
      exit 1
    fi
  fi

  if [[ "${recreate_repo_managed_collector}" == "true" ]]; then
    docker rm -f "${collector_name}" >/dev/null
  else
    if [[ "${collector_name}" == "${name}" ]]; then
      verify_repo_managed_collector_tls "${collector_name}" || exit 1
      if [[ "${agent_sandbox_metrics_enabled}" == "true" ]]; then
        verify_collector_http_probe "${collector_name}" "http://${agent_sandbox_metrics_target}/metrics" "controller_runtime_reconcile_total" || {
          echo "Collector ${collector_name} cannot reach agent-sandbox-controller metrics at http://${agent_sandbox_metrics_target}/metrics." >&2
          exit 1
        }
      fi
    fi

    if [[ "${print_host_endpoint}" == "true" ]]; then
      local_collector_host_endpoint
      exit 0
    fi

    log "Reusing local OTEL collector container: ${collector_name}"
    log "Image: ${collector_image}"
    log "Host OTLP endpoint: $(local_collector_host_endpoint)"
    exit 0
  fi
fi

require_env SPLUNK_REALM
require_env SPLUNK_ACCESS_TOKEN

if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
  log "Removing stopped collector container with reserved name: ${name}"
  docker rm -f "${name}" >/dev/null
fi

metrics_receiver_config=""
metrics_processor_config=""
metrics_pipeline_config=""
if [[ "${agent_sandbox_metrics_enabled}" == "true" ]]; then
  metrics_receiver_config="$(cat <<'YAML'
  prometheus/agent_sandbox_controller:
    config:
      global:
        scrape_interval: 30s
        scrape_timeout: 10s
      scrape_configs:
        - job_name: agent-sandbox-controller
          metrics_path: /metrics
          static_configs:
            - targets:
                - "${OPENCLAW_AGENT_SANDBOX_METRICS_TARGET}"
YAML
)"
  metrics_processor_config="$(cat <<'YAML'
  resource/agent_sandbox_controller:
    attributes:
      - key: service.name
        value: ${OPENCLAW_AGENT_SANDBOX_METRICS_SERVICE_NAME}
        action: upsert
      - key: deployment.environment
        value: ${OPENCLAW_DEPLOYMENT_ENVIRONMENT}
        action: upsert
      - key: k8s.namespace.name
        value: ${OPENCLAW_AGENT_SANDBOX_NAMESPACE}
        action: upsert
      - key: openshell.gateway.name
        value: ${OPENCLAW_OPENSHELL_GATEWAY_NAME}
        action: upsert
YAML
)"
  metrics_pipeline_config="$(cat <<'YAML'
    metrics/agent_sandbox_controller:
      receivers: [prometheus/agent_sandbox_controller]
      processors: [resource/agent_sandbox_controller, batch]
      exporters: [otlp]
YAML
)"
fi

collector_config="$(cat <<YAML
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
${metrics_receiver_config}

processors:
  batch:
${metrics_processor_config}

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
${metrics_pipeline_config}
YAML
)"

log "Starting local OTEL collector container: ${name}"
docker_run_args=(
  -d
  --name "${name}" \
  --restart unless-stopped \
  -p "${port}:4318" \
  -p "${grpc_port}:4317" \
  -p "${health_port}:13133" \
  -e SPLUNK_REALM="${SPLUNK_REALM}" \
  -e SPLUNK_ACCESS_TOKEN="${SPLUNK_ACCESS_TOKEN}" \
  -e SPLUNK_CONFIG_YAML="${collector_config}" \
  -e OPENCLAW_COLLECTOR_TLS_CA_MODE="${collector_tls_ca_mode}" \
  -e OPENCLAW_DEPLOYMENT_ENVIRONMENT="$(local_deployment_environment)" \
  -e OPENCLAW_OPENSHELL_GATEWAY_NAME="$(local_openshell_gateway_name)" \
  -e OPENCLAW_AGENT_SANDBOX_NAMESPACE="$(local_agent_sandbox_namespace)" \
  -e OPENCLAW_AGENT_SANDBOX_METRICS_SERVICE_NAME="$(local_agent_sandbox_metrics_service_name)" \
  -e OPENCLAW_AGENT_SANDBOX_METRICS_TARGET="${agent_sandbox_metrics_target}" \
  -e SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
  -e SSL_CERT_DIR="/etc/ssl/certs"
)

if [[ -n "${collector_ca_bundle_host_file}" ]]; then
  docker_run_args+=(
    -v "${collector_ca_bundle_host_file}:/etc/ssl/certs/ca-certificates.crt:ro"
  )
fi

docker run "${docker_run_args[@]}" "${image}" >/dev/null

if [[ "${agent_sandbox_metrics_enabled}" == "true" ]]; then
  ensure_collector_on_gateway_network "${name}" "${gateway_container}" || exit 1
fi

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${health_port}/" >/dev/null 2>&1; then
    verify_repo_managed_collector_tls "${name}" || exit 1
    if [[ "${agent_sandbox_metrics_enabled}" == "true" ]]; then
      verify_collector_http_probe "${name}" "http://${agent_sandbox_metrics_target}/metrics" "controller_runtime_reconcile_total" || {
        echo "Collector ${name} could not scrape agent-sandbox-controller metrics from http://${agent_sandbox_metrics_target}/metrics." >&2
        exit 1
      }
    fi

    if [[ "${print_host_endpoint}" == "true" ]]; then
      local_collector_host_endpoint
      exit 0
    fi

    log "Started local OTEL collector container: ${name}"
    log "Host OTLP endpoint: $(local_collector_host_endpoint)"
    exit 0
  fi
  sleep 2
done

echo "Collector container did not become healthy on port ${health_port}." >&2
docker logs "${name}" --tail 50 >&2 || true
exit 1
