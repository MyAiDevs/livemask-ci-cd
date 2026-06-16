#!/usr/bin/env bash
# TASK-CICD-RUNNER-BACKLOG-001 — Collect runtime status evidence for Lark notification.
#
# Collects:
#   - Git refs of all LiveMask repos
#   - Docker compose container status
#   - Health endpoint results (backend + job-service)
#   - Error logs from failed/exited containers
#
# Output: JSON to stdout, or file path via --output.
#
# Usage:
#   bash scripts/dev-runtime-status.sh [options]
#
# Options:
#   --compose FILE   Docker compose file (default: infra/docker-compose.staging.yml)
#   --env TYPE       Environment type: staging or dev (default: staging)
#   --output FILE    Write JSON status to FILE instead of stdout
#   --collect-only   Only collect status; skip health checks (for early failure)
#   --help           Show this help

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
ENV_TYPE="staging"
OUTPUT_FILE=""
COLLECT_ONLY=false

LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"

# ============================================================
# Parse args
# ============================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose)  COMPOSE_FILE="${2:-}"; shift 2 ;;
    --env)      ENV_TYPE="${2:-staging}"; shift 2 ;;
    --output)   OUTPUT_FILE="${2:-}"; shift 2 ;;
    --collect-only) COLLECT_ONLY=true; shift ;;
    --help|-h)  sed -n '3,/^# =/p' "${BASH_SOURCE[0]}" | sed 's/^# //;s/^#$//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ============================================================
# Resolve compose file path
# ============================================================
if [[ ! "${COMPOSE_FILE}" == /* ]]; then
  COMPOSE_FILE="${REPO_ROOT}/${COMPOSE_FILE}"
fi
COMPOSE_DIR="$(cd "$(dirname "${COMPOSE_FILE}")" && pwd)"
COMPOSE_BASENAME="$(basename "${COMPOSE_FILE}")"

# ============================================================
# Runner host info
# ============================================================
HOSTNAME="$(hostname 2>/dev/null || echo 'unknown')"
UPTIME="$(uptime 2>/dev/null | sed 's/,.*//' || echo 'unknown')"
BACKEND_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-64003}"
ADMIN_PORT="${LIVEMASK_ADMIN_PORT:-64001}"
WEBSITE_PORT="${LIVEMASK_WEBSITE_PORT:-64000}"
JOB_PORT="${LIVEMASK_JOB_SERVICE_PORT:-64002}"
NODEAGENT_PORT="${LIVEMASK_NODEAGENT_PORT:-65000}"
NODEAGENT_VPN_PORT_RANGE="${SINGBOX_PUBLIC_ENDPOINT_PORT_START:-65001}-${SINGBOX_PUBLIC_ENDPOINT_PORT_END:-65535}"
POSTGRES_HOST_PORT="${POSTGRES_PORT:-15432}"
REDIS_HOST_PORT="${REDIS_PORT:-16379}"

# ============================================================
# 1. Container status via Docker labels
# ============================================================
CONTAINER_JSON="[]"
CONTAINER_SUMMARY=""
FAILED_CONTAINERS=""
ALL_CONTAINERS_UP=true
COMPOSE_UP_DETECTED=false

if docker info &>/dev/null; then
  COMPOSE_PROJECT="livemask-${ENV_TYPE}"
  # Avoid `docker compose ps --format json`: NodeAgent exposes a very large
  # TCP/UDP port range, and compose JSON status can hang while expanding it.
  PS_OUTPUT=$(
    docker ps -a \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
      --format '{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Label "com.docker.compose.service"}}' \
      2>/dev/null || true
  )
  if [[ -n "${PS_OUTPUT}" ]]; then
    CONTAINER_JSON=$(
      printf '%s\n' "${PS_OUTPUT}" | python3 -c '
import json
import sys

containers = []
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    parts = raw.split("\t", 3)
    while len(parts) < 4:
        parts.append("")
    name, state, status, service = parts
    containers.append({
        "Name": name,
        "Service": service,
        "State": state,
        "Status": status,
    })
print(json.dumps(containers))
'
    )

    COMPOSE_UP_DETECTED=true
    RUNNING_COUNT=$(echo "${CONTAINER_JSON}" | python3 -c "import sys,json; print(sum(1 for c in json.load(sys.stdin) if c.get('State') == 'running'))" 2>/dev/null || echo 0)
    TOTAL_COUNT=$(echo "${CONTAINER_JSON}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    CONTAINER_SUMMARY="${RUNNING_COUNT}/${TOTAL_COUNT} running"

    while IFS=$'\t' read -r name state status service; do
      if [[ -z "${name}" ]]; then continue; fi
      if [[ "${state}" != "running" ]]; then
        ALL_CONTAINERS_UP=false
        FAILED_CONTAINERS+="${name} (${state}: ${status})\n"
      fi
    done <<< "${PS_OUTPUT}"
  fi
fi

# ============================================================
# 2. Git refs (from CI env vars or workspace repos)
# ============================================================
collect_ref() {
  local var_name="$1"
  local repo_name="$2"
  local default_val="$3"
  local ref="${!var_name:-${default_val}}"
  local commit=""

  # Try to get actual commit from workspace
  local ws_repo="${LIVEMASK_WORKSPACE_ROOT}/${repo_name}"
  if [[ -d "${ws_repo}/.git" ]]; then
    commit="$(git -C "${ws_repo}" rev-parse --short HEAD 2>/dev/null || echo "")"
  fi

  if [[ -n "$commit" ]]; then
    echo "${ref} (${commit})"
  else
    echo "${ref}"
  fi
}

BACKEND_REF_VALUE="$(collect_ref "BACKEND_REF" "livemask-backend" "dev")"
JOB_SERVICE_REF_VALUE="$(collect_ref "JOB_SERVICE_REF" "livemask-job-service" "dev")"
ADMIN_REF_VALUE="$(collect_ref "ADMIN_REF" "livemask-admin" "dev")"
WEBSITE_REF_VALUE="$(collect_ref "WEBSITE_REF" "livemask-website" "dev")"
APP_REF_VALUE="$(collect_ref "APP_REF" "livemask-app" "dev")"
NODEAGENT_REF_VALUE="$(collect_ref "NODEAGENT_REF" "livemask-nodeagent" "dev")"

bool_json() {
  case "$1" in
    true|TRUE|True|1|yes|YES) echo "true" ;;
    *) echo "false" ;;
  esac
}

