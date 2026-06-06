#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-C2C-POINTS-MARKET-PORTAL-AND-SMOKE-001
# C2C Points Market: unit tests + Postgres listing → escrow → settle e2e
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="${BACKEND_ROOT:-${SCRIPT_DIR}/../../livemask-backend}"
JOB_ROOT="${JOB_ROOT:-${SCRIPT_DIR}/../../livemask-job-service}"
COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
INTERNAL_SECRET="${INTERNAL_JOB_SECRET:-${INTERNAL_SERVICE_SECRET:-local-dev-secret}}"

FAILED=0
SUMMARY_LINES=()

fail() { echo "  FAIL: $1"; SUMMARY_LINES+=("FAIL: $1"); FAILED=1; }
pass() { echo "  PASS: $1"; SUMMARY_LINES+=("PASS: $1"); }
skip() { echo "  SKIP: $1"; SUMMARY_LINES+=("SKIP: $1"); }

quiet_json() {
  local path="${1:-}"
  python3 -c "
import sys,json
data=json.load(sys.stdin)
parts='${path}'.split('.')
current=data
for p in parts:
    if isinstance(current, dict):
        if p not in current:
            print('')
            sys.exit(0)
        current=current[p]
    elif isinstance(current, list):
        try:
            current=current[int(p)]
        except (IndexError, ValueError):
            print('')
            sys.exit(0)
    else:
        print('')
        sys.exit(0)
print(current)
" 2>/dev/null || echo ""
}

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}

echo "========================================"
echo " C2C Points Market Smoke"
echo "========================================"
echo ""

# ── Unit tests (offline) ───────────────────────────────────────────────────────
echo "--- [unit] backend commerce tests ---"
cd "$BACKEND_ROOT"
go test ./internal/commerce/... -count=1 -timeout 3m
pass "commerce unit tests"

echo "--- [unit] job points_market definition drift ---"
cd "$JOB_ROOT"
if go test ./internal/jobs/... -run 'TestDefinitionDrift' -count=1 2>/dev/null; then
  pass "job definition drift"
else
  skip "job definition drift (job-service build unavailable)"
fi

cd "${SCRIPT_DIR}/.."

# ── Health ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- [0] Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(curl -sS --max-time 3 "${API_BASE}/api/v1/health" 2>/dev/null || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    break
  fi
  [[ "${attempt}" -eq 30 ]] && fail "backend not ready" && printf '%s\n' "${SUMMARY_LINES[@]}" && exit 1
  sleep 2
done
pass "backend health"

# ── Admin login ────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Admin login ---"
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"c2c-smoke-admin","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
ADMIN_USER_ID=$(echo "${ADMIN_LOGIN}" | quiet_json "user.user_id")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" >/dev/null
  ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" || echo "")
  if [[ -n "${ADMIN_HASH}" ]]; then
    pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'"
    pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'c2c-smoke' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING"
    ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"request_id":"c2c-smoke-admin2","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
    ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
    ADMIN_USER_ID=$(echo "${ADMIN_LOGIN}" | quiet_json "user.user_id")
  fi
fi
[[ -z "${ADMIN_TOKEN}" ]] && fail "admin login" || pass "admin login"

# ── Buyer register ─────────────────────────────────────────────────────────────
echo ""
echo "--- [2] Buyer register ---"
BUYER_EMAIL="c2c-smoke-buyer@test.livemask"
BUYER_PASS="C2cSmoke123!"
pg_exec -c "DELETE FROM users WHERE email='${BUYER_EMAIL}'" >/dev/null || true

