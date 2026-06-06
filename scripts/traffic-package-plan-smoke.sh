#!/usr/bin/env bash
# TASK-CICD-TRAFFIC-PACKAGE-PLAN-SMOKE-001 — traffic package catalog → points purchase → entitlement
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
echo "--- [6] Usage ingest + exhausted gate ---"
QUOTA_BYTES=$(echo "${ENT_RESP}" | quiet_json "entitlement.traffic_quota_bytes")
USED_INGEST=$((QUOTA_BYTES + 1024))
INGEST=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/traffic-package/usage-ingest" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d "{\"user_id\":\"${BUYER_ID}\",\"bytes_used\":${USED_INGEST}}") || true
INGEST_OK=$(echo "${INGEST}" | quiet_json "ok")
ENT_EXHAUSTED=$(pg_exec -c "SELECT status FROM user_traffic_entitlements WHERE user_id='${BUYER_ID}' ORDER BY created_at DESC LIMIT 1")
[[ "${INGEST_OK}" == "True" || "${INGEST_OK}" == "true" ]] && pass "usage ingest ok" || fail "usage ingest (${INGEST})"
[[ "${ENT_EXHAUSTED}" == "exhausted" ]] && pass "entitlement exhausted after usage" || fail "entitlement status (${ENT_EXHAUSTED})"

CONNECT=$(curl -sS --max-time 5 -w "\n%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Authorization: Bearer ${BUYER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"platform":"smoke","app_version":"1.0"}') || true
CONNECT_HTTP=$(echo "${CONNECT}" | tail -1)
[[ "${CONNECT_HTTP}" == "403" || "${CONNECT_HTTP}" == "400" ]] && pass "connect blocked when exhausted (${CONNECT_HTTP})" || fail "connect gate (${CONNECT_HTTP})"

echo ""
echo "--- [7] Entitlement expire job ---"
EXPIRE_BUYER="traffic-smoke-expire@test.livemask"
EXPIRE_PASS="TrafficSmoke123!"
pg_exec -c "DELETE FROM users WHERE email='${EXPIRE_BUYER}'" >/dev/null || true
EXPIRE_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"tp-expire\",\"email\":\"${EXPIRE_BUYER}\",\"password\":\"${EXPIRE_PASS}\",\"display_name\":\"Expire Buyer\",\"client_type\":\"app\"}") || true
EXPIRE_TOKEN=$(echo "${EXPIRE_REG}" | quiet_json "access_token")
EXPIRE_ID=$(echo "${EXPIRE_REG}" | quiet_json "user.user_id")
pg_exec -c "INSERT INTO points_ledger (id, user_id, direction, amount, balance_after, source_type, source_id, status, created_at) SELECT gen_random_uuid(), '${EXPIRE_ID}', 'credit', ${SEED_AMOUNT}, ${SEED_AMOUNT}, 'manual_adjustment', 'traffic-expire-seed', 'posted', now() WHERE EXISTS (SELECT 1 FROM users WHERE id='${EXPIRE_ID}')" >/dev/null
curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/traffic-package-orders" \
  -H "Authorization: Bearer ${EXPIRE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"plan_id\":\"${PLAN_ID}\",\"idempotency_key\":\"expire-$(date +%s)\",\"payment_method\":\"points\"}" >/dev/null || true
pg_exec -c "UPDATE user_traffic_entitlements SET ends_at = NOW() - INTERVAL '1 hour' WHERE user_id='${EXPIRE_ID}'" >/dev/null || true
EXPIRE_JOB=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/traffic-package/entitlement-expire" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{}') || true
EXPIRE_OK=$(echo "${EXPIRE_JOB}" | quiet_json "ok")
EXPIRE_COUNT=$(echo "${EXPIRE_JOB}" | quiet_json "processed_count")
EXPIRE_STATUS=$(pg_exec -c "SELECT status FROM user_traffic_entitlements WHERE user_id='${EXPIRE_ID}' ORDER BY created_at DESC LIMIT 1")
[[ "${EXPIRE_OK}" == "True" || "${EXPIRE_OK}" == "true" ]] && pass "entitlement-expire job ok (count=${EXPIRE_COUNT})" || fail "entitlement-expire (${EXPIRE_JOB})"
[[ "${EXPIRE_STATUS}" == "expired" ]] && pass "entitlement expired in DB" || fail "expire status (${EXPIRE_STATUS})"

echo ""
echo "--- [8] USDT pending order ---"
USDT_BUYER="traffic-smoke-usdt@test.livemask"
USDT_PASS="TrafficSmoke123!"
pg_exec -c "DELETE FROM users WHERE email='${USDT_BUYER}'" >/dev/null || true
USDT_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"tp-usdt\",\"email\":\"${USDT_BUYER}\",\"password\":\"${USDT_PASS}\",\"display_name\":\"USDT Buyer\",\"client_type\":\"app\"}") || true
USDT_TOKEN=$(echo "${USDT_REG}" | quiet_json "access_token")
USDT_ID=$(echo "${USDT_REG}" | quiet_json "user.user_id")
pg_exec -c "UPDATE traffic_package_plans SET usdt_price_amount = 9.99, payment_methods = '[\"points\",\"usdt\"]'::jsonb WHERE id = '${PLAN_ID}'" >/dev/null || true
USDT_IDEM="usdt-smoke-$(date +%s)"
USDT_ORDER=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/traffic-package-orders" \
  -H "Authorization: Bearer ${USDT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"plan_id\":\"${PLAN_ID}\",\"idempotency_key\":\"${USDT_IDEM}\",\"payment_method\":\"usdt\"}") || true
