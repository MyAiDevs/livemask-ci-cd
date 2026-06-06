#!/usr/bin/env bash
# TASK-VPN-PKG-C2C-P2-POINTS-BRIDGE-001 — Gate C: package buy → points_return → C2C escrow → settle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="${BACKEND_ROOT:-${SCRIPT_DIR}/../../livemask-backend}"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/../infra/docker-compose.local.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
INTERNAL_SECRET="${INTERNAL_JOB_SECRET:-${INTERNAL_SERVICE_SECRET:-local-dev-secret}}"

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
echo " Commerce Marketplace Bridge Smoke (P2)"
echo "========================================"

echo ""
echo "--- [unit] trafficpackage + commerce tests ---"
cd "$BACKEND_ROOT"
go test ./internal/trafficpackage/... ./internal/commerce/... -count=1 -timeout 3m
pass "unit tests"

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
  -d '{"request_id":"bridge-admin","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
ADMIN_USER_ID=$(echo "${ADMIN_LOGIN}" | quiet_json "user.user_id")
[[ -n "${ADMIN_TOKEN}" ]] && pass "admin login" || fail "admin login"

echo ""
echo "--- [2] Buyer auth ---"
BUYER_EMAIL="bridge-smoke-buyer@test.livemask"
BUYER_PASS="BridgeSmoke123!"
pg_exec -c "DELETE FROM users WHERE email='${BUYER_EMAIL}'" >/dev/null || true
BUYER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"bridge-buyer\",\"email\":\"${BUYER_EMAIL}\",\"password\":\"${BUYER_PASS}\",\"display_name\":\"Bridge Buyer\",\"client_type\":\"app\"}") || true
BUYER_TOKEN=$(echo "${BUYER_REG}" | quiet_json "access_token")
BUYER_ID=$(echo "${BUYER_REG}" | quiet_json "user.user_id")
if [[ -z "${BUYER_TOKEN}" ]]; then
  BUYER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"bridge-login\",\"email\":\"${BUYER_EMAIL}\",\"password\":\"${BUYER_PASS}\",\"client_type\":\"app\"}") || true
  BUYER_TOKEN=$(echo "${BUYER_LOGIN}" | quiet_json "access_token")
  BUYER_ID=$(echo "${BUYER_LOGIN}" | quiet_json "user.user_id")
fi
[[ -n "${BUYER_TOKEN}" && -n "${BUYER_ID}" ]] && pass "buyer auth (${BUYER_ID})" || fail "buyer auth"

echo ""
echo "--- [3] Sync traffic catalog ---"
SYNC_BODY=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/product-config/vpn-packages" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); import json as j; print(j.dumps({'config': d.get('active_version',{}).get('config',{})}))" 2>/dev/null || echo '{"config":{}}')
curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/traffic-packages/sync-from-config" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${SYNC_BODY}" >/dev/null || true
CATALOG=$(curl -sS --max-time 5 "${API_BASE}/api/v1/traffic-packages" -H "Authorization: Bearer ${BUYER_TOKEN}") || true
PLAN_ID=$(echo "${CATALOG}" | python3 -c "import sys,json; d=json.load(sys.stdin); plans=d.get('plans') or []; print(plans[0]['id'] if plans else '')" 2>/dev/null || echo "")
POINTS_PRICE=$(echo "${CATALOG}" | python3 -c "import sys,json; d=json.load(sys.stdin); plans=d.get('plans') or []; print(plans[0].get('points_price',0) if plans else 0)" 2>/dev/null || echo "0")
POINTS_RETURN=$(echo "${CATALOG}" | python3 -c "import sys,json; d=json.load(sys.stdin); plans=d.get('plans') or []; p=plans[0] if plans else {}; print(p.get('points_return') or (int(p.get('points_price',0))*25//100))" 2>/dev/null || echo "0")
[[ -n "${PLAN_ID}" ]] && pass "catalog plan ${PLAN_ID}" || fail "catalog empty"

echo ""
echo "--- [4] Seed points + buy traffic package ---"
SEED_AMOUNT=$((POINTS_PRICE + POINTS_RETURN + 5000))
pg_exec -c "DELETE FROM points_ledger WHERE user_id='${BUYER_ID}'" >/dev/null || true
pg_exec -c "INSERT INTO points_ledger (id, user_id, direction, amount, balance_after, source_type, source_id, status, created_at) VALUES (gen_random_uuid(), '${BUYER_ID}', 'credit', ${SEED_AMOUNT}, ${SEED_AMOUNT}, 'manual_adjustment', 'bridge-smoke-seed', 'posted', now())" >/dev/null
BAL_BEFORE=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/points/balance" -H "Authorization: Bearer ${BUYER_TOKEN}" | quiet_json "available_balance")
IDEM_PKG="bridge-pkg-$(date +%s)"
PKG_ORDER=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/traffic-package-orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"plan_id\":\"${PLAN_ID}\",\"idempotency_key\":\"${IDEM_PKG}\",\"payment_method\":\"points\"}") || true
PKG_ORDER_ID=$(echo "${PKG_ORDER}" | quiet_json "order.id")
RETURN_POSTED=$(echo "${PKG_ORDER}" | quiet_json "points_return_posted")
[[ -n "${PKG_ORDER_ID}" ]] && pass "traffic order ${PKG_ORDER_ID}" || fail "traffic order create"

