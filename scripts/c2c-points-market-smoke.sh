#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-C2C-POINTS-MARKET-PORTAL-AND-SMOKE-001
# C2C Points Market: unit tests + Postgres listing → escrow → settle e2e
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="${BACKEND_ROOT:-${SCRIPT_DIR}/../livemask-backend}"
JOB_ROOT="${JOB_ROOT:-${SCRIPT_DIR}/../livemask-job-service}"
COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
INTERNAL_SECRET="${INTERNAL_JOB_SECRET:-test-internal-secret}"

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
go test ./internal/jobs/... -run 'TestDefinitionDrift' -count=1
pass "job definition drift"

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

echo ""
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
if [[ "${FAILED}" -ne 0 ]]; then
  echo "C2C Points Market Smoke: FAIL"
  exit 1
fi
echo "C2C Points Market Smoke: PASS"
exit 0
