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

require_env() {
  local name="$1"
  local value="${(P)name:-}"
  if [[ -z "${value}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

find_local_otel_collector() {
  local port="${1:-${LOCAL_OTEL_COLLECTOR_HOST_PORT:-4318}}"
  local match=""

  match="$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' | awk -F'\t' -v port="${port}" 'index($3, ":" port "->") { print; exit }')"
  if [[ -n "${match}" ]]; then
    printf '%s\n' "${match}"
    return 0
  fi

  return 1
}

local_collector_host_port() {
  printf '%s\n' "${LOCAL_OTEL_COLLECTOR_HOST_PORT:-4318}"
}

local_gateway_host_alias() {
  printf '%s\n' "${LOCAL_GATEWAY_HOST_ALIAS:-host.docker.internal}"
}

local_gateway_host_ip() {
  printf '%s\n' "${LOCAL_GATEWAY_HOST_IP:-192.168.65.254}"
}

local_openshell_gateway_name() {
  printf '%s\n' "${LOCAL_OPENSHELL_GATEWAY_NAME:-nemoclaw}"
}

local_gateway_otel_forwarder_name() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_NAME:-openclaw-otlp-forwarder}"
}

local_gateway_otel_forwarder_namespace() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_NAMESPACE:-openshell}"
}

local_gateway_otel_forwarder_http_port() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_HTTP_PORT:-4318}"
}

local_gateway_otel_forwarder_host_port() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_HOST_PORT:-43181}"
}

local_gateway_otel_forwarder_health_port() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_HEALTH_PORT:-13181}"
}

local_gateway_otel_forwarder_image() {
  printf '%s\n' "${LOCAL_OTEL_FORWARDER_IMAGE:-otel/opentelemetry-collector-contrib:0.126.0}"
}

local_gateway_otel_forwarder_service_host() {
  printf '%s.%s.svc\n' "$(local_gateway_otel_forwarder_name)" "$(local_gateway_otel_forwarder_namespace)"
}

local_gateway_otel_forwarder_service_fqdn() {
  printf '%s.%s.svc.cluster.local\n' "$(local_gateway_otel_forwarder_name)" "$(local_gateway_otel_forwarder_namespace)"
}

local_gateway_otel_forwarder_endpoint() {
  printf 'http://%s:%s\n' "$(local_gateway_otel_forwarder_service_fqdn)" "$(local_gateway_otel_forwarder_http_port)"
}

local_gateway_otel_forwarder_target_endpoint() {
  printf 'http://%s:%s\n' "$(local_gateway_host_ip)" "$(local_collector_host_port)"
}

local_collector_sandbox_endpoint() {
  local_gateway_otel_forwarder_endpoint
}

local_collector_host_endpoint() {
  printf 'http://127.0.0.1:%s\n' "$(local_collector_host_port)"
}

local_openai_relay_host_port() {
  printf '%s\n' "${LOCAL_OPENAI_RELAY_PORT:-8787}"
}

local_openai_relay_host_endpoint() {
  printf 'http://127.0.0.1:%s/v1\n' "$(local_openai_relay_host_port)"
}

local_openai_relay_gateway_endpoint() {
  printf 'http://%s:%s/v1\n' "$(local_gateway_host_alias)" "$(local_openai_relay_host_port)"
}

sandbox_ssh_host() {
  local sandbox_name="$1"
  printf 'openshell-%s\n' "${sandbox_name}"
}

write_sandbox_ssh_config() {
  local sandbox_name="$1"
  local config_file="$2"
  local openshell_bin=""

  openshell_bin="$(command -v openshell)"
  cat > "${config_file}" <<EOF
Host $(sandbox_ssh_host "${sandbox_name}")
    User sandbox
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /dev/null
    LogLevel ERROR
    ProxyCommand ${openshell_bin} ssh-proxy --gateway-name $(local_openshell_gateway_name) --name ${sandbox_name}
EOF
}

run_sandbox_script() {
  local sandbox_name="$1"
  local script_file="$2"
  local config_file=""

  config_file="$(mktemp)"
  write_sandbox_ssh_config "${sandbox_name}" "${config_file}"
  ssh -F "${config_file}" "$(sandbox_ssh_host "${sandbox_name}")" 'bash -s' < "${script_file}"
  rm -f "${config_file}"
}