USDT_ORDER_ID=$(echo "${USDT_ORDER}" | quiet_json "order.id")
USDT_ORDER_STATUS=$(echo "${USDT_ORDER}" | quiet_json "order.status")
USDT_ORDER_AMOUNT=$(echo "${USDT_ORDER}" | quiet_json "order.usdt_amount")
[[ -n "${USDT_ORDER_ID}" && "${USDT_ORDER_STATUS}" == "pending_payment" ]] && pass "usdt order pending ${USDT_ORDER_ID}" || fail "usdt pending order (status=${USDT_ORDER_STATUS})"
[[ -n "${USDT_ORDER_AMOUNT}" && "${USDT_ORDER_AMOUNT}" != "0" ]] && pass "usdt amount snapshot (${USDT_ORDER_AMOUNT})" || fail "usdt amount (${USDT_ORDER_AMOUNT})"

echo ""
echo "--- [9] USDT order reconcile job ---"
RECONCILE_JOB=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/traffic-package/order-reconcile" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{}') || true
RECONCILE_OK=$(echo "${RECONCILE_JOB}" | quiet_json "ok")
RECONCILE_COUNT=$(echo "${RECONCILE_JOB}" | quiet_json "processed_count")
USDT_FULFILLED=$(pg_exec -c "SELECT status FROM traffic_package_orders WHERE id='${USDT_ORDER_ID}'")
USDT_ENT_STATUS=$(pg_exec -c "SELECT status FROM user_traffic_entitlements WHERE user_id='${USDT_ID}' ORDER BY created_at DESC LIMIT 1")
[[ "${RECONCILE_OK}" == "True" || "${RECONCILE_OK}" == "true" ]] && pass "order-reconcile job ok (count=${RECONCILE_COUNT})" || fail "order-reconcile (${RECONCILE_JOB})"
[[ "${USDT_FULFILLED}" == "fulfilled" ]] && pass "usdt order fulfilled" || fail "usdt order status (${USDT_FULFILLED})"
[[ "${USDT_ENT_STATUS}" == "active" ]] && pass "usdt entitlement active" || fail "usdt entitlement (${USDT_ENT_STATUS})"

