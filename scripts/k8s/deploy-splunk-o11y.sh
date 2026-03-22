#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_lab_env

SPLUNK_OTEL_NAMESPACE="${SPLUNK_OTEL_NAMESPACE:-splunk-o11y}"
SPLUNK_OTEL_RELEASE_NAME="${SPLUNK_OTEL_RELEASE_NAME:-splunk-otel}"
SPLUNK_OTEL_CHART_VERSION="${SPLUNK_OTEL_CHART_VERSION:-}"
SPLUNK_ENVIRONMENT="${SPLUNK_ENVIRONMENT:-lab}"
SPLUNK_ENABLE_PROFILING="${SPLUNK_ENABLE_PROFILING:-true}"
K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-openclaw-lab}"
K8S_DISTRIBUTION="${K8S_DISTRIBUTION:-}"
K8S_CLOUD_PROVIDER="${K8S_CLOUD_PROVIDER:-}"
SPLUNK_REALM="${SPLUNK_REALM:-}"
SPLUNK_ACCESS_TOKEN="${SPLUNK_ACCESS_TOKEN:-}"

DELETE=false

usage() {
  cat <<'EOF'
Usage: deploy-splunk-o11y.sh [--delete]

Required environment:
  SPLUNK_REALM
  SPLUNK_ACCESS_TOKEN

Optional environment:
  SPLUNK_OTEL_NAMESPACE      Default: splunk-o11y
  SPLUNK_OTEL_RELEASE_NAME   Default: splunk-otel
  SPLUNK_OTEL_CHART_VERSION  Pin a Helm chart version
  SPLUNK_ENVIRONMENT         Default: lab
  SPLUNK_ENABLE_PROFILING    Default: true
  K8S_CLUSTER_NAME           Default: openclaw-lab
  K8S_DISTRIBUTION           e.g. eks, gke, aks
  K8S_CLOUD_PROVIDER         e.g. aws, gcp, azure
EOF
}

wait_for_instrumentation() {
  local attempts=60
  local sleep_seconds=5

  while (( attempts > 0 )); do
    if kubectl -n "${SPLUNK_OTEL_NAMESPACE}" get instrumentations.opentelemetry.io "${SPLUNK_OTEL_RELEASE_NAME}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_seconds}"
    attempts=$((attempts - 1))
  done

  echo "Timed out waiting for Instrumentation/${SPLUNK_OTEL_RELEASE_NAME} in namespace ${SPLUNK_OTEL_NAMESPACE}." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
require_tool helm

if [[ "${DELETE}" == "true" ]]; then
  helm uninstall "${SPLUNK_OTEL_RELEASE_NAME}" -n "${SPLUNK_OTEL_NAMESPACE}" >/dev/null 2>&1 || true
  kubectl delete namespace "${SPLUNK_OTEL_NAMESPACE}" --ignore-not-found >/dev/null
  exit 0
fi

if [[ -z "${SPLUNK_REALM}" || -z "${SPLUNK_ACCESS_TOKEN}" ]]; then
  echo "SPLUNK_REALM and SPLUNK_ACCESS_TOKEN must be set." >&2
  exit 1
fi

case "${SPLUNK_ENABLE_PROFILING}" in
  true|false)
    ;;
  *)
    echo "SPLUNK_ENABLE_PROFILING must be true or false." >&2
    exit 1
    ;;
esac

kubectl get namespace "${SPLUNK_OTEL_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${SPLUNK_OTEL_NAMESPACE}" >/dev/null

tmp_values="$(mktemp "/tmp/splunk-otel-values.XXXXXX.yaml")"
trap 'rm -f "${tmp_values}"' EXIT

{
  if [[ -n "${K8S_DISTRIBUTION}" ]]; then
    printf 'distribution: %s\n' "${K8S_DISTRIBUTION}"
  fi
  if [[ -n "${K8S_CLOUD_PROVIDER}" ]]; then
    printf 'cloudProvider: %s\n' "${K8S_CLOUD_PROVIDER}"
  fi
  cat <<EOF
clusterName: ${K8S_CLUSTER_NAME}
environment: ${SPLUNK_ENVIRONMENT}
splunkObservability:
  realm: ${SPLUNK_REALM}
  accessToken: ${SPLUNK_ACCESS_TOKEN}
  profilingEnabled: ${SPLUNK_ENABLE_PROFILING}
operatorcrds:
  install: true
operator:
  enabled: true
  admissionWebhooks:
    autoGenerateCert:
      enabled: true
EOF
} >"${tmp_values}"

helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart --force-update >/dev/null
helm repo update splunk-otel-collector-chart >/dev/null

helm_args=(
  upgrade
  --install
  "${SPLUNK_OTEL_RELEASE_NAME}"
  splunk-otel-collector-chart/splunk-otel-collector
  --namespace
  "${SPLUNK_OTEL_NAMESPACE}"
  --create-namespace
  --values
  "${tmp_values}"
)

if [[ -n "${SPLUNK_OTEL_CHART_VERSION}" ]]; then
  helm_args+=(--version "${SPLUNK_OTEL_CHART_VERSION}")
fi

helm "${helm_args[@]}"

kubectl -n "${SPLUNK_OTEL_NAMESPACE}" rollout status daemonset/"${SPLUNK_OTEL_RELEASE_NAME}-agent" --timeout=10m
kubectl -n "${SPLUNK_OTEL_NAMESPACE}" rollout status deployment/"${SPLUNK_OTEL_RELEASE_NAME}-k8s-cluster-receiver" --timeout=10m
kubectl -n "${SPLUNK_OTEL_NAMESPACE}" rollout status deployment/"${SPLUNK_OTEL_RELEASE_NAME}-opentelemetry-operator" --timeout=10m
wait_for_instrumentation

echo "Splunk OpenTelemetry Collector deployed in namespace ${SPLUNK_OTEL_NAMESPACE}."
echo "Release: ${SPLUNK_OTEL_RELEASE_NAME}"
echo "Verify: kubectl get pods -n ${SPLUNK_OTEL_NAMESPACE}"