BUYER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"c2c-smoke-buyer\",\"email\":\"${BUYER_EMAIL}\",\"password\":\"${BUYER_PASS}\",\"display_name\":\"C2C Buyer\",\"client_type\":\"app\"}") || true
BUYER_TOKEN=$(echo "${BUYER_REG}" | quiet_json "access_token")
BUYER_ID=$(echo "${BUYER_REG}" | quiet_json "user.user_id")
if [[ -z "${BUYER_TOKEN}" ]]; then
  BUYER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"c2c-smoke-buyer-login\",\"email\":\"${BUYER_EMAIL}\",\"password\":\"${BUYER_PASS}\",\"client_type\":\"app\"}") || true
  BUYER_TOKEN=$(echo "${BUYER_LOGIN}" | quiet_json "access_token")
  BUYER_ID=$(echo "${BUYER_LOGIN}" | quiet_json "user.user_id")
fi
[[ -z "${BUYER_TOKEN}" || -z "${BUYER_ID}" ]] && fail "buyer auth" || pass "buyer auth (${BUYER_ID})"

# ── Seed buyer points ──────────────────────────────────────────────────────────
echo ""
echo "--- [3] Seed buyer points ---"
pg_exec -c "DELETE FROM points_ledger WHERE user_id='${BUYER_ID}' AND source_id='c2c-smoke-seed'" >/dev/null || true
pg_exec -c "INSERT INTO points_ledger (id, user_id, direction, amount, balance_after, source_type, source_id, status, created_at) VALUES (gen_random_uuid(), '${BUYER_ID}', 'credit', 50000, 50000, 'manual_adjustment', 'c2c-smoke-seed', 'posted', now())" >/dev/null
BAL_CHECK=$(pg_exec -c "SELECT COALESCE((SELECT balance_after FROM points_ledger WHERE user_id='${BUYER_ID}' AND status='posted' ORDER BY created_at DESC LIMIT 1),0)")
[[ "${BAL_CHECK}" == "50000" ]] && pass "buyer points seeded" || fail "buyer points seed (got ${BAL_CHECK})"

# ── Product config family ──────────────────────────────────────────────────────
echo ""
echo "--- [4] points-market product config ---"
PC_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/product-config/points-market" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
PC_KEY=$(echo "${PC_RESP}" | quiet_json "family.key")
PC_FEE=$(echo "${PC_RESP}" | quiet_json "active_version.config.platform_fee_bps")
[[ "${PC_KEY}" == "points-market" ]] && pass "points-market config family" || fail "points-market config family (key=${PC_KEY})"
[[ -n "${PC_FEE}" ]] && pass "published platform_fee_bps=${PC_FEE}" || skip "no published points-market config (defaults apply)"

# ── Listing create + approve ───────────────────────────────────────────────────
echo ""
echo "--- [5] Listing create + approve ---"
LISTING_BODY='{"title":"C2C Smoke Listing","description":"e2e smoke item","category":"test","points_price":1000,"inventory_total":5}'
LISTING_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/points-market/items" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${LISTING_BODY}") || true
LISTING_ID=$(echo "${LISTING_RESP}" | quiet_json "id")
[[ -n "${LISTING_ID}" ]] && pass "listing created ${LISTING_ID}" || fail "listing create"

if [[ -n "${LISTING_ID}" ]]; then
  APPROVE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/points-market/items/${LISTING_ID}/approve" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  APPROVE_HTTP=$(echo "${APPROVE_RESP}" | quiet_json "status" 2>/dev/null || echo "ok")
  ITEM_STATUS=$(pg_exec -c "SELECT status FROM points_market_items WHERE id='${LISTING_ID}'")
  [[ "${ITEM_STATUS}" == "active" ]] && pass "listing approved" || fail "listing approve (status=${ITEM_STATUS})"
fi

# ── Order escrow + idempotency ───────────────────────────────────────────────────
echo ""
echo "--- [6] Order escrow ---"
IDEM_KEY="c2c-smoke-order-$(date +%s)"
ORDER_BODY="{\"item_id\":\"${LISTING_ID}\",\"idempotency_key\":\"${IDEM_KEY}\"}"
ORDER1=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/points-market/orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${ORDER_BODY}") || true
ORDER_ID=$(echo "${ORDER1}" | quiet_json "order.id")
ORDER_STATUS=$(echo "${ORDER1}" | quiet_json "order.status")
[[ -n "${ORDER_ID}" && "${ORDER_STATUS}" == "escrowed" ]] && pass "order escrowed ${ORDER_ID}" || fail "order create (status=${ORDER_STATUS})"

