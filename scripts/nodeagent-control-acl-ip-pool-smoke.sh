#!/usr/bin/env bash
# TASK-NODEAGENT-CONTROL-ACL-IP-POOL-DISCOVERY-001
# NodeAgent Control ACL IP Pool Discovery Smoke
#
# Verifies the P1 API contract without requiring a real external NodeAgent:
#   [1] Backend health
#   [2] JobService exposes backend_ip_pool_refresh
#   [3] Backend internal executor accepts discovered source records
#   [4] Backend refuses an empty publish for a fresh environment
#   [5] Admin source list shows persisted source records and projection
#   [6] Optional publish mode updates nodeagent.runtime_config.control_acl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

API_BASE="${API_BASE:-$(lm_backend_base_url)}"
JOB_BASE="${JOB_BASE:-$(lm_job_service_url)}"
INTERNAL_SECRET="${LIVEMASK_INTERNAL_SERVICE_SECRET:-dev-internal-secret}"
ADMIN_EMAIL="${LIVEMASK_ADMIN_EMAIL:-admin@livemask.dev}"
ADMIN_PASSWORD="${LIVEMASK_ADMIN_PASSWORD:-AdminPass123!}"
TIMESTAMP="$(date +%s)"
SMOKE_ENV="${LIVEMASK_CONTROL_ACL_SMOKE_ENV:-smoke-${TIMESTAMP}}"
PUBLISH_SMOKE="${LIVEMASK_CONTROL_ACL_SMOKE_PUBLISH:-0}"

FAILED=0
PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
SUMMARY_LINES=()

pass() {
  echo "  PASS: $1"
  SUMMARY_LINES+=("PASS: $1")
  PASS_COUNT=$((PASS_COUNT + 1))
}

skip() {
  echo "  SKIP: $1"
  SUMMARY_LINES+=("SKIP: $1")
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

fail() {
  echo "  FAIL: $1"
  SUMMARY_LINES+=("FAIL: $1")
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED=1
}

json_value() {
  local path="$1"
  python3 -c '
import json, sys
data=json.load(sys.stdin)
cur=data
for part in sys.argv[1].split("."):
    if part == "":
        continue
    if isinstance(cur, dict):
        cur = cur.get(part, "")
    elif isinstance(cur, list):
        try:
            cur = cur[int(part)]
        except Exception:
            cur = ""
    else:
        cur = ""
    if cur == "":
        break
print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur, separators=(",",":")))
' "${path}" 2>/dev/null || true
}

http_json() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local headers=("${@:4}")
  local tmp
  tmp="$(mktemp)"
  local code
  if [[ -n "${body}" ]]; then
    code=$(curl -sS --max-time 10 -o "${tmp}" -w "%{http_code}" -X "${method}" "${url}" \
      -H "Content-Type: application/json" "${headers[@]}" -d "${body}" 2>/dev/null || echo "000")
  else
    code=$(curl -sS --max-time 10 -o "${tmp}" -w "%{http_code}" -X "${method}" "${url}" \
      "${headers[@]}" 2>/dev/null || echo "000")
  fi
  printf '%s\n%s' "$(cat "${tmp}")" "${code}"
  rm -f "${tmp}"
}

echo "================================================"
echo " TASK-NODEAGENT-CONTROL-ACL-IP-POOL-DISCOVERY-001"
echo " NodeAgent Control ACL IP Pool Discovery Smoke"
echo "================================================"
lm_runtime_status_report
echo "Smoke environment: ${SMOKE_ENV}"
echo ""

echo "--- [1] Backend Health ---"
if lm_backend_ready; then
  pass "Backend health ok"
else
  fail "Backend health is not ready at ${API_BASE}"
fi

