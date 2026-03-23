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
  docker inspect "${container_name}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
    awk -F= '$1 == "OPENCLAW_COLLECTOR_TLS_CA_MODE" {print $2; exit}'
}

collector_env_value() {
  local container_name="$1"
  local env_name="$2"
  docker inspect "${container_name}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
    awk -F= -v env_name="${env_name}" '$1 == env_name {print substr($0, index($0, "=") + 1); exit}'
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

if [[ -n "${extra_ca_pem}" ]]; then
  collector_ca_bundle_host_file="$(collector_ca_bundle_host_path)"
  write_collector_ca_bundle "${image}" "${collector_ca_bundle_host_file}" "${extra_ca_pem}"
  collector_tls_ca_mode="system-plus-extra"
fi

if collector_info="$(find_local_otel_collector "${port}")"; then
  collector_name="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $1}')"
  collector_image="$(printf '%s\n' "${collector_info}" | awk -F'\t' '{print $2}')"

  if ! local_otel_collector_supports_traces "${collector_name}"; then
    echo "Container ${collector_name} exposes host port ${port}, but its collector config does not include a traces pipeline." >&2
    echo "This repo needs an OTLP trace-capable collector for the local NemoClaw/OpenShell flow." >&2
    echo "Stop that container, choose a different LOCAL_OTEL_COLLECTOR_HOST_PORT, or point the repo at a compatible collector." >&2
    exit 1
  fi

  if [[ "${collector_name}" == "${name}" && "${collector_tls_ca_mode}" == "system-plus-extra" && ( "$(collector_tls_ca_mode "${collector_name}")" != "system-plus-extra" || "$(collector_env_value "${collector_name}" "SSL_CERT_FILE")" != "/etc/ssl/certs/ca-certificates.crt" ) ]]; then
    log "Recreating ${collector_name} so the repo-managed collector trusts the configured extra CA"
    docker rm -f "${collector_name}" >/dev/null
  else
    if [[ "${collector_name}" == "${name}" ]]; then
      verify_repo_managed_collector_tls "${collector_name}" || exit 1
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
  -e SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
  -e SSL_CERT_DIR="/etc/ssl/certs"
)

if [[ -n "${collector_ca_bundle_host_file}" ]]; then
  docker_run_args+=(
    -v "${collector_ca_bundle_host_file}:/etc/ssl/certs/ca-certificates.crt:ro"
  )
fi

docker run "${docker_run_args[@]}" "${image}" >/dev/null

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${health_port}/" >/dev/null 2>&1; then
    verify_repo_managed_collector_tls "${name}" || exit 1

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
