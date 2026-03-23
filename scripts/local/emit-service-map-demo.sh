#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

load_lab_env

require_tool node

collector_url=""
trace_count="${TRACE_COUNT:-5}"
print_only="false"

usage() {
  cat <<EOF
Usage: scripts/local/emit-service-map-demo.sh [--count N] [--collector-url URL] [--print-only]

Sends synthetic multi-service OTLP traces for the local nemolaw environment so Splunk APM
can render a connected service map instead of a single isolated service.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      trace_count="$2"
      shift 2
      ;;
    --collector-url)
      collector_url="$2"
      shift 2
      ;;
    --print-only)
      print_only="true"
      shift
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

if [[ "${print_only}" == "true" ]]; then
  env \
    OTLP_HTTP_ENDPOINT="${collector_url}" \
    TRACE_COUNT="${trace_count}" \
    TRACE_PRINT_ONLY="true" \
    node "${SCRIPT_DIR}/emit-service-map-demo.js"
  exit 0
fi

echo "Sending ${trace_count} synthetic multi-service trace(s) to ${collector_url}"
env \
  OTLP_HTTP_ENDPOINT="${collector_url}" \
  TRACE_COUNT="${trace_count}" \
  node "${SCRIPT_DIR}/emit-service-map-demo.js"
