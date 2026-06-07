#!/usr/bin/env bash
# Idempotently seed production-like job cron schedules via Admin jobs API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

API_BASE="$(lm_backend_base_url)"
PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
skip() { SKIP=$((SKIP + 1)); echo "  [SKIP] $*"; }

echo "=== Seed job cron schedules ==="

LOGIN=$(curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"seed-job-cron","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}' 2>/dev/null || echo "{}")
TOKEN=$(echo "${LOGIN}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
if [[ -z "${TOKEN}" ]]; then
  fail "Admin login failed — cannot seed schedules"
  exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

LIST_HTTP=$(curl -sS --max-time 10 -o /tmp/job-schedules-list.json -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/jobs/schedules" -H "${AUTH}" 2>/dev/null || echo "000")
if [[ "${LIST_HTTP}" == "404" || "${LIST_HTTP}" == "501" ]]; then
  skip "Jobs schedules API not deployed (HTTP ${LIST_HTTP})"
  echo "Seed schedules: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
  exit 0
fi
if [[ "${LIST_HTTP}" != "200" ]]; then
  fail "List schedules HTTP ${LIST_HTTP}"
  exit 1
fi

declare -a SEEDS=(
  'billing_ledger_project|Billing ledger projection|0 2 * * *'
  'traffic_package_entitlement_expire|Traffic entitlement expire|15 3 * * *'
  'traffic_package_order_reconcile|Traffic order reconcile|45 3 * * *'
  'points_market_settlement_reconcile|Points market reconcile|0 4 * * *'
  'growth_settlement_reconcile|Growth settlement reconcile|30 4 * * *'
)

for seed in "${SEEDS[@]}"; do
  IFS='|' read -r JOB_TYPE NAME CRON <<<"${seed}"
  EXISTS=$(python3 - <<PY
import json
data=json.load(open("/tmp/job-schedules-list.json"))
items=data.get("schedules",data.get("items",[]))
print("yes" if any(s.get("job_type")== "${JOB_TYPE}" for s in items if isinstance(s,dict)) else "no")
PY
)
  if [[ "${EXISTS}" == "yes" ]]; then
    pass "Schedule exists: ${JOB_TYPE}"
    continue
  fi
  BODY=$(cat <<EOF
{"job_type":"${JOB_TYPE}","name":"${NAME}","schedule_type":"cron","timezone":"UTC","cron":"${CRON}"}
EOF
)
  CREATE_HTTP=$(curl -sS --max-time 10 -o /tmp/job-schedule-create.json -w "%{http_code}" \
    -X POST "${API_BASE}/admin/api/v1/jobs/schedules" \
    -H "${AUTH}" -H "Content-Type: application/json" -d "${BODY}" 2>/dev/null || echo "000")
  if [[ "${CREATE_HTTP}" == "201" || "${CREATE_HTTP}" == "200" ]]; then
    pass "Created schedule: ${JOB_TYPE}"
  else
    fail "Create ${JOB_TYPE}: HTTP ${CREATE_HTTP}"
  fi
done

echo "Seed schedules: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
[[ "${FAIL}" -eq 0 ]]
