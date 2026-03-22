#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_lab_env

OPENCLAW_NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
OPENCLAW_SECRET_NAME="${OPENCLAW_SECRET_NAME:-openclaw-secrets}"
SPLUNK_OTEL_NAMESPACE="${SPLUNK_OTEL_NAMESPACE:-splunk-o11y}"
SPLUNK_OTEL_RELEASE_NAME="${SPLUNK_OTEL_RELEASE_NAME:-splunk-otel}"
SKIP_SPLUNK_OTEL_INSTALL="${SKIP_SPLUNK_OTEL_INSTALL:-false}"

DELETE=false
SHOW_TOKEN=false

usage() {
  cat <<'EOF'
Usage: deploy-lab.sh [--show-token] [--delete]

This orchestrates:
  1. Splunk OpenTelemetry Collector + Operator install
  2. OpenClaw deployment
  3. Node.js auto-instrumentation annotation on the OpenClaw deployment

Required environment:
  One OpenClaw provider key such as OPENAI_API_KEY

Either:
  SPLUNK_REALM
  SPLUNK_ACCESS_TOKEN

Or:
  SKIP_SPLUNK_OTEL_INSTALL=true
  SPLUNK_INSTRUMENTATION_REF=<namespace>/<name>

Helpful file:
  scripts/k8s/lab.env.example
EOF
}

show_token() {
  kubectl get secret "${OPENCLAW_SECRET_NAME}" -n "${OPENCLAW_NAMESPACE}" -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | \
    { if base64 --decode >/dev/null 2>&1 <<<""; then base64 --decode; else base64 -D; fi; }
  printf '\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete)
      DELETE=true
      ;;
    --show-token)
      SHOW_TOKEN=true
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
  "${SCRIPT_DIR}/deploy-openclaw.sh" --delete
  if [[ "${SKIP_SPLUNK_OTEL_INSTALL}" != "true" ]]; then
    "${SCRIPT_DIR}/deploy-splunk-o11y.sh" --delete
  fi
  exit 0
fi

if [[ "${SKIP_SPLUNK_OTEL_INSTALL}" != "true" ]]; then
  if [[ -n "${SPLUNK_REALM:-}" && -n "${SPLUNK_ACCESS_TOKEN:-}" ]]; then
    "${SCRIPT_DIR}/deploy-splunk-o11y.sh"
  else
    echo "SPLUNK_REALM/SPLUNK_ACCESS_TOKEN not set; attempting to reuse an existing instrumentation object." >&2
  fi
fi
"${SCRIPT_DIR}/deploy-openclaw.sh"

INSTRUMENTATION_REF="$(resolve_instrumentation_ref)"

kubectl -n "${OPENCLAW_NAMESPACE}" patch deployment openclaw --type merge -p "$(cat <<EOF
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-nodejs: "${INSTRUMENTATION_REF}"
        instrumentation.opentelemetry.io/container-names: "openclaw"
EOF
)" >/dev/null
kubectl -n "${OPENCLAW_NAMESPACE}" rollout restart deployment/openclaw >/dev/null
kubectl -n "${OPENCLAW_NAMESPACE}" rollout status deployment/openclaw --timeout=10m

cat <<EOF
Lab ready.

OpenClaw namespace: ${OPENCLAW_NAMESPACE}
Splunk OTel namespace: ${SPLUNK_OTEL_NAMESPACE}
Instrumentation resource: ${INSTRUMENTATION_REF}

Verify OpenClaw:
  kubectl get pods -n ${OPENCLAW_NAMESPACE}

Verify auto-instrumentation:
  kubectl get pods -n ${OPENCLAW_NAMESPACE} -o yaml | grep -n "opentelemetry-auto-instrumentation"
  ${SCRIPT_DIR}/verify-lab.sh --strict-gateway --smoke-gateway

Open the gateway:
  kubectl port-forward svc/openclaw 18789:18789 -n ${OPENCLAW_NAMESPACE}
  open http://127.0.0.1:18789

Fetch the token:
  kubectl get secret ${OPENCLAW_SECRET_NAME} -n ${OPENCLAW_NAMESPACE} -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | openssl base64 -d -A
EOF

if [[ "${SHOW_TOKEN}" == "true" ]]; then
  show_token
fi