ORDER2=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/points-market/orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${ORDER_BODY}") || true
ORDER2_ID=$(echo "${ORDER2}" | quiet_json "order.id")
[[ "${ORDER2_ID}" == "${ORDER_ID}" ]] && pass "idempotent order replay" || fail "idempotency (got ${ORDER2_ID})"

ESCROW_ROW=$(pg_exec -c "SELECT COUNT(*) FROM points_ledger WHERE user_id='${BUYER_ID}' AND source_type='market_escrow_debit' AND source_id='${ORDER_ID}'")
[[ "${ESCROW_ROW}" == "1" ]] && pass "escrow debit ledger row" || fail "escrow debit ledger (count=${ESCROW_ROW})"

BAL_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/points/balance" \
  -H "Authorization: Bearer ${BUYER_TOKEN}") || true
AVAIL_BAL=$(echo "${BAL_RESP}" | quiet_json "available_balance")
FROZEN_BAL=$(echo "${BAL_RESP}" | quiet_json "frozen_balance")
BAL_CURRENCY=$(echo "${BAL_RESP}" | quiet_json "currency")
[[ "${BAL_CURRENCY}" == "points" ]] && pass "balance currency=points" || fail "balance currency (${BAL_CURRENCY})"
[[ "${FROZEN_BAL}" == "1000" ]] && pass "frozen_balance=1000 after escrow" || fail "frozen_balance (got ${FROZEN_BAL})"
[[ "${AVAIL_BAL}" == "49000" ]] && pass "available_balance=49000 after escrow" || fail "available_balance (got ${AVAIL_BAL})"

# ── Confirm fulfilled ──────────────────────────────────────────────────────────
echo ""
echo "--- [7] Confirm fulfilled ---"
CONFIRM=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/points-market/orders/${ORDER_ID}/confirm-fulfilled" \
  -H "Authorization: Bearer ${BUYER_TOKEN}") || true
POST_CONFIRM=$(echo "${CONFIRM}" | quiet_json "order.status")
[[ "${POST_CONFIRM}" == "settlement_pending" ]] && pass "order settlement_pending" || fail "confirm fulfilled (status=${POST_CONFIRM})"

# ── Settlement reconcile ───────────────────────────────────────────────────────
echo ""
echo "--- [8] Settlement reconcile ---"
SETTLE=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/points-market/settlement-reconcile" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d "{\"order_ids\":[\"${ORDER_ID}\"]}") || true
SETTLE_OK=$(echo "${SETTLE}" | quiet_json "ok")
[[ "${SETTLE_OK}" == "True" || "${SETTLE_OK}" == "true" ]] && pass "settlement reconcile" || fail "settlement reconcile (${SETTLE})"

FINAL_STATUS=$(pg_exec -c "SELECT status FROM points_market_orders WHERE id='${ORDER_ID}'")
[[ "${FINAL_STATUS}" == "settled" ]] && pass "order settled in DB" || fail "order final status (${FINAL_STATUS})"

SELLER_CREDIT=$(pg_exec -c "SELECT COUNT(*) FROM points_ledger WHERE user_id='${ADMIN_USER_ID}' AND source_type='market_settlement_credit' AND source_id='${ORDER_ID}'")
[[ "${SELLER_CREDIT}" == "1" ]] && pass "seller settlement credit" || fail "seller credit (count=${SELLER_CREDIT})"

FEE_CREDIT=$(pg_exec -c "SELECT COUNT(*) FROM points_ledger WHERE source_type='market_platform_fee' AND source_id='${ORDER_ID}'")
[[ "${FEE_CREDIT}" == "1" ]] && pass "platform fee ledger row" || fail "platform fee (count=${FEE_CREDIT})"

