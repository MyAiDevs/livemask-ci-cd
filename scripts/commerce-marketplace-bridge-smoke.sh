#!/usr/bin/env bash
# TASK-VPN-PKG-C2C-P2-POINTS-BRIDGE-001 — Gate C: package buy → points_return → C2C escrow → settle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="${BACKEND_ROOT:-${SCRIPT_DIR}/../../livemask-backend}"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/../infra/docker-compose.local.yml}"
if [[ "${COMPOSE_FILE}" != /* ]]; then
  COMPOSE_FILE="${SCRIPT_DIR}/../${COMPOSE_FILE}"
fi
COMPOSE_FILE="$(cd "$(dirname "${COMPOSE_FILE}")" && pwd)/$(basename "${COMPOSE_FILE}")"
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
( cd "$BACKEND_ROOT" && go test ./internal/trafficpackage/... ./internal/commerce/... ./internal/bankcard/... ./internal/support/... -count=1 -timeout 3m )
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
echo "--- [8] Growth ambassador: referral → package_paid → aggregate → ledger ---"
L1_EMAIL="bridge-smoke-l1@test.livemask"
L1_PASS="BridgeSmokeL1!"
REF_EMAIL="bridge-smoke-ref@test.livemask"
REF_PASS="BridgeSmokeRef!"
pg_exec -c "DELETE FROM users WHERE email IN ('${L1_EMAIL}','${REF_EMAIL}')" >/dev/null || true
L1_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"bridge-l1\",\"email\":\"${L1_EMAIL}\",\"password\":\"${L1_PASS}\",\"display_name\":\"Bridge L1\",\"client_type\":\"app\"}") || true
L1_TOKEN=$(echo "${L1_REG}" | quiet_json "access_token")
L1_ID=$(echo "${L1_REG}" | quiet_json "user.user_id")
REF_CODE=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/referral-link" \
  -H "Authorization: Bearer ${L1_TOKEN}" | quiet_json "code")
REF_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"bridge-ref\",\"email\":\"${REF_EMAIL}\",\"password\":\"${REF_PASS}\",\"display_name\":\"Bridge Ref\",\"client_type\":\"app\",\"referral_code\":\"${REF_CODE}\"}") || true
REF_TOKEN=$(echo "${REF_REG}" | quiet_json "access_token")
REF_ID=$(echo "${REF_REG}" | quiet_json "user.user_id")
[[ -n "${L1_ID}" && -n "${REF_CODE}" && -n "${REF_ID}" ]] && pass "referral chain L1=${L1_ID} ref=${REF_ID}" || fail "referral chain setup"

REF_SEED=$((POINTS_PRICE + POINTS_RETURN + 5000))
pg_exec -c "DELETE FROM points_ledger WHERE user_id='${REF_ID}'" >/dev/null || true
pg_exec -c "INSERT INTO points_ledger (id, user_id, direction, amount, balance_after, source_type, source_id, status, created_at) VALUES (gen_random_uuid(), '${REF_ID}', 'credit', ${REF_SEED}, ${REF_SEED}, 'manual_adjustment', 'bridge-growth-seed', 'posted', now())" >/dev/null
IDEM_GROWTH="bridge-growth-$(date +%s)"
GROWTH_PKG=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/traffic-package-orders" \
  -H "Authorization: Bearer ${REF_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"plan_id\":\"${PLAN_ID}\",\"idempotency_key\":\"${IDEM_GROWTH}\",\"payment_method\":\"points\"}") || true
GROWTH_ORDER_ID=$(echo "${GROWTH_PKG}" | quiet_json "order.id")
SNAP_COUNT=$(pg_exec -c "SELECT COUNT(*) FROM growth_attribution_snapshots WHERE source_event_id='package_paid:${GROWTH_ORDER_ID}'")
[[ -n "${GROWTH_ORDER_ID}" && "${SNAP_COUNT}" == "1" ]] && pass "package_paid attribution snapshot" || fail "package_paid snapshot (order=${GROWTH_ORDER_ID}, count=${SNAP_COUNT})"

AGG=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/growth/ambassador-reward-aggregate" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{"limit":20}') || true
AGG_OK=$(echo "${AGG}" | quiet_json "ok")
AGG_COUNT=$(echo "${AGG}" | quiet_json "processed_count")
[[ "${AGG_OK}" == "True" || "${AGG_OK}" == "true" ]] && pass "ambassador reward aggregate (processed=${AGG_COUNT})" || fail "ambassador reward aggregate"

L1_LEDGER=$(pg_exec -c "SELECT points_delta FROM growth_points_ledger WHERE user_id='${L1_ID}' AND source_event_id='package_paid:${GROWTH_ORDER_ID}' AND attribution_level='l1' LIMIT 1")
[[ "${L1_LEDGER}" == "100" ]] && pass "L1 growth_points_ledger=100" || fail "L1 ledger (got ${L1_LEDGER}, want 100)"

echo ""
echo "--- [9] Growth L2 ambassador reward ---"
L2_EMAIL="bridge-smoke-l2@test.livemask"
L2_PASS="BridgeSmokeL2!"
pg_exec -c "DELETE FROM users WHERE email='${L2_EMAIL}'" >/dev/null || true
L2_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"bridge-l2\",\"email\":\"${L2_EMAIL}\",\"password\":\"${L2_PASS}\",\"display_name\":\"Bridge L2\",\"client_type\":\"app\"}") || true
L2_TOKEN=$(echo "${L2_REG}" | quiet_json "access_token")
L2_ID=$(echo "${L2_REG}" | quiet_json "user.user_id")
L2_CODE=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/referral-link" \
  -H "Authorization: Bearer ${L2_TOKEN}" | quiet_json "code")
L1B_EMAIL="bridge-smoke-l1b@test.livemask"
pg_exec -c "DELETE FROM users WHERE email='${L1B_EMAIL}'" >/dev/null || true
L1B_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"bridge-l1b\",\"email\":\"${L1B_EMAIL}\",\"password\":\"${L1_PASS}\",\"display_name\":\"Bridge L1B\",\"client_type\":\"app\",\"referral_code\":\"${L2_CODE}\"}") || true
L1B_TOKEN=$(echo "${L1B_REG}" | quiet_json "access_token")
L1B_ID=$(echo "${L1B_REG}" | quiet_json "user.user_id")
L1B_CODE=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/referral-link" \
  -H "Authorization: Bearer ${L1B_TOKEN}" | quiet_json "code")
REF2_EMAIL="bridge-smoke-ref2@test.livemask"
pg_exec -c "DELETE FROM users WHERE email='${REF2_EMAIL}'" >/dev/null || true
REF2_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"bridge-ref2\",\"email\":\"${REF2_EMAIL}\",\"password\":\"${REF_PASS}\",\"display_name\":\"Bridge Ref2\",\"client_type\":\"app\",\"referral_code\":\"${L1B_CODE}\"}") || true
REF2_TOKEN=$(echo "${REF2_REG}" | quiet_json "access_token")
REF2_ID=$(echo "${REF2_REG}" | quiet_json "user.user_id")
[[ -n "${L2_ID}" && -n "${L1B_ID}" && -n "${REF2_ID}" ]] && pass "L2→L1→buyer chain" || fail "L2 chain setup"
pg_exec -c "DELETE FROM points_ledger WHERE user_id='${REF2_ID}' AND source_id='bridge-l2-seed'" >/dev/null || true
pg_exec -c "INSERT INTO points_ledger (id, user_id, direction, amount, balance_after, source_type, source_id, status, created_at) VALUES (gen_random_uuid(), '${REF2_ID}', 'credit', ${REF_SEED}, ${REF_SEED}, 'manual_adjustment', 'bridge-l2-seed', 'posted', now())" >/dev/null
IDEM_L2="bridge-l2-$(date +%s)"
L2_PKG=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/traffic-package-orders" \
  -H "Authorization: Bearer ${REF2_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"plan_id\":\"${PLAN_ID}\",\"idempotency_key\":\"${IDEM_L2}\",\"payment_method\":\"points\"}") || true
L2_ORDER_ID=$(echo "${L2_PKG}" | quiet_json "order.id")
curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/growth/ambassador-reward-aggregate" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{"limit":20}' >/dev/null || true
L2_LEDGER=$(pg_exec -c "SELECT points_delta FROM growth_points_ledger WHERE user_id='${L2_ID}' AND source_event_id='package_paid:${L2_ORDER_ID}' AND attribution_level='l2' LIMIT 1")
[[ "${L2_LEDGER}" == "50" ]] && pass "L2 growth_points_ledger=50" || fail "L2 ledger (got ${L2_LEDGER}, want 50)"

echo ""
echo "--- [10] Commerce package grant expire ---"
EXPIRE_KEY="bridge-expire-$(date +%s)"
CREATE_EXP=$(curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/packages" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"package_key\":\"${EXPIRE_KEY}\",\"display_name\":\"Bridge Expire Pack\",\"duration_days\":1,\"points_price\":800,\"points_grant\":200}") || true
EXP_PKG_ID=$(echo "${CREATE_EXP}" | quiet_json "id")
curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/packages/${EXP_PKG_ID}/publish" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" >/dev/null || true
pg_exec -c "DELETE FROM points_ledger WHERE user_id='${BUYER_ID}' AND source_id='bridge-expire-seed'" >/dev/null || true
pg_exec -c "INSERT INTO points_ledger (id, user_id, direction, amount, balance_after, source_type, source_id, status, created_at) VALUES (gen_random_uuid(), '${BUYER_ID}', 'credit', 5000, 5000, 'manual_adjustment', 'bridge-expire-seed', 'posted', now())" >/dev/null
EXP_ORDER=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/package-orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"package_id\":\"${EXP_PKG_ID}\",\"idempotency_key\":\"expire-$(date +%s)\",\"payment_method\":\"points\"}") || true
EXP_ORDER_ID=$(echo "${EXP_ORDER}" | quiet_json "order.id")
EXP_ORDER_STATUS=$(echo "${EXP_ORDER}" | quiet_json "order.status")
[[ -n "${EXP_ORDER_ID}" && "${EXP_ORDER_STATUS}" == "fulfilled" ]] && pass "commerce package order fulfilled ${EXP_ORDER_ID}" || fail "commerce package order (status=${EXP_ORDER_STATUS})"
pg_exec -c "UPDATE commerce_package_grants SET ends_at = NOW() - INTERVAL '2 days' WHERE order_id='${EXP_ORDER_ID}'" >/dev/null || true
EXPIRE_JOB=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/commerce/package-expire" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{}') || true
EXPIRE_OK=$(echo "${EXPIRE_JOB}" | quiet_json "ok")
GRANT_STATUS=$(pg_exec -c "SELECT status FROM commerce_package_grants WHERE order_id='${EXP_ORDER_ID}'")
[[ "${EXPIRE_OK}" == "True" || "${EXPIRE_OK}" == "true" ]] && pass "package-expire executor ok" || fail "package-expire (${EXPIRE_JOB})"
[[ "${GRANT_STATUS}" == "expired" ]] && pass "commerce grant expired" || fail "grant status (${GRANT_STATUS})"

echo ""
echo "--- [11] Ambassador settlement generate (dry-run) ---"
PERIOD_END=$(date -u +%Y-%m-%d)
PERIOD_START=$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)
SETTLE_GEN=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/growth/ambassador-settlement-generate" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d "{\"period_start\":\"${PERIOD_START}\",\"period_end\":\"${PERIOD_END}\",\"dry_run\":true}") || true
SETTLE_ROLE=$(echo "${SETTLE_GEN}" | quiet_json "role_type")
[[ "${SETTLE_ROLE}" == "promotion_ambassador" ]] && pass "ambassador settlement dry-run" || fail "ambassador settlement (${SETTLE_GEN})"

echo ""
echo "--- [12] Support ticket SLA scan ---"
pg_exec -c "DELETE FROM support_tickets WHERE title='bridge-sla-smoke'" >/dev/null || true
pg_exec -c "INSERT INTO support_tickets (submitter_user_id, category, priority, status, title, last_activity_at) SELECT id, 'points', 'normal', 'open', 'bridge-sla-smoke', NOW() - INTERVAL '4 days' FROM users WHERE email='${BUYER_EMAIL}' LIMIT 1" >/dev/null
SLA_JOB=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/support/ticket-sla-scan" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{"stale_hours":1,"limit":10}') || true
SLA_OK=$(echo "${SLA_JOB}" | quiet_json "ok")
SLA_PRIO=$(pg_exec -c "SELECT priority FROM support_tickets WHERE title='bridge-sla-smoke' LIMIT 1")
[[ "${SLA_OK}" == "True" || "${SLA_OK}" == "true" ]] && pass "ticket-sla-scan ok" || fail "ticket-sla-scan (${SLA_JOB})"
[[ "${SLA_PRIO}" == "high" ]] && pass "ticket priority escalated to high" || fail "ticket priority (${SLA_PRIO})"

echo ""
echo "--- [13] Bank card draft → confirm → admin approve ---"
CREATE_CARD=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/me/bank-cards" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"holder_name":"Bridge Buyer","bank_name":"Test Bank","card_number":"6222021234567890"}') || true
CARD_ID=$(echo "${CREATE_CARD}" | quiet_json "id")
CARD_STATUS=$(echo "${CREATE_CARD}" | quiet_json "status")
CARD_MASKED=$(echo "${CREATE_CARD}" | quiet_json "card_number_masked")
[[ -n "${CARD_ID}" && "${CARD_STATUS}" == "draft" ]] && pass "bank card draft ${CARD_ID}" || fail "bank card create (${CREATE_CARD})"
[[ "${CARD_MASKED}" == *"****"* ]] && pass "bank card masked (${CARD_MASKED})" || fail "bank card mask leak (${CARD_MASKED})"
CONFIRM_CARD=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/me/bank-cards/${CARD_ID}/confirm" \
  -H "Authorization: Bearer ${BUYER_TOKEN}") || true
CONFIRM_STATUS=$(echo "${CONFIRM_CARD}" | quiet_json "status")
[[ "${CONFIRM_STATUS}" == "pending_review" ]] && pass "bank card pending_review" || fail "bank card confirm (${CONFIRM_CARD})"
APPROVE_CARD=$(curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/users/${BUYER_ID}/bank-cards/${CARD_ID}/approve" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
APPROVE_STATUS=$(echo "${APPROVE_CARD}" | quiet_json "status")
[[ "${APPROVE_STATUS}" == "verified" ]] && pass "bank card verified" || fail "bank card approve (${APPROVE_CARD})"

echo ""
echo "--- [14] Support ticket create + admin transition ---"
CREATE_TICKET=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/support/tickets" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"category":"points","priority":"normal","title":"bridge-support-smoke"}') || true
TICKET_ID=$(echo "${CREATE_TICKET}" | quiet_json "id")
[[ -n "${TICKET_ID}" ]] && pass "support ticket created ${TICKET_ID}" || fail "support ticket create (${CREATE_TICKET})"
ADMIN_TICKETS=$(curl -sS --max-time 10 -X GET "${API_BASE}/admin/api/v1/support/tickets" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
ADMIN_HAS=$(echo "${ADMIN_TICKETS}" | python3 -c "import sys,json; d=json.load(sys.stdin); ids=[t.get('id') for t in (d.get('tickets') or [])]; print('1' if '${TICKET_ID}' in ids else '0')" 2>/dev/null || echo "0")
[[ "${ADMIN_HAS}" == "1" ]] && pass "admin lists support ticket" || fail "admin support list (${ADMIN_TICKETS})"
TRANS_TICKET=$(curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/support/tickets/${TICKET_ID}/transition" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"status":"triage"}') || true
TRANS_STATUS=$(echo "${TRANS_TICKET}" | quiet_json "status")
[[ "${TRANS_STATUS}" == "triage" ]] && pass "support ticket transitioned to triage" || fail "support transition (${TRANS_TICKET})"

echo ""
echo "--- [15] Admin user bank-card list (masked) ---"
ADMIN_CARDS=$(curl -sS --max-time 10 -X GET "${API_BASE}/admin/api/v1/users/${BUYER_ID}/bank-cards" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
ADMIN_CARD_STATUS=$(echo "${ADMIN_CARDS}" | python3 -c "import sys,json; d=json.load(sys.stdin); cards=d.get('cards') or []; print(next((c.get('status','') for c in cards if c.get('id')=='${CARD_ID}'), ''))" 2>/dev/null || echo "")
ADMIN_MASKED=$(echo "${ADMIN_CARDS}" | python3 -c "import sys,json; d=json.load(sys.stdin); cards=d.get('cards') or []; print(next((c.get('card_number_masked','') for c in cards if c.get('id')=='${CARD_ID}'), ''))" 2>/dev/null || echo "")
[[ "${ADMIN_CARD_STATUS}" == "verified" ]] && pass "admin user bank-card list verified" || fail "admin bank-card list (${ADMIN_CARDS})"
[[ "${ADMIN_MASKED}" == *"****"* && "${ADMIN_MASKED}" != *"6222021234567890"* ]] && pass "admin list masked only" || fail "admin list mask leak (${ADMIN_MASKED})"

echo ""
echo "--- [16] Admin points ledger search ---"
LEDGER_ALL=$(curl -sS --max-time 10 -X GET "${API_BASE}/admin/api/v1/points/ledger?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
LEDGER_TOTAL=$(echo "${LEDGER_ALL}" | quiet_json "total")
[[ "${LEDGER_TOTAL}" -ge 1 ]] 2>/dev/null && pass "admin points ledger total>=1 (${LEDGER_TOTAL})" || fail "admin points ledger (${LEDGER_ALL})"
LEDGER_USER=$(curl -sS --max-time 10 -X GET "${API_BASE}/admin/api/v1/points/ledger?limit=10&user_id=${BUYER_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
USER_ITEMS=$(echo "${LEDGER_USER}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items') or []))" 2>/dev/null || echo "0")
[[ "${USER_ITEMS}" -ge 1 ]] 2>/dev/null && pass "admin ledger user filter (${USER_ITEMS} rows)" || fail "admin ledger user filter (${LEDGER_USER})"
USER_FORBIDDEN=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X GET "${API_BASE}/admin/api/v1/points/ledger" \
  -H "Authorization: Bearer ${BUYER_TOKEN}") || true
[[ "${USER_FORBIDDEN}" == "403" || "${USER_FORBIDDEN}" == "401" ]] && pass "user token blocked on admin ledger (${USER_FORBIDDEN})" || fail "admin ledger RBAC (${USER_FORBIDDEN})"

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