resolve_nemoclaw_repo_dir() {
  printf '%s\n' "${NEMOCLAW_REPO_DIR:-/tmp/NemoClaw}"
}

apply_nemoclaw_overlay_patch() {
  local repo_dir="$1"
  local patch_files=("${SCRIPT_DIR}/overlays/"*.patch)
  local patch_file=""

  if [[ "${#patch_files[@]}" -eq 0 ]]; then
    echo "Missing NemoClaw overlay patches in ${SCRIPT_DIR}/overlays" >&2
    return 1
  fi

  # The local /tmp NemoClaw clone is disposable. Reset the overlay target so
  # reruns pick up the current patch even if a previous attempt left Dockerfile
  # or onboard.js in a partially patched state.
  if ! git -C "${repo_dir}" restore --source=HEAD --worktree -- Dockerfile bin/lib/onboard.js >/dev/null 2>&1; then
    git -C "${repo_dir}" checkout -- Dockerfile bin/lib/onboard.js >/dev/null 2>&1 || true
  fi

  for patch_file in "${patch_files[@]}"; do
    git -C "${repo_dir}" apply --check "${patch_file}" >/dev/null 2>&1 || {
      echo "Failed to apply NemoClaw overlay patch cleanly in ${repo_dir}: ${patch_file}" >&2
      return 1
    }

    git -C "${repo_dir}" apply --whitespace=nowarn "${patch_file}"
  done
}

configure_nemoclaw_overlay_defaults() {
  local repo_dir="$1"
  local model="$2"
  local provider_base_url="$3"
  local provider_api="$4"
  local provider_key_env="$5"
  local dockerfile="${repo_dir}/Dockerfile"

  node - "${dockerfile}" "${model}" "${provider_base_url}" "${provider_api}" "${provider_key_env}" <<'EOF'
const fs = require("fs");

const [dockerfile, model, providerBaseUrl, providerApi, providerKeyEnv] = process.argv.slice(2);
let content = fs.readFileSync(dockerfile, "utf8");

const replacements = [
  [/^ARG NEMOCLAW_MODEL=.*$/m, `ARG NEMOCLAW_MODEL=${model}`],
  [/^ARG NEMOCLAW_PROVIDER_BASE_URL=.*$/m, `ARG NEMOCLAW_PROVIDER_BASE_URL=${providerBaseUrl}`],
  [/^ARG NEMOCLAW_PROVIDER_API=.*$/m, `ARG NEMOCLAW_PROVIDER_API=${providerApi}`],
  [/^ARG NEMOCLAW_PROVIDER_KEY_ENV=.*$/m, `ARG NEMOCLAW_PROVIDER_KEY_ENV=${providerKeyEnv}`],
];

for (const [pattern, value] of replacements) {
  if (!pattern.test(content)) {
    throw new Error(`Expected Dockerfile line not found for ${value}`);
  }
  content = content.replace(pattern, value);
}

fs.writeFileSync(dockerfile, content);
EOF
}

resolve_host_extra_ca_pem() {
  local explicit_file="${LOCAL_EXTRA_CA_FILE:-}"
  local explicit_common_name="${LOCAL_EXTRA_CA_COMMON_NAME:-}"
  local keychains=(
    "/Library/Keychains/System.keychain"
    "${HOME}/Library/Keychains/login.keychain-db"
  )
  local common_names=()
  local keychain=""
  local common_name=""
  local output=""

  if [[ -n "${explicit_file}" ]]; then
    if [[ ! -f "${explicit_file}" ]]; then
      echo "LOCAL_EXTRA_CA_FILE does not exist: ${explicit_file}" >&2
      return 1
    fi
    cat "${explicit_file}"
    return 0
  fi

  if ! command -v security >/dev/null 2>&1; then
    return 1
  fi

  if [[ -n "${explicit_common_name}" ]]; then
    common_names+=("${explicit_common_name}")
  fi
  common_names+=("Cisco Secure Access Root CA")

  for common_name in "${common_names[@]}"; do
    for keychain in "${keychains[@]}"; do
      [[ -f "${keychain}" ]] || continue
      output="$(security find-certificate -a -c "${common_name}" -p "${keychain}" 2>/dev/null || true)"
      if [[ -n "${output}" ]]; then
        printf '%s\n' "${output}"
        return 0
      fi
    done
  done

  return 1
}
