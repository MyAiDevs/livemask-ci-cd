#!/usr/bin/env bash
# Shared local Docker Compose file resolution (base + hot reload override).

local_compose_primary_file() {
  local repo_dir="${1:-${REPO_DIR:-}}"
  echo "${repo_dir}/infra/docker-compose.local.yml"
}

local_compose_hot_file() {
  local repo_dir="${1:-${REPO_DIR:-}}"
  echo "${repo_dir}/infra/docker-compose.hot.yml"
}

# Returns 0 when hot reload overlay should be applied.
local_compose_hot_reload_enabled() {
  case "${LIVEMASK_LOCAL_HOT_RELOAD:-true}" in
    0|false|FALSE|no|NO|off|OFF)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

# Usage: local_compose_file_args <repo_dir> <primary_compose_path> <hot_reload_enabled>
# Prints compose -f arguments to stdout (one path per line).
local_compose_file_args() {
  local repo_dir="$1"
  local primary="$2"
  local hot_enabled="${3:-true}"

  printf '%s\n' "${primary}"
  if [[ "${hot_enabled}" == "true" ]] && local_compose_hot_reload_enabled; then
    local hot
    hot="$(local_compose_hot_file "${repo_dir}")"
    if [[ -f "${hot}" && "${primary}" == *"docker-compose.local.yml" ]]; then
      printf '%s\n' "${hot}"
    fi
  fi
}
