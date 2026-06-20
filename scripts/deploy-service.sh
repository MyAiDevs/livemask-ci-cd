#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
SERVICE="${SERVICE:-}"
PREPARE_CONTEXT=false
START_DEPS=false
SKIP_HEALTH=false
ALLOW_PARALLEL_STACKS=false

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-service.sh --service backend|admin|website|job-service|nodeagent|all [options]

Options:
  --compose FILE        Compose file to use. Defaults to infra/docker-compose.staging.yml.
  --prepare-context     Copy/check infra/_build_deps before building.
  --start-deps          Ensure postgres and redis are running before deploying app service(s).
  --skip-health         Skip post-deploy HTTP health checks.
  --allow-parallel-stacks
                        Override the dev/stage mutual-exclusion guard.

This script performs targeted service deployment only. It never runs
`docker compose down`, never deletes volumes, and never recreates unrelated
application services.

Admin and Website are frontend services. Their dev-runtime deploy path clears
safe build-context artifacts and uses `docker compose build --no-cache` before
recreating the target service, so stale Next.js/Vite bundles cannot survive a
dev push through Docker layer reuse.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      SERVICE="${2:-}"
      shift 2
      ;;
    --compose)
      COMPOSE_FILE="${2:-}"
      shift 2
      ;;
    --prepare-context)
      PREPARE_CONTEXT=true
      shift
      ;;
    --start-deps)
      START_DEPS=true
      shift
      ;;
    --skip-health)
      SKIP_HEALTH=true
      shift
      ;;
    --allow-parallel-stacks)
      ALLOW_PARALLEL_STACKS=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${SERVICE}" ]]; then
  echo "--service is required" >&2
  usage >&2
  exit 2
fi

