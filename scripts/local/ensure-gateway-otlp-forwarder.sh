#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env

require_tool docker

print_only="false"
print_cluster_ip_only="false"

forwarder_ready_replicas() {
  local gateway_container="$1"
  local forwarder_name="$2"
  local forwarder_namespace="$3"

  docker exec "${gateway_container}" sh -lc \
    "kubectl get deploy ${forwarder_name} -n ${forwarder_namespace} -o jsonpath='{.status.readyReplicas}'" 2>/dev/null || true
}

forwarder_cluster_ip() {
  local gateway_container="$1"
  local forwarder_name="$2"
  local forwarder_namespace="$3"

  docker exec "${gateway_container}" sh -lc \
    "kubectl get svc ${forwarder_name} -n ${forwarder_namespace} -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-endpoint)
      print_only="true"
      shift
      ;;
    --print-cluster-ip)
      print_cluster_ip_only="true"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: scripts/local/ensure-gateway-otlp-forwarder.sh [--print-endpoint] [--print-cluster-ip]" >&2
      exit 1
      ;;
  esac
done

"${SCRIPT_DIR}/ensure-collector.sh" >/dev/null

gateway_container="$(gateway_container_name)"
if ! gateway_container_running; then
  echo "OpenShell gateway container is not running: ${gateway_container}" >&2
  exit 1
fi

forwarder_name="$(local_gateway_otel_forwarder_name)"
forwarder_namespace="$(local_gateway_otel_forwarder_namespace)"
forwarder_http_port="$(local_gateway_otel_forwarder_http_port)"
forwarder_host_port="$(local_gateway_otel_forwarder_host_port)"
forwarder_health_port="$(local_gateway_otel_forwarder_health_port)"
forwarder_image="$(local_gateway_otel_forwarder_image)"
forwarder_target_endpoint="http://$(format_host_for_url "$(resolve_gateway_host_ip)")":$(local_collector_host_port)
forwarder_endpoint="$(local_gateway_otel_forwarder_endpoint)"
existing_forwarder_cluster_ip="$(forwarder_cluster_ip "${gateway_container}" "${forwarder_name}" "${forwarder_namespace}")"
existing_forwarder_ready="$(forwarder_ready_replicas "${gateway_container}" "${forwarder_name}" "${forwarder_namespace}")"

if [[ ("${print_only}" == "true" || "${print_cluster_ip_only}" == "true") && -n "${existing_forwarder_cluster_ip}" && "${existing_forwarder_cluster_ip}" != "None" && -n "${existing_forwarder_ready}" && "${existing_forwarder_ready}" != "0" ]]; then
  if [[ "${print_only}" == "true" ]]; then
    printf '%s\n' "${forwarder_endpoint}"
    exit 0
  fi

  printf '%s\n' "${existing_forwarder_cluster_ip}"
  exit 0
fi

manifest_file="$(mktemp)"
sed \
  -e "s#__LOCAL_OTEL_FORWARDER_NAME__#${forwarder_name}#g" \
  -e "s#__LOCAL_OTEL_FORWARDER_NAMESPACE__#${forwarder_namespace}#g" \
  -e "s#__LOCAL_OTEL_FORWARDER_IMAGE__#${forwarder_image}#g" \
  -e "s#__LOCAL_OTEL_FORWARDER_HTTP_PORT__#${forwarder_http_port}#g" \
  -e "s#__LOCAL_OTEL_FORWARDER_HOST_PORT__#${forwarder_host_port}#g" \
  -e "s#__LOCAL_OTEL_FORWARDER_HEALTH_PORT__#${forwarder_health_port}#g" \
  -e "s#__LOCAL_OTEL_FORWARDER_TARGET_ENDPOINT__#${forwarder_target_endpoint}#g" \
  "${SCRIPT_DIR}/manifests/gateway-otlp-forwarder.yaml" > "${manifest_file}"

docker exec -i "${gateway_container}" sh -lc 'kubectl apply -f -' < "${manifest_file}" >/dev/null
rm -f "${manifest_file}"

docker exec "${gateway_container}" sh -lc \
  "kubectl rollout status deployment/${forwarder_name} -n ${forwarder_namespace} --timeout=120s" >/dev/null

forwarder_cluster_ip="$(forwarder_cluster_ip "${gateway_container}" "${forwarder_name}" "${forwarder_namespace}")"
if [[ -z "${forwarder_cluster_ip}" || "${forwarder_cluster_ip}" == "None" ]]; then
  echo "Failed to resolve ClusterIP for forwarder service ${forwarder_name}." >&2
  exit 1
fi

if [[ "${print_only}" == "true" ]]; then
  printf '%s\n' "${forwarder_endpoint}"
  exit 0
fi

if [[ "${print_cluster_ip_only}" == "true" ]]; then
  printf '%s\n' "${forwarder_cluster_ip}"
  exit 0
fi

echo "In-gateway OTLP forwarder: ${forwarder_name}"
echo "Namespace: ${forwarder_namespace}"
echo "Sandbox OTLP endpoint: ${forwarder_endpoint}"
echo "Sandbox OTLP ClusterIP service: http://${forwarder_cluster_ip}:${forwarder_http_port}"
echo "Sandbox OTLP service DNS: $(local_gateway_otel_forwarder_service_fqdn)"
echo "Forwarder target endpoint: ${forwarder_target_endpoint}"