echo ""
echo "--- [10] Admin commerce package CRUD + USDT order ---"
PKG_KEY="smoke-usdt-pack-$(date +%s)"
CREATE_PKG=$(curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/packages" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"package_key\":\"${PKG_KEY}\",\"display_name\":\"Smoke USDT Pack\",\"description\":\"smoke\",\"usdt_price_amount\":\"19.99\",\"points_grant\":2500}") || true
PKG_ID=$(echo "${CREATE_PKG}" | quiet_json "id")
PKG_STATUS=$(echo "${CREATE_PKG}" | quiet_json "status")
[[ -n "${PKG_ID}" && "${PKG_STATUS}" == "draft" ]] && pass "admin create draft package ${PKG_ID}" || fail "admin create package (${CREATE_PKG})"
UPDATE_PKG=$(curl -sS --max-time 10 -X PUT "${API_BASE}/admin/api/v1/packages/${PKG_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"display_name":"Smoke USDT Pack Updated","points_grant":3000}') || true
UPDATED_GRANT=$(echo "${UPDATE_PKG}" | quiet_json "points_grant")
[[ "${UPDATED_GRANT}" == "3000" ]] && pass "admin update package" || fail "admin update (${UPDATE_PKG})"
PUBLISH_PKG=$(curl -sS --max-time 10 -X POST "${API_BASE}/admin/api/v1/packages/${PKG_ID}/publish" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
PUBLISHED_STATUS=$(echo "${PUBLISH_PKG}" | quiet_json "status")
[[ "${PUBLISHED_STATUS}" == "active" ]] && pass "admin publish package" || fail "admin publish (${PUBLISH_PKG})"
COMM_USDT_ORDER=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/package-orders" \
  -H "Authorization: Bearer ${USDT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"package_id\":\"${PKG_ID}\",\"idempotency_key\":\"comm-usdt-$(date +%s)\",\"payment_method\":\"usdt\"}") || true
COMM_ORDER_STATUS=$(echo "${COMM_USDT_ORDER}" | quiet_json "order.status")
COMM_ORDER_USDT=$(echo "${COMM_USDT_ORDER}" | quiet_json "order.amount_usdt")
[[ "${COMM_ORDER_STATUS}" == "pending_payment" ]] && pass "commerce usdt pending order" || fail "commerce usdt order (${COMM_ORDER_STATUS})"
[[ -n "${COMM_ORDER_USDT}" && "${COMM_ORDER_USDT}" != "0" ]] && pass "commerce usdt amount (${COMM_ORDER_USDT})" || fail "commerce usdt amount"
COMM_RECON=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/commerce/package-order-reconcile" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d '{}') || true
COMM_RECON_OK=$(echo "${COMM_RECON}" | quiet_json "ok")
[[ "${COMM_RECON_OK}" == "True" || "${COMM_RECON_OK}" == "true" ]] && pass "commerce package-order-reconcile ok" || fail "commerce reconcile (${COMM_RECON})"

echo ""
echo "--- [11] Gate D — NodeAgent usage report (HMAC) ---"
NODE_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d '{"node_name":"traffic-smoke-node","agent_version":"smoke-1.0.0"}') || true
NODE_ID=$(echo "${NODE_REG}" | quiet_json "node_id")
NODE_SECRET=$(echo "${NODE_REG}" | quiet_json "node_secret")
if [[ -n "${NODE_ID}" && -n "${NODE_SECRET}" ]]; then
  HB_TS=$(date +%s)
  NODE_SECRET_HASH=$(echo -n "${NODE_SECRET}" | sha256sum | cut -d' ' -f1)
  HB_SIG=$(python3 -c "import hmac,hashlib; print(hmac.new('${NODE_SECRET_HASH}'.encode(),'${NODE_ID}:${HB_TS}'.encode(),hashlib.sha256).hexdigest())")
  curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/heartbeat" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${NODE_ID}" \
    -H "X-Signature: ${HB_SIG}" \
    -H "X-Timestamp: ${HB_TS}" \
    -d '{"agent_version":"smoke-1.0.0","config_version":1,"singbox_status":"running","load_score":10}' >/dev/null || true
  USAGE_BEFORE=$(pg_exec -c "SELECT COALESCE(traffic_used_bytes,0) FROM user_traffic_entitlements WHERE user_id='${USDT_ID}' ORDER BY created_at DESC LIMIT 1")
  USAGE_DELTA=2048
  USAGE_TS=$(date +%s)
  USAGE_SIG=$(python3 -c "import hmac,hashlib; print(hmac.new('${NODE_SECRET_HASH}'.encode(),'${NODE_ID}:${USAGE_TS}'.encode(),hashlib.sha256).hexdigest())")
  AGENT_USAGE=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/agent/traffic-usage/report" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${NODE_ID}" \
    -H "X-Signature: ${USAGE_SIG}" \
    -H "X-Timestamp: ${USAGE_TS}" \
    -d "{\"user_id\":\"${USDT_ID}\",\"session_id\":\"smoke-session\",\"bytes_used\":${USAGE_DELTA},\"bandwidth_limit_mbps\":10,\"speed_limit_supported\":true}") || true
  AGENT_OK=$(echo "${AGENT_USAGE}" | quiet_json "ok")
  USAGE_AFTER=$(pg_exec -c "SELECT COALESCE(traffic_used_bytes,0) FROM user_traffic_entitlements WHERE user_id='${USDT_ID}' ORDER BY created_at DESC LIMIT 1")
  EXPECTED_AFTER=$((USAGE_BEFORE + USAGE_DELTA))
  [[ "${AGENT_OK}" == "True" || "${AGENT_OK}" == "true" ]] && pass "nodeagent usage report ok" || fail "nodeagent usage (${AGENT_USAGE})"
  [[ "${USAGE_AFTER}" == "${EXPECTED_AFTER}" ]] && pass "traffic_used_bytes incremented (${USAGE_AFTER})" || fail "usage bytes before=${USAGE_BEFORE} after=${USAGE_AFTER}"
else
  fail "node register for Gate D (${NODE_REG})"
fi

echo ""
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
if [[ "${FAILED}" -ne 0 ]]; then
  echo "Traffic Package Plan Smoke: FAIL"
  exit 1
fi
echo "Traffic Package Plan Smoke: PASS"
exit 0
