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

wait_http() {
  local name="$1"
  local url="$2"
  local ok_pattern="${3:-^(200|301|302|307|308)$}"
  local code=""
  local attempt

  for attempt in $(seq 1 45); do
    code="$(curl -sS --max-time 3 -o /tmp/livemask-deploy-service-${name}.out -w "%{http_code}" "${url}" 2>/dev/null || echo "000")"
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

deploy_one() {
  local service="$1"
  echo "[deploy-service] deploying ${service} with --no-deps"
  compose up -d --build --no-deps "${service}"
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

echo "[deploy-service] complete: ${SERVICE}"