http_code_with_retries() {
  local url="$1"
  local attempts="${2:-15}"
  local delay="${3:-2}"
  local code="000"

  for attempt in $(seq 1 "${attempts}"); do
    code="$(curl -sS --max-time 3 -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || true)"
    if [[ "${code}" =~ ^(200|301|302|307|308)$ ]]; then
      echo "${code}"
      return 0
    fi
    sleep "${delay}"
  done

  if [[ -z "${code}" ]]; then
    code="000"
  fi
  echo "${code}"
  return 1
}

# ============================================================
# 3. Health endpoints
# ============================================================
HEALTH_RESULTS="[]"
HEALTH_ALL_PASS=true
HEALTH_DETAILS=""

if [[ "${COLLECT_ONLY}" == "false" ]] && docker info &>/dev/null; then
  # Backend health
  BE_HEALTH_URL="http://127.0.0.1:${BACKEND_PORT}/api/v1/health"
  BE_HEALTH_RESPONSE=""
  BE_HEALTH_OK=false
  BE_HEALTH="unknown"

  for attempt in $(seq 1 5); do
    BE_HEALTH_RESPONSE=$(curl -sS --max-time 3 "${BE_HEALTH_URL}" 2>/dev/null || true)
    if [[ -n "${BE_HEALTH_RESPONSE}" ]]; then
      BE_HEALTH_OK=true
      BE_HEALTH=$(echo "${BE_HEALTH_RESPONSE}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    s=d.get('status','unknown')
    db=d.get('db_connected','?')
    redis=d.get('redis_connected','?')
    print(f'status={s}, db={db}, redis={redis}')
except: print('parse_error')
" 2>/dev/null || echo "parse_error")
      break
    fi
    sleep 2
  done

  if [[ "${BE_HEALTH_OK}" != "true" ]]; then
    HEALTH_ALL_PASS=false
    HEALTH_DETAILS+="backend health: TIMEOUT (${BE_HEALTH_URL})\n"
  else
    if echo "${BE_HEALTH}" | grep -qv "status=ok"; then
      HEALTH_ALL_PASS=false
    fi
    HEALTH_DETAILS+="backend health: ${BE_HEALTH}\n"
  fi

  HEALTH_RESULTS=$(python3 -c "
import json
h=[{
  'service': 'backend',
  'endpoint': '${BE_HEALTH_URL}',
  'reachable': ${BE_HEALTH_OK},
  'result': '${BE_HEALTH}'
}]
print(json.dumps(h))
" 2>/dev/null || echo "$HEALTH_RESULTS")

  # Job-service health (if running)
  JS_HEALTH_URL="http://127.0.0.1:${JOB_PORT}/healthz"
  JS_HEALTH_RESPONSE=$(curl -sS --max-time 3 "${JS_HEALTH_URL}" 2>/dev/null || true)
  JS_HEALTH_OK=false
  if [[ -n "${JS_HEALTH_RESPONSE}" ]]; then
    JS_HEALTH_OK=true
    HEALTH_DETAILS+="job-service health: reachable\n"
  fi

  HEALTH_RESULTS=$(python3 -c "
import json
results = json.loads('''${HEALTH_RESULTS}''')
results.append({
  'service': 'job-service',
  'endpoint': '${JS_HEALTH_URL}',
  'reachable': ${JS_HEALTH_OK},
  'result': '${JS_HEALTH_RESPONSE}' if '${JS_HEALTH_RESPONSE}' else 'timeout'
})
print(json.dumps(results))
" 2>/dev/null || echo "$HEALTH_RESULTS")

  # Admin and website HTTP reachability
  ADMIN_URL="http://127.0.0.1:${ADMIN_PORT}/login"
  ADMIN_CODE=$(http_code_with_retries "${ADMIN_URL}" 20 2 || true)
  if [[ "${ADMIN_CODE}" =~ ^(200|301|302|307|308)$ ]]; then
    HEALTH_DETAILS+="admin page: HTTP ${ADMIN_CODE}\n"
  else
    HEALTH_ALL_PASS=false
    HEALTH_DETAILS+="admin page: HTTP ${ADMIN_CODE} (${ADMIN_URL})\n"
  fi

  WEBSITE_URL="http://127.0.0.1:${WEBSITE_PORT}/"
  WEBSITE_CODE=$(http_code_with_retries "${WEBSITE_URL}" 10 2 || true)
  if [[ "${WEBSITE_CODE}" =~ ^(200|301|302|307|308)$ ]]; then
    HEALTH_DETAILS+="website page: HTTP ${WEBSITE_CODE}\n"
  else
    HEALTH_ALL_PASS=false
    HEALTH_DETAILS+="website page: HTTP ${WEBSITE_CODE} (${WEBSITE_URL})\n"
  fi
fi

# ============================================================
# 4. Error excerpts from failed containers
# ============================================================
ERROR_EXCERPTS=""
if [[ -n "${FAILED_CONTAINERS}" ]]; then
  # Collect recent logs from each failed container
  while IFS= read -r fail_entry; do
    if [[ -z "$fail_entry" ]]; then continue; fi
    container_name=$(echo "$fail_entry" | cut -d' ' -f1)
    if timeout 5 docker inspect "${container_name}" &>/dev/null; then
      log_snippet=$(timeout 10 docker logs "${container_name}" --tail 30 2>&1 | head -30 || true)
      if [[ -n "${log_snippet}" ]]; then
        ERROR_EXCERPTS+="--- ${container_name} logs (last 30) ---\n${log_snippet}\n"
      fi
    fi
  done <<< "$(printf "%b" "${FAILED_CONTAINERS}")"
fi

# ============================================================
# 5. Assemble JSON
# ============================================================
COMPOSE_UP_DETECTED_JSON="$(bool_json "${COMPOSE_UP_DETECTED}")"
ALL_CONTAINERS_UP_JSON="$(bool_json "${ALL_CONTAINERS_UP}")"
HEALTH_ALL_PASS_JSON="$(bool_json "${HEALTH_ALL_PASS}")"

STATUS_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${STATUS_TMP_DIR}"' EXIT
CONTAINER_JSON_FILE="${STATUS_TMP_DIR}/containers.json"
FAILED_CONTAINERS_FILE="${STATUS_TMP_DIR}/failed-containers.txt"
HEALTH_DETAILS_FILE="${STATUS_TMP_DIR}/health-details.txt"
ERROR_EXCERPTS_FILE="${STATUS_TMP_DIR}/error-excerpts.txt"
printf '%s' "${CONTAINER_JSON}" > "${CONTAINER_JSON_FILE}"
printf '%b' "${FAILED_CONTAINERS}" > "${FAILED_CONTAINERS_FILE}"
printf '%b' "${HEALTH_DETAILS}" > "${HEALTH_DETAILS_FILE}"
printf '%b' "${ERROR_EXCERPTS}" > "${ERROR_EXCERPTS_FILE}"

STATUS_JSON=$(
FAILED_CONTAINERS_FILE_ENV="${FAILED_CONTAINERS_FILE}" \
HEALTH_DETAILS_FILE_ENV="${HEALTH_DETAILS_FILE}" \
ERROR_EXCERPTS_FILE_ENV="${ERROR_EXCERPTS_FILE}" \
CONTAINER_JSON_FILE_ENV="${CONTAINER_JSON_FILE}" \
HOSTNAME_ENV="${HOSTNAME}" \
UPTIME_ENV="${UPTIME}" \
ENV_TYPE_ENV="${ENV_TYPE}" \
COMPOSE_BASENAME_ENV="${COMPOSE_BASENAME}" \
BACKEND_PORT_ENV="${BACKEND_PORT}" \
ADMIN_PORT_ENV="${ADMIN_PORT}" \
WEBSITE_PORT_ENV="${WEBSITE_PORT}" \
JOB_PORT_ENV="${JOB_PORT}" \
NODEAGENT_PORT_ENV="${NODEAGENT_PORT}" \
NODEAGENT_VPN_PORT_RANGE_ENV="${NODEAGENT_VPN_PORT_RANGE}" \
POSTGRES_HOST_PORT_ENV="${POSTGRES_HOST_PORT}" \
REDIS_HOST_PORT_ENV="${REDIS_HOST_PORT}" \
COMPOSE_UP_DETECTED_ENV="${COMPOSE_UP_DETECTED_JSON}" \
ALL_CONTAINERS_UP_ENV="${ALL_CONTAINERS_UP_JSON}" \
HEALTH_ALL_PASS_ENV="${HEALTH_ALL_PASS_JSON}" \
CONTAINER_SUMMARY_ENV="${CONTAINER_SUMMARY}" \
BACKEND_REF_VALUE_ENV="${BACKEND_REF_VALUE}" \
JOB_SERVICE_REF_VALUE_ENV="${JOB_SERVICE_REF_VALUE}" \
ADMIN_REF_VALUE_ENV="${ADMIN_REF_VALUE}" \
WEBSITE_REF_VALUE_ENV="${WEBSITE_REF_VALUE}" \
NODEAGENT_REF_VALUE_ENV="${NODEAGENT_REF_VALUE}" \
APP_REF_VALUE_ENV="${APP_REF_VALUE}" \
python3 -c "
import json
import os

def read_text_env_path(env_key, default=''):
    path = os.environ.get(env_key)
    if not path:
        return default
    try:
        with open(path, 'r', encoding='utf-8') as handle:
            return handle.read()
    except Exception:
        return default

containers_raw = read_text_env_path('CONTAINER_JSON_FILE_ENV', '[]') or '[]'
try:
    containers = json.loads(containers_raw)
except Exception:
    containers = []

failed_containers = read_text_env_path('FAILED_CONTAINERS_FILE_ENV').strip()
health_details = read_text_env_path('HEALTH_DETAILS_FILE_ENV').strip()
error_excerpts = read_text_env_path('ERROR_EXCERPTS_FILE_ENV').strip()

backend_port = os.environ['BACKEND_PORT_ENV']
admin_port = os.environ['ADMIN_PORT_ENV']
website_port = os.environ['WEBSITE_PORT_ENV']
job_port = os.environ['JOB_PORT_ENV']
nodeagent_port = os.environ['NODEAGENT_PORT_ENV']
nodeagent_vpn_range = os.environ['NODEAGENT_VPN_PORT_RANGE_ENV']

result = {
    'schema_version': 1,
    'timestamp': '$(date -u +'%Y-%m-%dT%H:%M:%SZ')',
    'hostname': os.environ.get('HOSTNAME_ENV', 'unknown'),
    'uptime': os.environ.get('UPTIME_ENV', 'unknown'),
    'environment': os.environ.get('ENV_TYPE_ENV', 'staging'),
    'compose_file': os.environ.get('COMPOSE_BASENAME_ENV', ''),
    'compose_project': 'livemask-' + os.environ.get('ENV_TYPE_ENV', 'staging'),
    'host_port_map': {
        'backend': backend_port + '->8080',
        'admin': admin_port + '->3000',
        'website': website_port + '->3000',
        'job-service': job_port + '->64002',
        'nodeagent': nodeagent_port + '->65000',
        'nodeagent-vpn': nodeagent_vpn_range + '->' + nodeagent_vpn_range + '/tcp,udp',
        'postgres': os.environ['POSTGRES_HOST_PORT_ENV'] + '->5432',
        'redis': os.environ['REDIS_HOST_PORT_ENV'] + '->6379'
    },
    'host_health_urls': {
        'backend': 'http://127.0.0.1:' + backend_port + '/api/v1/health',
        'admin': 'http://127.0.0.1:' + admin_port + '/login',
        'website': 'http://127.0.0.1:' + website_port + '/',
        'job-service': 'http://127.0.0.1:' + job_port + '/healthz'
    },
    'compose_up_detected': json.loads(os.environ['COMPOSE_UP_DETECTED_ENV']),
    'all_containers_up': json.loads(os.environ['ALL_CONTAINERS_UP_ENV']),
    'container_summary': os.environ.get('CONTAINER_SUMMARY_ENV', ''),
    'containers': containers,
    'failed_containers': failed_containers,
    'refs': {
        'BACKEND_REF': os.environ.get('BACKEND_REF_VALUE_ENV', ''),
        'JOB_SERVICE_REF': os.environ.get('JOB_SERVICE_REF_VALUE_ENV', ''),
        'ADMIN_REF': os.environ.get('ADMIN_REF_VALUE_ENV', ''),
        'WEBSITE_REF': os.environ.get('WEBSITE_REF_VALUE_ENV', ''),
        'NODEAGENT_REF': os.environ.get('NODEAGENT_REF_VALUE_ENV', '')
    },
    'local_only_refs': {
        'APP_REF': os.environ.get('APP_REF_VALUE_ENV', '')
    },
    'compose_up_result': os.environ.get('COMPOSE_UP_DETECTED_ENV', 'false'),
    'health_all_pass': json.loads(os.environ['HEALTH_ALL_PASS_ENV']),
    'health_details': health_details if health_details else '',
    'error_excerpts': error_excerpts if error_excerpts else ''
}

print(json.dumps(result, indent=2))
")

# ============================================================
# Output
# ============================================================
if [[ -n "${OUTPUT_FILE}" ]]; then
  echo "${STATUS_JSON}" > "${OUTPUT_FILE}"
  echo "${STATUS_JSON}"
else
  echo "${STATUS_JSON}"
fi
