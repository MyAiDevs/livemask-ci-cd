#!/usr/bin/env bash
# TASK-CICD-TRAFFIC-PACKAGE-PLAN-SMOKE-001 — traffic package catalog → points purchase → entitlement
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="${BACKEND_ROOT:-${SCRIPT_DIR}/../../livemask-backend}"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/../infra/docker-compose.local.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"

FAILED=0
SUMMARY_LINES=()
fail() { echo "  FAIL: $1"; SUMMARY_LINES+=("FAIL: $1"); FAILED=1; }
pass() { echo "  PASS: $1"; SUMMARY_LINES+=("PASS: $1"); }

quiet_json() {
  python3 -c "
import sys,json
data=json.load(sys.stdin)
parts='${1:-}'.split('.')
cur=data
for p in parts:
    if isinstance(cur, dict):
        cur=cur.get(p, '')
    elif isinstance(cur, list):
        try: cur=cur[int(p)]
        except: cur=''
    else:
        cur=''
print(cur if cur is not None else '')
" 2>/dev/null || echo ""
}

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}

echo "========================================"
echo " Traffic Package Plan Smoke"
echo "========================================"

echo ""
echo "--- [unit] trafficpackage tests ---"
cd "$BACKEND_ROOT"
go test ./internal/trafficpackage/... -count=1 -timeout 3m
pass "trafficpackage unit tests"

echo ""
echo "--- [0] Health ---"
for attempt in $(seq 1 30); do
  if curl -sS --max-time 3 "${API_BASE}/api/v1/health" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    break
  fi
  [[ "${attempt}" -eq 30 ]] && fail "backend not ready" && printf '%s\n' "${SUMMARY_LINES[@]}" && exit 1
  sleep 2
done
pass "backend health"

echo ""
echo "--- [1] Admin login ---"
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"tp-smoke-admin","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
[[ -n "${ADMIN_TOKEN}" ]] && pass "admin login" || fail "admin login"

echo ""
echo "--- [2] Buyer register ---"
BUYER_EMAIL="traffic-smoke-buyer@test.livemask"
BUYER_PASS="TrafficSmoke123!"
pg_exec -c "DELETE FROM users WHERE email='${BUYER_EMAIL}'" >/dev/null || true
BUYER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"tp-smoke-buyer\",\"email\":\"${BUYER_EMAIL}\",\"password\":\"${BUYER_PASS}\",\"display_name\":\"Traffic Buyer\",\"client_type\":\"app\"}") || true
BUYER_TOKEN=$(echo "${BUYER_REG}" | quiet_json "access_token")
BUYER_ID=$(echo "${BUYER_REG}" | quiet_json "user.user_id")
if [[ -z "${BUYER_TOKEN}" ]]; then
  BUYER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"tp-smoke-login\",\"email\":\"${BUYER_EMAIL}\",\"password\":\"${BUYER_PASS}\",\"client_type\":\"app\"}") || true
  BUYER_TOKEN=$(echo "${BUYER_LOGIN}" | quiet_json "access_token")
  BUYER_ID=$(echo "${BUYER_LOGIN}" | quiet_json "user.user_id")
fi
[[ -n "${BUYER_TOKEN}" && -n "${BUYER_ID}" ]] && pass "buyer auth (${BUYER_ID})" || fail "buyer auth"

echo ""
echo "--- [3] Catalog has active plans ---"
CATALOG=$(curl -sS --max-time 5 "${API_BASE}/api/v1/traffic-packages" -H "Authorization: Bearer ${BUYER_TOKEN}") || true
PLAN_COUNT=$(echo "${CATALOG}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('plans') or []))" 2>/dev/null || echo "0")
if [[ "${PLAN_COUNT}" -gt 0 ]]; then
  pass "catalog plans (${PLAN_COUNT})"
else
  SYNC_BODY=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/product-config/vpn-packages" -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); import json as j; print(j.dumps({'config': d.get('active_version',{}).get('config',{})}))" 2>/dev/null || echo '{"config":{}}')
  curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/traffic-packages/sync-from-config" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${SYNC_BODY}" >/dev/null || true
  CATALOG=$(curl -sS --max-time 5 "${API_BASE}/api/v1/traffic-packages" -H "Authorization: Bearer ${BUYER_TOKEN}") || true
  PLAN_COUNT=$(echo "${CATALOG}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('plans') or []))" 2>/dev/null || echo "0")
  [[ "${PLAN_COUNT}" -gt 0 ]] && pass "catalog synced (${PLAN_COUNT})" || fail "catalog empty"
fi

PLAN_ID=$(echo "${CATALOG}" | python3 -c "import sys,json; d=json.load(sys.stdin); plans=d.get('plans') or []; print(plans[0]['id'] if plans else '')" 2>/dev/null || echo "")
POINTS_PRICE=$(echo "${CATALOG}" | python3 -c "import sys,json; d=json.load(sys.stdin); plans=d.get('plans') or []; print(plans[0].get('points_price',0) if plans else 0)" 2>/dev/null || echo "0")

echo ""
echo "--- [4] Seed buyer points ---"
SEED_AMOUNT=$((POINTS_PRICE + 5000))
pg_exec -c "DELETE FROM points_ledger WHERE user_id='${BUYER_ID}' AND source_id='traffic-smoke-seed'" >/dev/null || true
pg_exec -c "INSERT INTO points_ledger (id, user_id, direction, amount, balance_after, source_type, source_id, status, created_at) VALUES (gen_random_uuid(), '${BUYER_ID}', 'credit', ${SEED_AMOUNT}, ${SEED_AMOUNT}, 'manual_adjustment', 'traffic-smoke-seed', 'posted', now())" >/dev/null
pass "buyer points seeded (${SEED_AMOUNT})"

echo ""
echo "--- [5] Points purchase + entitlement ---"
IDEM_KEY="traffic-smoke-$(date +%s)"
ORDER_RESP=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/traffic-package-orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"plan_id\":\"${PLAN_ID}\",\"idempotency_key\":\"${IDEM_KEY}\",\"payment_method\":\"points\"}") || true
ORDER_ID=$(echo "${ORDER_RESP}" | quiet_json "order.id")
ORDER_STATUS=$(echo "${ORDER_RESP}" | quiet_json "order.status")
ENT_STATUS=$(echo "${ORDER_RESP}" | quiet_json "entitlement.status")
[[ -n "${ORDER_ID}" && "${ORDER_STATUS}" == "fulfilled" ]] && pass "order fulfilled ${ORDER_ID}" || fail "order create (status=${ORDER_STATUS})"
[[ "${ENT_STATUS}" == "active" ]] && pass "entitlement active" || fail "entitlement (status=${ENT_STATUS})"

DEBIT_COUNT=$(pg_exec -c "SELECT COUNT(*) FROM points_ledger WHERE user_id='${BUYER_ID}' AND source_type='traffic_package_points_debit' AND source_id='${ORDER_ID}'")
[[ "${DEBIT_COUNT}" == "1" ]] && pass "points debit ledger" || fail "debit ledger (count=${DEBIT_COUNT})"

ENT_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/traffic-entitlement" -H "Authorization: Bearer ${BUYER_TOKEN}") || true
ME_STATUS=$(echo "${ENT_RESP}" | quiet_json "entitlement.status")
[[ "${ME_STATUS}" == "active" ]] && pass "GET /me/traffic-entitlement active" || fail "me entitlement (${ME_STATUS})"

echo ""
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
if [[ "${FAILED}" -ne 0 ]]; then
  echo "Traffic Package Plan Smoke: FAIL"
  exit 1
fi
echo "Traffic Package Plan Smoke: PASS"
exit 0
