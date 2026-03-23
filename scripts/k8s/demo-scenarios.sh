#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_lab_env

OPENCLAW_NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
OPENCLAW_SECRET_NAME="${OPENCLAW_SECRET_NAME:-openclaw-secrets}"
OPENCLAW_DEPLOYMENT_NAME="${OPENCLAW_DEPLOYMENT_NAME:-openclaw}"
OPENCLAW_CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-openclaw}"
OPENCLAW_DEPLOYMENT_ENVIRONMENT="${OPENCLAW_DEPLOYMENT_ENVIRONMENT:-Openclaw}"
SPLUNK_OTEL_NAMESPACE="${SPLUNK_OTEL_NAMESPACE:-splunk-o11y}"
SPLUNK_OTEL_RELEASE_NAME="${SPLUNK_OTEL_RELEASE_NAME:-splunk-otel}"
K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-openclaw-lab}"
OPENSHELL_DEMO_SERVICE_NAME="${OPENSHELL_DEMO_SERVICE_NAME:-openshell-demo-control-plane}"
OPENSHELL_DEMO_COLLECTOR_URL="${OPENSHELL_DEMO_COLLECTOR_URL:-}"
ERROR_BURST_REQUEST_COUNT="${ERROR_BURST_REQUEST_COUNT:-8}"

SCENARIO="all"
PRINT_ONLY=false

usage() {
  cat <<'EOF'
Usage: demo-scenarios.sh [scenario] [--print-only]

Scenarios:
  normal
  policy-blocked
  error-burst
  suspicious
  all

This script exercises the current OpenClaw Kubernetes lab and emits OpenShell-shaped
traces, metrics, and logs through the Splunk OTel collector so the O11y demo can show:

  - real OpenClaw gateway traffic
  - synthetic OpenShell/NemoClaw control-plane events
  - security/policy signals suitable for dashboards and detectors
EOF
}

info() {
  printf '[info] %s\n' "$1"
}

fail() {
  printf '[fail] %s\n' "$1" >&2
  exit 1
}

resolve_pod() {
  local pod_names=""
  local pod=""

  pod_names="$(kubectl -n "${OPENCLAW_NAMESPACE}" get pod -l app.kubernetes.io/name="${OPENCLAW_DEPLOYMENT_NAME}" --field-selector=status.phase=Running -o name)"
  pod="$(printf '%s\n' "${pod_names}" | sed -n '1s|pod/||p')"
  [[ -n "${pod}" ]] || fail "No running OpenClaw pod found in namespace ${OPENCLAW_NAMESPACE}."
  printf '%s\n' "${pod}"
}

gateway_token() {
  local encoded=""

  encoded="$(kubectl -n "${OPENCLAW_NAMESPACE}" get secret "${OPENCLAW_SECRET_NAME}" -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' 2>/dev/null || true)"
  [[ -n "${encoded}" ]] || fail "Secret ${OPENCLAW_SECRET_NAME} does not contain OPENCLAW_GATEWAY_TOKEN."
  printf '%s' "${encoded}" | base64_decode
}

resolve_collector_url() {
  local pod="$1"
  local runtime_env=""
  local otel_endpoint=""

  if [[ -n "${OPENSHELL_DEMO_COLLECTOR_URL}" ]]; then
    printf '%s\n' "${OPENSHELL_DEMO_COLLECTOR_URL}"
    return 0
  fi

  runtime_env="$(kubectl -n "${OPENCLAW_NAMESPACE}" exec "${pod}" -c "${OPENCLAW_CONTAINER_NAME}" -- env)"
  otel_endpoint="$(printf '%s\n' "${runtime_env}" | awk -F= '/^OTEL_EXPORTER_OTLP_ENDPOINT=/{print substr($0, index($0,$2))}')"

  if [[ -n "${otel_endpoint}" ]]; then
    if [[ "${otel_endpoint}" == *":4317" ]]; then
      printf '%s\n' "${otel_endpoint%:4317}:4318"
      return 0
    fi
    printf '%s\n' "${otel_endpoint}"
    return 0
  fi

  printf 'http://%s-agent.%s.svc:4318\n' "${SPLUNK_OTEL_RELEASE_NAME}" "${SPLUNK_OTEL_NAMESPACE}"
}