RETURN_ROW=$(pg_exec -c "SELECT COUNT(*) FROM points_ledger WHERE user_id='${BUYER_ID}' AND source_type='traffic_package_points_return' AND source_id='${PKG_ORDER_ID}'")
[[ "${RETURN_ROW}" == "1" ]] && pass "points_return ledger row" || fail "points_return ledger (count=${RETURN_ROW})"
[[ "${RETURN_POSTED}" == "${POINTS_RETURN}" ]] && pass "points_return_posted=${RETURN_POSTED}" || fail "points_return_posted (got ${RETURN_POSTED}, want ${POINTS_RETURN})"

BAL_AFTER_PKG=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/points/balance" -H "Authorization: Bearer ${BUYER_TOKEN}" | quiet_json "available_balance")
EXPECTED_AFTER=$((SEED_AMOUNT - POINTS_PRICE + POINTS_RETURN))
[[ "${BAL_AFTER_PKG}" == "${EXPECTED_AFTER}" ]] && pass "available after package=${BAL_AFTER_PKG}" || fail "available after package (got ${BAL_AFTER_PKG}, want ${EXPECTED_AFTER})"

echo ""
echo "--- [5] C2C listing + escrow ---"
LISTING_BODY='{"title":"Bridge Smoke Listing","description":"p2 bridge","category":"test","points_price":1000,"inventory_total":5}'
LISTING_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/points-market/items" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${LISTING_BODY}") || true
LISTING_ID=$(echo "${LISTING_RESP}" | quiet_json "id")
curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/points-market/items/${LISTING_ID}/approve" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" >/dev/null || true
[[ -n "${LISTING_ID}" ]] && pass "listing ${LISTING_ID}" || fail "listing create"

IDEM_C2C="bridge-c2c-$(date +%s)"
C2C_ORDER=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/points-market/orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"item_id\":\"${LISTING_ID}\",\"idempotency_key\":\"${IDEM_C2C}\"}") || true
C2C_ORDER_ID=$(echo "${C2C_ORDER}" | quiet_json "order.id")
C2C_STATUS=$(echo "${C2C_ORDER}" | quiet_json "order.status")
[[ -n "${C2C_ORDER_ID}" && "${C2C_STATUS}" == "escrowed" ]] && pass "c2c escrowed ${C2C_ORDER_ID}" || fail "c2c order (status=${C2C_STATUS})"

AVAIL_AFTER_ESCROW=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/points/balance" -H "Authorization: Bearer ${BUYER_TOKEN}" | quiet_json "available_balance")
FROZEN_AFTER_ESCROW=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/points/balance" -H "Authorization: Bearer ${BUYER_TOKEN}" | quiet_json "frozen_balance")
EXPECTED_AVAIL=$((EXPECTED_AFTER - 1000))
[[ "${AVAIL_AFTER_ESCROW}" == "${EXPECTED_AVAIL}" ]] && pass "available after escrow=${AVAIL_AFTER_ESCROW}" || fail "available after escrow (got ${AVAIL_AFTER_ESCROW})"
[[ "${FROZEN_AFTER_ESCROW}" == "1000" ]] && pass "frozen after escrow=1000" || fail "frozen after escrow (got ${FROZEN_AFTER_ESCROW})"

echo ""
echo "--- [6] Confirm + settle ---"
curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/points-market/orders/${C2C_ORDER_ID}/confirm-fulfilled" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" >/dev/null || true
SETTLE=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/points-market/settlement-reconcile" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d "{\"order_ids\":[\"${C2C_ORDER_ID}\"]}") || true
SETTLE_OK=$(echo "${SETTLE}" | quiet_json "ok")
[[ "${SETTLE_OK}" == "True" || "${SETTLE_OK}" == "true" ]] && pass "settlement reconcile" || fail "settlement reconcile"

FINAL_STATUS=$(pg_exec -c "SELECT status FROM points_market_orders WHERE id='${C2C_ORDER_ID}'")
[[ "${FINAL_STATUS}" == "settled" ]] && pass "c2c order settled" || fail "c2c final status (${FINAL_STATUS})"

echo ""
echo "--- [7] Idempotent package replay (no double return) ---"
PKG_ORDER2=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/traffic-package-orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"plan_id\":\"${PLAN_ID}\",\"idempotency_key\":\"${IDEM_PKG}\",\"payment_method\":\"points\"}") || true
RETURN_ROWS=$(pg_exec -c "SELECT COUNT(*) FROM points_ledger WHERE user_id='${BUYER_ID}' AND source_type='traffic_package_points_return' AND source_id='${PKG_ORDER_ID}'")
[[ "${RETURN_ROWS}" == "1" ]] && pass "idempotent points_return (count=1)" || fail "double points_return (count=${RETURN_ROWS})"

echo ""
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
if [[ "${FAILED}" -ne 0 ]]; then
  echo "Commerce Marketplace Bridge Smoke: FAIL"
  exit 1
fi
echo "Commerce Marketplace Bridge Smoke: PASS"
exit 0