echo "--- [2] JobService Definition ---"
JOB_DEF_RAW=$(http_json GET "${JOB_BASE}/internal/jobs" "" -H "X-Internal-Secret: ${INTERNAL_SECRET}")
JOB_DEF_BODY="$(printf '%s\n' "${JOB_DEF_RAW}" | sed '$d')"
JOB_DEF_CODE="$(printf '%s\n' "${JOB_DEF_RAW}" | tail -n 1)"
if [[ "${JOB_DEF_CODE}" == "200" ]]; then
  if echo "${JOB_DEF_BODY}" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(j.get("job_type")=="backend_ip_pool_refresh" for j in d.get("jobs",[])) else 1)' 2>/dev/null; then
    pass "JobService exposes backend_ip_pool_refresh"
  else
    fail "JobService definitions do not include backend_ip_pool_refresh"
  fi
elif [[ "${JOB_DEF_CODE}" == "000" ]]; then
  skip "JobService not reachable at ${JOB_BASE}"
else
  skip "JobService definition check HTTP ${JOB_DEF_CODE}"
fi

echo "--- [3] Backend Internal Executor Persist Source Records ---"
SOURCE_BODY=$(cat <<JSON
{
  "run_id": "control-acl-smoke-${TIMESTAMP}",
  "environment": "${SMOKE_ENV}",
  "publish": false,
  "dry_run": false,
  "ttl_seconds": 900,
  "reason": "CI smoke source persistence",
  "sources": [
    {"address": "203.0.113.10", "role": "backend", "source": "dns"},
    {"address": "198.51.100.0/24", "role": "admin_proxy", "source": "deploy_static"}
  ]
}
JSON
)
SOURCE_RAW=$(http_json POST "${API_BASE}/internal/job-executors/nodeagent/control-acl-ip-pool-refresh" "${SOURCE_BODY}" -H "X-Internal-Secret: ${INTERNAL_SECRET}")
SOURCE_RESP="$(printf '%s\n' "${SOURCE_RAW}" | sed '$d')"
SOURCE_CODE="$(printf '%s\n' "${SOURCE_RAW}" | tail -n 1)"
if [[ "${SOURCE_CODE}" == "200" ]]; then
  ACCEPTED_COUNT=$(echo "${SOURCE_RESP}" | json_value "accepted" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
  if [[ "${ACCEPTED_COUNT}" -ge 2 ]]; then
    pass "Backend accepted persisted source records (${ACCEPTED_COUNT})"
  else
    fail "Backend accepted count ${ACCEPTED_COUNT}, expected >= 2"
  fi
else
  fail "Backend control ACL refresh HTTP ${SOURCE_CODE}: ${SOURCE_RESP}"
fi

echo "--- [4] Empty Publish Guard ---"
EMPTY_ENV="${SMOKE_ENV}-empty"
EMPTY_BODY=$(cat <<JSON
{"run_id":"control-acl-empty-${TIMESTAMP}","environment":"${EMPTY_ENV}","publish":true,"dry_run":false,"sources":[]}
JSON
)
EMPTY_RAW=$(http_json POST "${API_BASE}/internal/job-executors/nodeagent/control-acl-ip-pool-refresh" "${EMPTY_BODY}" -H "X-Internal-Secret: ${INTERNAL_SECRET}")
EMPTY_RESP="$(printf '%s\n' "${EMPTY_RAW}" | sed '$d')"
EMPTY_CODE="$(printf '%s\n' "${EMPTY_RAW}" | tail -n 1)"
if [[ "${EMPTY_CODE}" =~ ^4 ]]; then
  pass "Empty publish rejected with HTTP ${EMPTY_CODE}"
elif [[ "${EMPTY_CODE}" == "200" ]]; then
  PUBLISHED="$(echo "${EMPTY_RESP}" | json_value "published")"
  if [[ "${PUBLISHED}" == "false" ]]; then
    pass "Empty publish returned 200 but did not publish"
  else
    fail "Empty publish unexpectedly published a config"
  fi
else
  fail "Empty publish guard unexpected HTTP ${EMPTY_CODE}: ${EMPTY_RESP}"
fi

echo "--- [5] Admin Source Breakdown ---"
ADMIN_LOGIN=$(http_json POST "${API_BASE}/admin/api/v1/auth/login" \
  "{\"request_id\":\"control-acl-smoke-${TIMESTAMP}\",\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"client_type\":\"admin\"}")
ADMIN_LOGIN_BODY="$(printf '%s\n' "${ADMIN_LOGIN}" | sed '$d')"
ADMIN_LOGIN_CODE="$(printf '%s\n' "${ADMIN_LOGIN}" | tail -n 1)"
ADMIN_TOKEN="$(echo "${ADMIN_LOGIN_BODY}" | json_value "access_token")"
if [[ "${ADMIN_LOGIN_CODE}" == "200" && -n "${ADMIN_TOKEN}" ]]; then
  LIST_RAW=$(http_json GET "${API_BASE}/admin/api/v1/nodeagent/control-acl-sources?environment=${SMOKE_ENV}" "" -H "Authorization: Bearer ${ADMIN_TOKEN}")
  LIST_RESP="$(printf '%s\n' "${LIST_RAW}" | sed '$d')"
  LIST_CODE="$(printf '%s\n' "${LIST_RAW}" | tail -n 1)"
  if [[ "${LIST_CODE}" == "200" ]]; then
    TOTAL="$(echo "${LIST_RESP}" | json_value "total")"
    ACTIVE="$(echo "${LIST_RESP}" | json_value "projection.active_count")"
    if [[ "${TOTAL:-0}" -ge 2 && "${ACTIVE:-0}" -ge 2 ]]; then
      pass "Admin source list exposes records and projection (total=${TOTAL}, active=${ACTIVE})"
    else
      fail "Admin source projection incomplete: total=${TOTAL:-0}, active=${ACTIVE:-0}"
    fi
  else
    fail "Admin source list HTTP ${LIST_CODE}: ${LIST_RESP}"
  fi
else
  skip "Admin login unavailable (HTTP ${ADMIN_LOGIN_CODE}); source API auth check skipped"
fi

echo "--- [6] Optional Publish Contract ---"
if [[ "${PUBLISH_SMOKE}" == "1" ]]; then
  PUBLISH_BODY=$(cat <<JSON
{
  "run_id": "control-acl-publish-${TIMESTAMP}",
  "environment": "${SMOKE_ENV}",
  "publish": true,
  "dry_run": false,
  "ttl_seconds": 900,
  "reason": "CI smoke publish contract",
  "sources": [
    {"address": "203.0.113.10", "role": "backend", "source": "dns"}
  ]
}
JSON
)
  PUBLISH_RAW=$(http_json POST "${API_BASE}/internal/job-executors/nodeagent/control-acl-ip-pool-refresh" "${PUBLISH_BODY}" -H "X-Internal-Secret: ${INTERNAL_SECRET}")
  PUBLISH_RESP="$(printf '%s\n' "${PUBLISH_RAW}" | sed '$d')"
  PUBLISH_CODE="$(printf '%s\n' "${PUBLISH_RAW}" | tail -n 1)"
  if [[ "${PUBLISH_CODE}" == "200" && "$(echo "${PUBLISH_RESP}" | json_value "published")" == "true" ]]; then
    pass "Backend published control ACL projection"
  else
    fail "Publish contract failed HTTP ${PUBLISH_CODE}: ${PUBLISH_RESP}"
  fi
else
  skip "Set LIVEMASK_CONTROL_ACL_SMOKE_PUBLISH=1 to mutate nodeagent.runtime_config in an isolated smoke runtime"
fi

echo ""
echo "================================================"
echo "Summary: ${PASS_COUNT} passed, ${SKIP_COUNT} skipped, ${FAIL_COUNT} failed"
printf '%s\n' "${SUMMARY_LINES[@]}"
echo "================================================"

if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
