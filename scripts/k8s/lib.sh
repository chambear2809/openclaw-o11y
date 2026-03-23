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

base64_decode() {
  if base64 --decode >/dev/null 2>&1 <<<""; then
    base64 --decode
  else
    base64 -D
  fi
}

resolve_storage_class() {
  local configured="${OPENCLAW_STORAGE_CLASS:-}"
  local detected=""

  if [[ -n "${configured}" ]]; then
    printf '%s\n' "${configured}"
    return 0
  fi

  detected="$(kubectl get storageclass --no-headers -o custom-columns=NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class 2>/dev/null | awk '$2=="true"{print $1; exit}')"
  if [[ -n "${detected}" ]]; then
    printf '%s\n' "${detected}"
    return 0
  fi

  detected="$(kubectl get storageclass --no-headers 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -n "${detected}" ]]; then
    printf '%s\n' "${detected}"
    return 0
  fi

  echo "No Kubernetes storage class found. Set OPENCLAW_STORAGE_CLASS explicitly." >&2
  exit 1
}

resolve_instrumentation_ref() {
  local explicit="${SPLUNK_INSTRUMENTATION_REF:-}"
  local namespace="${SPLUNK_OTEL_NAMESPACE:-}"
  local release="${SPLUNK_OTEL_RELEASE_NAME:-}"
  local discovered=""
  local count=""

  if [[ -n "${explicit}" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  if [[ -n "${namespace}" && -n "${release}" ]] && kubectl get instrumentation.opentelemetry.io "${release}" -n "${namespace}" >/dev/null 2>&1; then
    printf '%s/%s\n' "${namespace}" "${release}"
    return 0
  fi

  if kubectl get instrumentation.opentelemetry.io splunk-otel-collector -n otel-splunk >/dev/null 2>&1; then
    printf '%s\n' "otel-splunk/splunk-otel-collector"
    return 0
  fi

  count="$(kubectl get instrumentations.opentelemetry.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${count}" == "1" ]]; then
    discovered="$(kubectl get instrumentations.opentelemetry.io -A --no-headers | awk '{print $1 "/" $2}')"
    printf '%s\n' "${discovered}"
    return 0
  fi

  echo "Unable to resolve a Splunk instrumentation object. Set SPLUNK_INSTRUMENTATION_REF or deploy one first." >&2
  exit 1
}

render_openclaw_manifests() {
  local manifest_dir="$1"
  local storage_class="$2"

  kubectl kustomize "${manifest_dir}" | env \
    OPENCLAW_STORAGE_CLASS="${storage_class}" \
    OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}" \
    OPENCLAW_NODE_OPTIONS="${OPENCLAW_NODE_OPTIONS_BASE:---max-old-space-size=1536}" \
    OPENCLAW_SERVICE_NAME="${OPENCLAW_SERVICE_NAME:-openclaw}" \
    OPENCLAW_RESOURCE_ATTRIBUTES="deployment.environment=${OPENCLAW_DEPLOYMENT_ENVIRONMENT:-Openclaw}" \
    OPENCLAW_SECRET_NAME="${OPENCLAW_SECRET_NAME:-openclaw-secrets}" \
    OPENCLAW_MEMORY_REQUEST="${OPENCLAW_MEMORY_REQUEST:-1Gi}" \
    OPENCLAW_MEMORY_LIMIT="${OPENCLAW_MEMORY_LIMIT:-2Gi}" \
    OPENCLAW_INSTRUMENTATION_REF="${OPENCLAW_INSTRUMENTATION_REF:-}" \
    node "${SCRIPT_DIR}/render-openclaw-manifests.js"
}
