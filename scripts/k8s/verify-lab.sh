#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_lab_env

OPENCLAW_NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
OPENCLAW_DEPLOYMENT_NAME="${OPENCLAW_DEPLOYMENT_NAME:-openclaw}"
OPENCLAW_CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-openclaw}"
OPENCLAW_DEPLOYMENT_ENVIRONMENT="${OPENCLAW_DEPLOYMENT_ENVIRONMENT:-Openclaw}"
STRICT_GATEWAY=false
SMOKE_GATEWAY=false

usage() {
  cat <<'EOF'
Usage: verify-lab.sh [--strict-gateway] [--smoke-gateway]

Checks:
  - OpenClaw deployment exists
  - Pod template has the Node.js instrumentation annotation
  - A running pod was mutated with the auto-instrumentation init container
  - Runtime env contains OTEL exporter settings and deployment.environment
  - Optional: gateway is listening on port 18789 inside the pod
  - Optional: gateway serves an authenticated localhost HTTP request inside the pod
EOF
}

ok() {
  printf '[ok] %s\n' "$1"
}

warn() {
  printf '[warn] %s\n' "$1"
}

fail() {
  printf '[fail] %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict-gateway)
      STRICT_GATEWAY=true
      ;;
    --smoke-gateway)
      SMOKE_GATEWAY=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

require_tool kubectl

pod_names="$(kubectl -n "${OPENCLAW_NAMESPACE}" get pod -l app.kubernetes.io/name="${OPENCLAW_DEPLOYMENT_NAME}" --field-selector=status.phase=Running -o name)"
pod="$(printf '%s\n' "${pod_names}" | sed -n '1s|pod/||p')"
[[ -n "${pod}" ]] || fail "No running OpenClaw pod found in namespace ${OPENCLAW_NAMESPACE}."

injection_ref="$(kubectl -n "${OPENCLAW_NAMESPACE}" get deployment "${OPENCLAW_DEPLOYMENT_NAME}" -o jsonpath='{.spec.template.metadata.annotations.instrumentation\.opentelemetry\.io/inject-nodejs}' 2>/dev/null || true)"
[[ -n "${injection_ref}" ]] || fail "Deployment ${OPENCLAW_DEPLOYMENT_NAME} is missing the inject-nodejs annotation."
ok "Deployment annotation points to ${injection_ref}"

init_containers="$(kubectl -n "${OPENCLAW_NAMESPACE}" get pod "${pod}" -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}')"
printf '%s\n' "${init_containers}" | grep -qx 'opentelemetry-auto-instrumentation-nodejs' || fail "Pod ${pod} was not mutated with the Node.js auto-instrumentation init container."
ok "Pod ${pod} contains the Node.js auto-instrumentation init container"

runtime_env="$(kubectl -n "${OPENCLAW_NAMESPACE}" exec "${pod}" -c "${OPENCLAW_CONTAINER_NAME}" -- env)"
printf '%s\n' "${runtime_env}" | grep -q '^NODE_OPTIONS=.*autoinstrumentation\.js' || fail "NODE_OPTIONS does not point at the injected auto-instrumentation bundle."
ok "NODE_OPTIONS includes the injected auto-instrumentation bundle"

otel_endpoint="$(printf '%s\n' "${runtime_env}" | awk -F= '/^OTEL_EXPORTER_OTLP_ENDPOINT=/{print substr($0, index($0,$2))}')"
[[ -n "${otel_endpoint}" ]] || fail "OTEL_EXPORTER_OTLP_ENDPOINT is missing from the running container."
ok "Exporter endpoint is ${otel_endpoint}"

otel_service_name="$(printf '%s\n' "${runtime_env}" | awk -F= '/^OTEL_SERVICE_NAME=/{print $2}')"
[[ -n "${otel_service_name}" ]] || fail "OTEL_SERVICE_NAME is missing from the running container."
ok "Service name is ${otel_service_name}"

resource_attributes="$(printf '%s\n' "${runtime_env}" | awk -F= '/^OTEL_RESOURCE_ATTRIBUTES=/{print substr($0, index($0,$2))}')"
printf '%s\n' "${resource_attributes}" | grep -q "deployment.environment=${OPENCLAW_DEPLOYMENT_ENVIRONMENT}" || fail "OTEL_RESOURCE_ATTRIBUTES does not include deployment.environment=${OPENCLAW_DEPLOYMENT_ENVIRONMENT}."
ok "Resource attributes include deployment.environment=${OPENCLAW_DEPLOYMENT_ENVIRONMENT}"

if kubectl -n "${OPENCLAW_NAMESPACE}" exec "${pod}" -c "${OPENCLAW_CONTAINER_NAME}" -- sh -lc 'cat /proc/net/tcp /proc/net/tcp6 | grep -qi :4965'; then
  ok "Gateway is listening on port 18789 inside the pod"
elif [[ "${STRICT_GATEWAY}" == "true" ]]; then
  fail "Gateway is not listening on port 18789 inside the pod."
else
  warn "Gateway is not listening on port 18789 inside the pod"
fi

if [[ "${SMOKE_GATEWAY}" == "true" ]]; then
  smoke_output="$(kubectl -n "${OPENCLAW_NAMESPACE}" exec "${pod}" -c "${OPENCLAW_CONTAINER_NAME}" -- node -e 'const http=require("http"); const token=process.env.OPENCLAW_GATEWAY_TOKEN || ""; const path="/__openclaw__/canvas/?token="+encodeURIComponent(token); const headers=token ? {Authorization:"Bearer "+token} : {}; const req=http.get({host:"127.0.0.1", port:18789, path, headers}, (res)=>{console.log("STATUS="+res.statusCode); res.resume(); res.on("end", ()=>process.exit(res.statusCode===200 ? 0 : 1));}); req.on("error", (err)=>{console.error("ERROR="+err.message); process.exit(1);});')"
  ok "Gateway smoke request succeeded: ${smoke_output}"
fi
