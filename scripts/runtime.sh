#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$(cd "${REPO_DIR}/.." && pwd)}"
export LIVEMASK_WORKSPACE_ROOT

command="${1:-}"
if [[ -z "${command}" ]]; then
  command="help"
else
  shift || true
fi

LOCAL_COMPOSE_LIB="${SCRIPT_DIR}/lib/local-compose.sh"
if [[ -f "${LOCAL_COMPOSE_LIB}" ]]; then
  # shellcheck source=scripts/lib/local-compose.sh
  source "${LOCAL_COMPOSE_LIB}"
fi

env_file=""
compose_file="${REPO_DIR}/infra/docker-compose.local.yml"
runtime_mode="local"
services="backend"
with_deps=true
hot_reload_enabled=true
pull_images=false

usage() {
  cat <<'EOF'
Usage:
  bash scripts/runtime.sh start   [options]
  bash scripts/runtime.sh stop    [options]
  bash scripts/runtime.sh restart [options]
  bash scripts/runtime.sh status  [options]
  bash scripts/runtime.sh pull    [options]
  bash scripts/runtime.sh logs    [options]

Options:
  --env-file FILE          Load independent runtime config file.
  --compose FILE           Compose file to use. Defaults to infra/docker-compose.local.yml.
  --mode local|runtime     local=source-mounted containers, runtime=image deployment.
  --services LIST          Comma-separated: backend,admin,website,nodeagent,job-service,all.
  --no-deps                Do not start internal PostgreSQL/Redis containers.
  --no-hot-reload          Disable docker-compose.hot.yml overlay (Go rebuild loop + dev polling).
  --auto-reload            Alias for default local hot reload (kept for compatibility).
  --pull                   Pull images before start.

Local mode enables hot reload by default:
  - Backend / Job Service / NodeAgent: mounted Go source checksum watcher
  - Admin / Website: dev-server HMR with Docker Desktop polling

Examples:
  bash scripts/runtime.sh start --mode local --services all
  bash scripts/runtime.sh start --mode runtime --env-file infra/env/production.env --services backend,admin --no-deps
  bash scripts/runtime.sh restart --mode runtime --env-file infra/env/staging.env --services all
EOF
}

print_local_urls() {
  cat <<EOF
Fixed local URLs:
  Backend   http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}
  Admin     http://127.0.0.1:${LIVEMASK_ADMIN_PORT:-3001}
  Website   http://127.0.0.1:${LIVEMASK_WEBSITE_PORT:-3002}
  App Web   http://127.0.0.1:${LIVEMASK_APP_WEB_PORT:-3003}
  NodeAgent http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT:-19090}
  JobSvc    http://127.0.0.1:${LIVEMASK_JOB_SERVICE_PORT:-19191}
EOF
}

print_nodeagent_log_upload_status() {
  local container_id=""
  local enabled=""

  container_id="$(compose_base ps -q nodeagent 2>/dev/null || true)"
  if [[ -z "${container_id}" ]]; then
    echo "NodeAgent log upload: nodeagent container not running"
    return 0
  fi

  enabled="$(docker inspect "${container_id}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= '$1 == "LOG_UPLOAD_ENABLED" {print $2; exit}')"
  if [[ -z "${enabled}" ]]; then
    echo "NodeAgent log upload: LOG_UPLOAD_ENABLED not set"
    return 0
  fi

  echo "NodeAgent log upload: LOG_UPLOAD_ENABLED=${enabled}"
  if [[ "${enabled}" != "true" ]]; then
    echo "  Admin node logs read Backend observability data; with upload disabled, the UI can show stale DB logs."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      env_file="$2"
      shift 2
      ;;
    --compose)
      compose_file="$2"
      shift 2
      ;;
    --mode)
      case "$2" in
        local)
          runtime_mode="local"
          compose_file="${REPO_DIR}/infra/docker-compose.local.yml"
          ;;
        runtime)
          runtime_mode="runtime"
          compose_file="${REPO_DIR}/infra/docker-compose.runtime.yml"
          hot_reload_enabled=false
          ;;
        *)
          echo "Unknown mode: $2" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --services)
      services="$2"
      shift 2
      ;;
    --no-deps)
      with_deps=false
      shift
      ;;
    --no-hot-reload)
      hot_reload_enabled=false
      shift
      ;;
    --auto-reload)
      hot_reload_enabled=true
      shift
      ;;
    --pull)
      pull_images=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${env_file}" != "" ]]; then
  if [[ ! -f "${env_file}" && -f "${REPO_DIR}/${env_file}" ]]; then
    env_file="${REPO_DIR}/${env_file}"
  fi
  if [[ ! -f "${env_file}" ]]; then
    echo "Env file not found: ${env_file}" >&2
    exit 1
  fi
