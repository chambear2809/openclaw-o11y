#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_lab_env

OPENCLAW_NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
OPENCLAW_SECRET_NAME="${OPENCLAW_SECRET_NAME:-openclaw-secrets}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
OPENCLAW_SERVICE_NAME="${OPENCLAW_SERVICE_NAME:-openclaw}"
OPENCLAW_DEPLOYMENT_ENVIRONMENT="${OPENCLAW_DEPLOYMENT_ENVIRONMENT:-Openclaw}"
OPENCLAW_NODE_OPTIONS_BASE="${OPENCLAW_NODE_OPTIONS_BASE:---max-old-space-size=1536}"
OPENCLAW_MEMORY_REQUEST="${OPENCLAW_MEMORY_REQUEST:-1Gi}"
OPENCLAW_MEMORY_LIMIT="${OPENCLAW_MEMORY_LIMIT:-2Gi}"

SHOW_TOKEN=false
CREATE_SECRET_ONLY=false
DELETE=false

PROVIDER_KEYS=(
  "ANTHROPIC_API_KEY"
  "GEMINI_API_KEY"
  "OPENAI_API_KEY"
  "OPENROUTER_API_KEY"
)

usage() {
  cat <<'EOF'
Usage: deploy-openclaw.sh [--create-secret] [--show-token] [--delete]

Environment:
  OPENCLAW_NAMESPACE      Namespace to deploy into. Default: openclaw
  OPENCLAW_SECRET_NAME    Secret name for gateway/provider credentials. Default: openclaw-secrets
  OPENCLAW_IMAGE          Container image. Default: ghcr.io/openclaw/openclaw:latest
  OPENCLAW_STORAGE_CLASS  Optional override. Auto-detected when unset.
  OPENCLAW_SERVICE_NAME   Exported OTEL service.name. Default: openclaw
  OPENCLAW_DEPLOYMENT_ENVIRONMENT  Exported deployment.environment. Default: Openclaw
  OPENCLAW_NODE_OPTIONS_BASE  Base NODE_OPTIONS before OTel injection. Default: --max-old-space-size=1536
  OPENCLAW_MEMORY_REQUEST  OpenClaw memory request. Default: 1Gi
  OPENCLAW_MEMORY_LIMIT   OpenClaw memory limit. Default: 2Gi

Credential input:
  Export at least one of:
    ANTHROPIC_API_KEY
    GEMINI_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
  Optional:
    OPENCLAW_GATEWAY_TOKEN
EOF
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    python3 -c 'import secrets; print(secrets.token_hex(24))'
  fi
}

secret_exists() {
  kubectl -n "${OPENCLAW_NAMESPACE}" get secret "${OPENCLAW_SECRET_NAME}" >/dev/null 2>&1
}

get_secret_value() {
  local key="$1"
  local encoded=""

  if ! secret_exists; then
    return 0
  fi

  encoded="$(kubectl -n "${OPENCLAW_NAMESPACE}" get secret "${OPENCLAW_SECRET_NAME}" -o "jsonpath={.data.${key}}" 2>/dev/null || true)"

  if [[ -z "${encoded}" ]]; then
    return 0
  fi

  printf '%s' "${encoded}" | base64_decode
}

ensure_namespace() {
  kubectl get namespace "${OPENCLAW_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${OPENCLAW_NAMESPACE}" >/dev/null
}

ensure_secret() {
  local gateway_token="${OPENCLAW_GATEWAY_TOKEN:-}"
  local provider_count=0
  local literals=()
  local key=""
  local value=""

  if [[ -z "${gateway_token}" ]]; then
    gateway_token="$(get_secret_value OPENCLAW_GATEWAY_TOKEN)"
  fi
  if [[ -z "${gateway_token}" ]]; then
    gateway_token="$(generate_token)"
  fi

  literals+=("--from-literal=OPENCLAW_GATEWAY_TOKEN=${gateway_token}")

  for key in "${PROVIDER_KEYS[@]}"; do
    value="${!key:-}"
    if [[ -z "${value}" ]]; then
      value="$(get_secret_value "${key}")"
    fi
    if [[ -n "${value}" ]]; then
      literals+=("--from-literal=${key}=${value}")
      provider_count=$((provider_count + 1))
    fi
  done

  if (( provider_count == 0 )); then
    echo "No provider key found. Export one of: ${PROVIDER_KEYS[*]}" >&2
    exit 1
  fi

  kubectl -n "${OPENCLAW_NAMESPACE}" create secret generic "${OPENCLAW_SECRET_NAME}" \
    "${literals[@]}" \
    --dry-run=client \
    -o yaml | kubectl apply -n "${OPENCLAW_NAMESPACE}" -f - >/dev/null
}

show_token() {
  local token=""
  token="$(get_secret_value OPENCLAW_GATEWAY_TOKEN)"
  if [[ -n "${token}" ]]; then
    printf '%s\n' "${token}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-secret)
      CREATE_SECRET_ONLY=true
      ;;
    --show-token)
      SHOW_TOKEN=true
      ;;
    --delete)
      DELETE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

require_tool kubectl

if [[ "${DELETE}" == "true" ]]; then
  kubectl delete namespace "${OPENCLAW_NAMESPACE}" --ignore-not-found >/dev/null
  exit 0
fi

ensure_namespace
ensure_secret

if [[ "${CREATE_SECRET_ONLY}" == "true" ]]; then
  if [[ "${SHOW_TOKEN}" == "true" ]]; then
    show_token
  fi
  exit 0
fi

OPENCLAW_STORAGE_CLASS="$(resolve_storage_class)"
render_openclaw_manifests "${MANIFEST_DIR}" "${OPENCLAW_STORAGE_CLASS}" | kubectl -n "${OPENCLAW_NAMESPACE}" apply -f - >/dev/null
kubectl -n "${OPENCLAW_NAMESPACE}" set image deployment/openclaw openclaw="${OPENCLAW_IMAGE}" >/dev/null
kubectl -n "${OPENCLAW_NAMESPACE}" set env deployment/openclaw \
  NODE_OPTIONS="${OPENCLAW_NODE_OPTIONS_BASE}" \
  OTEL_SERVICE_NAME="${OPENCLAW_SERVICE_NAME}" \
  OTEL_RESOURCE_ATTRIBUTES="deployment.environment=${OPENCLAW_DEPLOYMENT_ENVIRONMENT}" >/dev/null
kubectl -n "${OPENCLAW_NAMESPACE}" set resources deployment/openclaw -c openclaw \
  --requests="cpu=500m,memory=${OPENCLAW_MEMORY_REQUEST}" \
  --limits="cpu=1,memory=${OPENCLAW_MEMORY_LIMIT}" >/dev/null
kubectl -n "${OPENCLAW_NAMESPACE}" rollout restart deployment/openclaw >/dev/null
kubectl -n "${OPENCLAW_NAMESPACE}" rollout status deployment/openclaw --timeout=10m

echo "OpenClaw deployed in namespace ${OPENCLAW_NAMESPACE}."
echo "Storage class: ${OPENCLAW_STORAGE_CLASS}"
echo "Port-forward: kubectl port-forward svc/openclaw 18789:18789 -n ${OPENCLAW_NAMESPACE}"
echo "Token command: kubectl get secret ${OPENCLAW_SECRET_NAME} -n ${OPENCLAW_NAMESPACE} -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | openssl base64 -d -A"

if [[ "${SHOW_TOKEN}" == "true" ]]; then
  show_token
fi