case "${SERVICE}" in
  backend|admin|website|job-service|nodeagent|all) ;;
  *)
    echo "Unknown service: ${SERVICE}" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ "${COMPOSE_FILE}" != /* ]]; then
  COMPOSE_FILE="${REPO_ROOT}/${COMPOSE_FILE}"
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

cd "${REPO_ROOT}"

current_stack="${LIVEMASK_STACK_NAME:-livemask-dev}"

guard_single_runtime_stack() {
  if [[ "${ALLOW_PARALLEL_STACKS}" == "true" ]]; then
    echo "[deploy-service] parallel stack guard overridden"
    return 0
  fi

  local current_family=""
  case "${current_stack}" in
    livemask-dev) current_family="dev" ;;
    livemask-stage|livemask-staging) current_family="stage" ;;
    *)
      echo "[deploy-service] stack guard skipped for non dev/stage stack: ${current_stack}"
      return 0
      ;;
  esac

  local conflicting_pattern=""
  if [[ "${current_family}" == "dev" ]]; then
    conflicting_pattern='^livemask-(stage|staging)-'
  else
    conflicting_pattern='^livemask-dev-'
  fi

  local conflicts=""
  conflicts="$(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E "${conflicting_pattern}" || true)"
  if [[ -n "${conflicts}" ]]; then
    cat >&2 <<EOF
[deploy-service] Refusing to deploy ${current_stack}: another LiveMask runtime stack is running.

${conflicts}

livemask-dev and livemask-stage/livemask-staging are mutually exclusive on the
same host: choose one active stack only. Stop the other stack explicitly before
deploying this one.
EOF
    exit 20
  fi
}

guard_single_runtime_stack

if [[ "${PREPARE_CONTEXT}" == "true" ]]; then
  bash scripts/prepare-staging-build-context.sh
fi

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

is_frontend_service() {
  case "$1" in
    admin|website) return 0 ;;
    *) return 1 ;;
  esac
}

wait_http() {
  local name="$1"
  local url="$2"
  local ok_pattern="${3:-^(200|301|302|307|308)$}"
  local code=""
  local attempt

  for attempt in $(seq 1 45); do
    if ! code="$(curl -sS --max-time 3 -o /tmp/livemask-deploy-service-${name}.out -w "%{http_code}" "${url}" 2>/dev/null)"; then
      code="000"
    fi
    if [[ "${code}" =~ ${ok_pattern} ]]; then
      echo "[deploy-service] ${name} healthy: HTTP ${code} (${url})"
      return 0
    fi
    echo "[deploy-service] waiting for ${name}: attempt ${attempt}/45 HTTP ${code}"
    sleep 2
  done

  echo "[deploy-service] ${name} health failed: HTTP ${code} (${url})" >&2
  if [[ -s "/tmp/livemask-deploy-service-${name}.out" ]]; then
    sed -n '1,80p' "/tmp/livemask-deploy-service-${name}.out" >&2 || true
  fi
  return 1
}

build_context_dir_for_service() {
  case "$1" in
    backend) echo "backend" ;;
    admin) echo "admin" ;;
    website) echo "website" ;;
    job-service) echo "job-service" ;;
    nodeagent) echo "nodeagent" ;;
    *) return 1 ;;
  esac
}

print_build_context_ref() {
  local service="$1"
  local dir_name=""
  local context_dir=""
  local ref=""
  local latest_file=""

  dir_name="$(build_context_dir_for_service "${service}")" || return 0
  context_dir="${REPO_ROOT}/infra/_build_deps/${dir_name}"

  if [[ ! -d "${context_dir}" ]]; then
    echo "[deploy-service] build context for ${service}: missing (${context_dir})"
    return 0
  fi

  local git_root=""
  if git_root="$(git -C "${context_dir}" rev-parse --show-toplevel 2>/dev/null)" && [[ "${git_root}" == "${context_dir}" ]] && ref="$(git -C "${context_dir}" rev-parse --short HEAD 2>/dev/null)"; then
    echo "[deploy-service] build context for ${service}: git ${ref} (${context_dir})"
    return 0
  fi

  latest_file="$(find "${context_dir}" -type f \( -name go.mod -o -name package.json -o -name main.go \) -printf '%T@ %TY-%Tm-%TdT%TH:%TM:%TS %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2- || true)"
  if [[ -n "${latest_file}" ]]; then
    echo "[deploy-service] build context for ${service}: no git metadata, newest source ${latest_file}"
  else
    echo "[deploy-service] build context for ${service}: no git metadata and no source marker found (${context_dir})"
  fi
}

clear_frontend_build_context_cache() {
  local service="$1"
  local dir_name=""
  local context_dir=""
  local paths=()

  dir_name="$(build_context_dir_for_service "${service}")" || return 0
  context_dir="${REPO_ROOT}/infra/_build_deps/${dir_name}"
  [[ -d "${context_dir}" ]] || return 0

  case "${service}" in
    admin)
      paths=(.next .turbo node_modules/.cache node_modules/.vite)
      ;;
    website)
      paths=(dist .vite .turbo node_modules/.cache node_modules/.vite)
      ;;
    *)
      return 0
      ;;
  esac

  echo "[deploy-service] clearing frontend build-context cache for ${service}"
  for path in "${paths[@]}"; do
    if [[ -e "${context_dir}/${path}" ]]; then
      echo "[deploy-service]   rm -rf infra/_build_deps/${dir_name}/${path}"
      rm -rf "${context_dir:?}/${path}"
    fi
  done
}

deploy_one() {
  local service="$1"
  print_build_context_ref "${service}"
  if is_frontend_service "${service}"; then
    clear_frontend_build_context_cache "${service}"
    echo "[deploy-service] building ${service} with --no-cache"
    compose build --no-cache "${service}"
    echo "[deploy-service] deploying ${service} with --no-build --no-deps --force-recreate"
    compose up -d --no-build --no-deps --force-recreate "${service}"
    return 0
  fi

  if [[ "${service}" == "nodeagent" ]]; then
    echo "[deploy-service] deploying ${service} with --build --no-deps"
    echo "[deploy-service] nodeagent is not force-recreated because it owns the large VPN port pool"
    compose up -d --build --no-deps "${service}"
    return 0
  fi

  echo "[deploy-service] deploying ${service} with --build --no-deps --force-recreate"
  compose up -d --build --no-deps --force-recreate "${service}"
}

health_one() {
  local service="$1"
  case "${service}" in
    backend)
      wait_http backend "http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-64003}/api/v1/health" "^200$"
      ;;
    admin)
      wait_http admin "http://127.0.0.1:${LIVEMASK_ADMIN_PORT:-64001}/login"
      ;;
    website)
      wait_http website "http://127.0.0.1:${LIVEMASK_WEBSITE_PORT:-64000}/"
      ;;
    job-service)
      wait_http job-service "http://127.0.0.1:${LIVEMASK_JOB_SERVICE_PORT:-64002}/healthz" "^200$"
      ;;
    nodeagent)
      wait_http nodeagent "http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT:-65000}/app/probe" "^200$"
      ;;
  esac
}

seed_job_service_default_schedules() {
  local enabled="${JOB_SERVICE_SEED_DEFAULT_SCHEDULES:-true}"
  if [[ "${enabled}" != "true" ]]; then
    echo "[deploy-service] job-service default schedule seed skipped (JOB_SERVICE_SEED_DEFAULT_SCHEDULES=${enabled})"
    return 0
  fi

  local seed_script=""
  for candidate in \
    "${REPO_ROOT}/../livemask-job-service/scripts/seed-default-schedules.sh" \
    "${REPO_ROOT}/infra/_build_deps/job-service/scripts/seed-default-schedules.sh"; do
    if [[ -f "${candidate}" ]]; then
      seed_script="${candidate}"
      break
    fi
  done
  if [[ -z "${seed_script}" ]]; then
    echo "[deploy-service] ERROR: job-service schedule seed script not found" >&2
    echo "[deploy-service] expected ../livemask-job-service/scripts/seed-default-schedules.sh or infra/_build_deps/job-service/scripts/seed-default-schedules.sh" >&2
    return 1
  fi

  echo "[deploy-service] seeding job-service default schedules via ${seed_script}"
  JOB_SERVICE_URL="${JOB_SERVICE_URL:-http://127.0.0.1:${LIVEMASK_JOB_SERVICE_PORT:-64002}}" \
  JOB_SERVICE_INTERNAL_BEARER_TOKEN="${JOB_SERVICE_INTERNAL_BEARER_TOKEN:-${INTERNAL_SERVICE_SECRET:-local-dev-secret}}" \
    bash "${seed_script}"
}

if [[ "${START_DEPS}" == "true" ]]; then
  echo "[deploy-service] ensuring infrastructure deps are running"
  compose up -d postgres redis
fi

services=()
if [[ "${SERVICE}" == "all" ]]; then
  services=(backend job-service admin website nodeagent)
else
  services=("${SERVICE}")
fi

for service in "${services[@]}"; do
  deploy_one "${service}"
done

compose ps

if [[ "${SKIP_HEALTH}" != "true" ]]; then
  for service in "${services[@]}"; do
    health_one "${service}"
  done
fi

for service in "${services[@]}"; do
  if [[ "${service}" == "job-service" ]]; then
    seed_job_service_default_schedules
  fi
done

echo "[deploy-service] complete: ${SERVICE}"