fi

profiles=()
service_args=()

add_profile() {
  local profile="$1"
  for existing in "${profiles[@]:-}"; do
    [[ "${existing}" == "${profile}" ]] && return 0
  done
  profiles+=("${profile}")
}

IFS=',' read -r -a selected_services <<<"${services}"
for service in "${selected_services[@]}"; do
  case "${service}" in
    all)
      add_profile backend
      add_profile admin
      add_profile website
      add_profile nodeagent
      add_profile job-service
      service_args+=(backend admin website)
      service_args+=(nodeagent job-service)
      ;;
    app)
      echo "Service 'app' is not started by Docker runtime. Use livemask-app/scripts/local-app.sh to run Flutter locally." >&2
      exit 2
      ;;
    backend|admin|website|nodeagent|job-service)
      add_profile "${service}"
      service_args+=("${service}")
      ;;
    "")
      ;;
    *)
      echo "Unknown service: ${service}" >&2
      exit 2
      ;;
  esac
done

if [[ "${with_deps}" == "true" ]]; then
  add_profile deps
  service_args=(postgres redis "${service_args[@]}")
fi

compose_base() {
  local args=()
  local compose_files=()
  local file

  [[ "${env_file}" != "" ]] && args+=(--env-file "${env_file}")
  for profile in "${profiles[@]:-}"; do
    args+=(--profile "${profile}")
  done

  if [[ "${runtime_mode}" == "local" && "${hot_reload_enabled}" == "true" ]]; then
    while IFS= read -r file; do
      [[ -n "${file}" ]] && compose_files+=(-f "${file}")
    done < <(local_compose_file_args "${REPO_DIR}" "${compose_file}" true)
  else
    compose_files=(-f "${compose_file}")
  fi

  docker compose "${args[@]}" "${compose_files[@]}" "$@"
}

print_hot_reload_mode() {
  if [[ "${runtime_mode}" != "local" ]]; then
    return 0
  fi
  if [[ "${hot_reload_enabled}" == "true" ]] && local_compose_hot_reload_enabled; then
    echo "Local hot reload: ENABLED (docker-compose.hot.yml overlay)"
  else
    echo "Local hot reload: DISABLED (plain go run / no polling overlay)"
  fi
}

case "${command}" in
  start)
    print_hot_reload_mode
    [[ "${pull_images}" == "true" ]] && compose_base pull "${service_args[@]}"
    compose_base up -d --force-recreate "${service_args[@]}"
    ;;
  stop)
    compose_base down --remove-orphans
    ;;
  restart)
    print_hot_reload_mode
    compose_base down --remove-orphans
    [[ "${pull_images}" == "true" ]] && compose_base pull "${service_args[@]}"
    compose_base up -d --force-recreate "${service_args[@]}"
    ;;
  status)
    compose_base ps -a
    echo
    print_hot_reload_mode
    echo
    print_local_urls
    echo
    echo "Backend health:"
    curl -fsS "http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}/api/v1/health" 2>/dev/null || echo "backend health unavailable"
    echo
    echo "Admin:"
    curl -fsS -o /dev/null -w "HTTP %{http_code}\n" "http://127.0.0.1:${LIVEMASK_ADMIN_PORT:-3001}/login" 2>/dev/null || echo "admin unavailable"
    echo
    echo "Website:"
    curl -fsS -o /dev/null -w "HTTP %{http_code}\n" "http://127.0.0.1:${LIVEMASK_WEBSITE_PORT:-3002}/" 2>/dev/null || echo "website unavailable"
    echo
    echo "App:"
    echo "managed locally by livemask-app/scripts/local-app.sh, not Docker runtime"
    echo
    echo "NodeAgent status:"
    curl -fsS "http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT:-19090}/config/status" 2>/dev/null || echo "nodeagent status unavailable"
    print_nodeagent_log_upload_status
    echo
    echo "Job Service health:"
    curl -fsS "http://127.0.0.1:${LIVEMASK_JOB_SERVICE_PORT:-19191}/healthz" 2>/dev/null || echo "job service health unavailable"
    echo
    ;;
  pull)
    compose_base pull "${service_args[@]}"
    ;;
  logs)
    compose_base logs -f "${service_args[@]}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: ${command}" >&2
    usage >&2
    exit 2
    ;;
esac