run_remote_emitter() {
  local pod="$1"
  local collector_url="$2"
  local scenario_name="$3"
  local gateway_mode="$4"
  local gateway_port="$5"
  local request_count="$6"
  local workflow_outcome="$7"
  local policy_decision="$8"
  local policy_name="$9"
  local target_host="${10}"
  local target_path="${11}"
  local http_method="${12}"
  local action_count="${13}"
  local suspicion_score="${14}"
  local log_severity="${15}"
  local summary_message="${16}"
  local token=""
  local -a env_args

  token="$(gateway_token)"
  env_args=(
    "DEMO_COLLECTOR_URL=${collector_url}"
    "DEMO_SERVICE_NAME=${OPENSHELL_DEMO_SERVICE_NAME}"
    "DEMO_DEPLOYMENT_ENVIRONMENT=${OPENCLAW_DEPLOYMENT_ENVIRONMENT}"
    "DEMO_NAMESPACE=${OPENCLAW_NAMESPACE}"
    "DEMO_CLUSTER_NAME=${K8S_CLUSTER_NAME}"
    "DEMO_SCENARIO=${scenario_name}"
    "DEMO_GATEWAY_MODE=${gateway_mode}"
    "DEMO_GATEWAY_PORT=${gateway_port}"
    "DEMO_INVALID_GATEWAY_TOKEN=denied-demo-token"
    "DEMO_REQUEST_COUNT=${request_count}"
    "DEMO_WORKFLOW_OUTCOME=${workflow_outcome}"
    "DEMO_POLICY_DECISION=${policy_decision}"
    "DEMO_POLICY_NAME=${policy_name}"
    "DEMO_TARGET_HOST=${target_host}"
    "DEMO_TARGET_PATH=${target_path}"
    "DEMO_HTTP_METHOD=${http_method}"
    "DEMO_ACTION_COUNT=${action_count}"
    "DEMO_SUSPICION_SCORE=${suspicion_score}"
    "DEMO_LOG_SEVERITY=${log_severity}"
    "DEMO_SUMMARY_MESSAGE=${summary_message}"
  )

  if [[ "${PRINT_ONLY}" == "true" ]]; then
    env_args+=("DEMO_PRINT_ONLY=true")
  fi

  kubectl -n "${OPENCLAW_NAMESPACE}" exec -i "${pod}" -c "${OPENCLAW_CONTAINER_NAME}" -- \
    env "${env_args[@]}" sh -lc 'unset NODE_OPTIONS; exec node -' < "${SCRIPT_DIR}/demo-emitter.js"
}

run_normal() {
  local pod="$1"
  local collector_url="$2"
  info "Running normal workflow scenario."
  run_remote_emitter \
    "${pod}" \
    "${collector_url}" \
    "normal" \
    "valid" \
    "18789" \
    "1" \
    "success" \
    "allow" \
    "openclaw-default" \
    "127.0.0.1" \
    "/__openclaw__/canvas/" \
    "GET" \
    "3" \
    "0.02" \
    "INFO" \
    "Normal workflow completed: config read, allowed tool use, result write."
}

run_policy_blocked() {
  local pod="$1"
  local collector_url="$2"
  info "Running policy-blocked scenario."
  run_remote_emitter \
    "${pod}" \
    "${collector_url}" \
    "policy-blocked" \
    "none" \
    "18789" \
    "1" \
    "blocked" \
    "deny" \
    "github-api-readonly" \
    "api.github.com" \
    "/repos/octocat/hello-world/issues" \
    "POST" \
    "1" \
    "0.40" \
    "WARN" \
    "Policy denied an unapproved outbound POST, matching the OpenShell GitHub quickstart pattern."
}

run_error_burst() {
  local pod="$1"
  local collector_url="$2"
  info "Running runtime degradation / error burst scenario."
  run_remote_emitter \
    "${pod}" \
    "${collector_url}" \
    "error-burst" \
    "invalid" \
    "18790" \
    "${ERROR_BURST_REQUEST_COUNT}" \
    "error" \
    "allow" \
    "gateway-auth" \
    "127.0.0.1" \
    "/__openclaw__/canvas/" \
    "GET" \
    "${ERROR_BURST_REQUEST_COUNT}" \
    "0.10" \
    "ERROR" \
    "Gateway error burst generated repeated connection failures to exercise latency and error detectors."
}

run_suspicious() {
  local pod="$1"
  local collector_url="$2"
  info "Running suspicious multi-step behavior scenario."
  run_remote_emitter \
    "${pod}" \
    "${collector_url}" \
    "suspicious" \
    "mixed" \
    "18789" \
    "4" \
    "alert" \
    "deny" \
    "egress-exfil-guardrail" \
    "pastebin.example" \
    "/api/v1/documents" \
    "POST" \
    "4" \
    "0.92" \
    "WARN" \
    "Suspicious multi-step chain detected after local read, tool use, and blocked exfiltration attempt."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    normal|policy-blocked|error-burst|suspicious|all)
      SCENARIO="$1"
      ;;
    --print-only)
      PRINT_ONLY=true
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

POD="$(resolve_pod)"
COLLECTOR_URL="$(resolve_collector_url "${POD}")"

info "Using pod ${POD} in namespace ${OPENCLAW_NAMESPACE}."
info "Using collector endpoint ${COLLECTOR_URL}."
info "Synthetic control-plane service.name=${OPENSHELL_DEMO_SERVICE_NAME}."

case "${SCENARIO}" in
  normal)
    run_normal "${POD}" "${COLLECTOR_URL}"
    ;;
  policy-blocked)
    run_policy_blocked "${POD}" "${COLLECTOR_URL}"
    ;;
  error-burst)
    run_error_burst "${POD}" "${COLLECTOR_URL}"
    ;;
  suspicious)
    run_suspicious "${POD}" "${COLLECTOR_URL}"
    ;;
  all)
    run_normal "${POD}" "${COLLECTOR_URL}"
    run_policy_blocked "${POD}" "${COLLECTOR_URL}"
    run_error_burst "${POD}" "${COLLECTOR_URL}"
    run_suspicious "${POD}" "${COLLECTOR_URL}"
    ;;
esac