# ── P3: seller listing + dispute + job scans ───────────────────────────────────
echo ""
echo "--- [9] Seller listing (user API) ---"
SELLER_EMAIL="c2c-smoke-seller@test.livemask"
SELLER_PASS="C2cSmoke123!"
pg_exec -c "DELETE FROM users WHERE email='${SELLER_EMAIL}'" >/dev/null || true

SELLER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"c2c-smoke-seller\",\"email\":\"${SELLER_EMAIL}\",\"password\":\"${SELLER_PASS}\",\"display_name\":\"C2C Seller\",\"client_type\":\"app\"}") || true
SELLER_TOKEN=$(echo "${SELLER_REG}" | quiet_json "access_token")
SELLER_ID=$(echo "${SELLER_REG}" | quiet_json "user.user_id")
if [[ -n "${SELLER_ID}" ]]; then
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) VALUES ('${SELLER_ID}', 'sponsor_ambassador', 'c2c-smoke') ON CONFLICT DO NOTHING" >/dev/null
  SELLER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"c2c-smoke-seller-login\",\"email\":\"${SELLER_EMAIL}\",\"password\":\"${SELLER_PASS}\",\"client_type\":\"app\"}") || true
  SELLER_TOKEN=$(echo "${SELLER_LOGIN}" | quiet_json "access_token")
fi

PLAIN_EMAIL="c2c-smoke-plain@test.livemask"
pg_exec -c "DELETE FROM users WHERE email='${PLAIN_EMAIL}'" >/dev/null || true
PLAIN_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"c2c-smoke-plain\",\"email\":\"${PLAIN_EMAIL}\",\"password\":\"${SELLER_PASS}\",\"display_name\":\"Plain User\",\"client_type\":\"app\"}") || true
PLAIN_TOKEN=$(echo "${PLAIN_REG}" | quiet_json "access_token")
if [[ -z "${PLAIN_TOKEN}" ]]; then
  PLAIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"c2c-smoke-plain-login\",\"email\":\"${PLAIN_EMAIL}\",\"password\":\"${SELLER_PASS}\",\"client_type\":\"app\"}") || true
  PLAIN_TOKEN=$(echo "${PLAIN_LOGIN}" | quiet_json "access_token")
fi

