#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env

require_tool node

collector_url=""
trace_count="${TRACE_COUNT:-1}"
trace_service_name="${TRACE_SERVICE_NAME:-openclaw-manual}"
trace_span_name="${TRACE_SPAN_NAME:-openclaw.manual.test}"
trace_deployment_environment="${TRACE_DEPLOYMENT_ENVIRONMENT:-nemolaw}"

usage() {
  cat <<EOF
Usage: scripts/local/emit-test-trace.sh [--count N] [--service-name NAME] [--span-name NAME] [--collector-url URL]

Sends synthetic OTLP traces directly to the local collector so you can validate Splunk ingest
without NemoClaw, OpenShell, or a live model request.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      trace_count="$2"
      shift 2
      ;;
    --service-name)
      trace_service_name="$2"
      shift 2
      ;;
    --span-name)
      trace_span_name="$2"
      shift 2
      ;;
    --collector-url)
      collector_url="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${collector_url}" ]]; then
  collector_url="$("${SCRIPT_DIR}/ensure-collector.sh" --print-host-endpoint)"
fi

echo "Sending ${trace_count} synthetic trace(s) to ${collector_url}"
env \
  OTLP_HTTP_ENDPOINT="${collector_url}" \
  TRACE_COUNT="${trace_count}" \
  TRACE_SERVICE_NAME="${trace_service_name}" \
  TRACE_SPAN_NAME="${trace_span_name}" \
  TRACE_DEPLOYMENT_ENVIRONMENT="${trace_deployment_environment}" \
  node "${SCRIPT_DIR}/emit-test-trace.js"