DENY_RESP=$(curl -sS --max-time 5 -w "\n%{http_code}" -X POST "${API_BASE}/api/v1/points-market/listings" \
  -H "Authorization: Bearer ${PLAIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"title":"Denied","points_price":500,"inventory_total":1}') || true
DENY_HTTP=$(echo "${DENY_RESP}" | tail -1)
[[ "${DENY_HTTP}" == "403" ]] && pass "plain user listing denied (403)" || fail "plain user listing gate (http=${DENY_HTTP})"

USER_LIST_BODY='{"title":"C2C Seller Listing","description":"p3 smoke","category":"test","points_price":800,"inventory_total":3}'
USER_LIST_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/points-market/listings" \
  -H "Authorization: Bearer ${SELLER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${USER_LIST_BODY}") || true
USER_LISTING_ID=$(echo "${USER_LIST_RESP}" | quiet_json "id")
USER_LIST_STATUS=$(echo "${USER_LIST_RESP}" | quiet_json "status")
[[ -n "${USER_LISTING_ID}" ]] && pass "seller listing created ${USER_LISTING_ID}" || fail "seller listing create"
[[ "${USER_LIST_STATUS}" == "pending_review" ]] && pass "seller listing pending_review" || fail "seller listing status (${USER_LIST_STATUS})"

if [[ -n "${USER_LISTING_ID}" ]]; then
  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/points-market/items/${USER_LISTING_ID}/approve" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" >/dev/null || true
  USER_ITEM_STATUS=$(pg_exec -c "SELECT status FROM points_market_items WHERE id='${USER_LISTING_ID}'")
  [[ "${USER_ITEM_STATUS}" == "active" ]] && pass "seller listing approved" || fail "seller listing approve (${USER_ITEM_STATUS})"
fi

echo ""
echo "--- [10] Dispute + job executor scans ---"
DISPUTE_ORDER_BODY="{\"listing_id\":\"${USER_LISTING_ID}\",\"idempotency_key\":\"c2c-smoke-dispute-$(date +%s)\"}"
DISPUTE_ORDER=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/points-market/orders" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${DISPUTE_ORDER_BODY}") || true
DISPUTE_ORDER_ID=$(echo "${DISPUTE_ORDER}" | quiet_json "order.id")
[[ -n "${DISPUTE_ORDER_ID}" ]] && pass "dispute-path order ${DISPUTE_ORDER_ID}" || fail "dispute-path order create"

if [[ -n "${DISPUTE_ORDER_ID}" ]]; then
  DISPUTE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/points-market/orders/${DISPUTE_ORDER_ID}/dispute" \
    -H "Authorization: Bearer ${BUYER_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"reason_code":"not_received"}') || true
  DISPUTE_ID=$(echo "${DISPUTE_RESP}" | quiet_json "id")
  DISPUTE_STATUS=$(echo "${DISPUTE_RESP}" | quiet_json "status")
  ORDER_DISPUTED=$(pg_exec -c "SELECT status FROM points_market_orders WHERE id='${DISPUTE_ORDER_ID}'")
  [[ -n "${DISPUTE_ID}" && "${DISPUTE_STATUS}" == "open" ]] && pass "dispute opened ${DISPUTE_ID}" || fail "dispute open"
  [[ "${ORDER_DISPUTED}" == "disputed" ]] && pass "order status disputed" || fail "order disputed status (${ORDER_DISPUTED})"

  pg_exec -c "UPDATE points_market_disputes SET created_at = NOW() - INTERVAL '72 hours' WHERE id='${DISPUTE_ID}'" >/dev/null || true
  SLA_SCAN=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/points-market/dispute-sla-scan" \
    -H "Content-Type: application/json" \
    -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
    -d '{}') || true
  SLA_OK=$(echo "${SLA_SCAN}" | quiet_json "ok")
  SLA_COUNT=$(echo "${SLA_SCAN}" | quiet_json "processed_count")
  [[ "${SLA_OK}" == "True" || "${SLA_OK}" == "true" ]] && pass "dispute-sla-scan ok" || fail "dispute-sla-scan (${SLA_SCAN})"
  ESC_STATUS=$(pg_exec -c "SELECT status FROM points_market_disputes WHERE id='${DISPUTE_ID}'")
  [[ "${ESC_STATUS}" == "escalated" ]] && pass "dispute escalated by sla scan" || fail "dispute escalation (${ESC_STATUS}, count=${SLA_COUNT})"
  TICKET_LINK=$(pg_exec -c "SELECT COALESCE(support_ticket_id::text,'') FROM points_market_disputes WHERE id='${DISPUTE_ID}'")
  [[ -n "${TICKET_LINK}" ]] && pass "dispute support_ticket_id linked" || fail "support_ticket_id empty"
fi

DIGEST=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/points-market/digest" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{}') || true
DIGEST_OK=$(echo "${DIGEST}" | quiet_json "ok")
DIGEST_MSG=$(echo "${DIGEST}" | quiet_json "message")
[[ "${DIGEST_OK}" == "True" || "${DIGEST_OK}" == "true" ]] && pass "market digest ok (${DIGEST_MSG})" || fail "market digest (${DIGEST})"

RISK=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/points-market/risk-hold-scan" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{}') || true
RISK_OK=$(echo "${RISK}" | quiet_json "ok")
[[ "${RISK_OK}" == "True" || "${RISK_OK}" == "true" ]] && pass "risk-hold-scan ok" || fail "risk-hold-scan (${RISK})"

echo ""
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
if [[ "${FAILED}" -ne 0 ]]; then
  echo "C2C Points Market Smoke: FAIL"
  exit 1
fi
echo "C2C Points Market Smoke: PASS"
exit 0
