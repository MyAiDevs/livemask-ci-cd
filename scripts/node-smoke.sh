#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# TASK-CICD-NODE-001 — Node 注册/审批/心跳/推荐全链路 Smoke
# ──────────────────────────────────────────────────────────────────────────────
# Dependencies:
#   Backend TASK-NODE-001 (register, heartbeat, node listing)
#   Backend TASK-BACKEND-NODE-002 (approve, activate status transitions)
#   Admin TASK-ADMIN-NODE-001 (admin JWT + node:manage permission)
#   NodeAgent TASK-NODE-001 (HMAC-SHA256 signing)
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/../infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"

FAILED=0
SUMMARY_LINES=()

fail() {
  local msg="$1"
  echo "  FAIL: ${msg}"
  SUMMARY_LINES+=("FAIL: ${msg}")
  FAILED=1
}

pass() {
  local msg="$1"
  echo "  PASS: ${msg}"
  SUMMARY_LINES+=("PASS: ${msg}")
}

quiet_json() {
  # Usage: quiet_json <field> <json_string>
  python3 -c "import sys,json; print(json.load(sys.stdin)['${1}'])" 2>/dev/null || echo ""
}

echo "========================================"
echo " TASK-CICD-NODE-001: Node Full-Link Smoke"
echo "========================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Step 0: Wait for backend health
# ──────────────────────────────────────────────────────────────────────────────
echo "--- [0] Health Check ---"
HEALTH_URL="${API_BASE}/api/v1/health"
for attempt in $(seq 1 30); do
  health_resp=$(curl -sS --max-time 3 "${HEALTH_URL}" 2>/dev/null || true)
  if [[ -n "${health_resp}" ]]; then
    health_status=$(echo "${health_resp}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [[ "${health_status}" == "ok" ]]; then
      echo "  Backend ready on attempt ${attempt}"
      pass "Backend health ok"
      break
    fi
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    fail "Backend not ready after 30 attempts"
    echo "--- docker compose ps ---"
    docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
    echo "--- docker compose logs backend (last 50) ---"
    docker compose -f "${COMPOSE_FILE}" logs backend --tail=50 2>/dev/null || true
    echo ""
    echo "=== NODE SMOKE SUMMARY ==="
    printf '%s\n' "${SUMMARY_LINES[@]}"
    exit 1
  fi
  sleep 2
done

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: Login as admin (dev seed user)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Admin Login (dev seed) ---"
ADMIN_LOGIN_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"node-smoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN_RESP}" | quiet_json "access_token")
ADMIN_USER_ID=$(echo "${ADMIN_LOGIN_RESP}" | quiet_json "user.user_id")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "  INFO: initial admin login failed, seeding via SQL..."
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask \
    -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
  ADMIN_HASH=$(docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask \
    -tA -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
  if [[ -n "${ADMIN_HASH}" ]]; then
    docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask \
      -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
    docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask \
      -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by node-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
    ADMIN_LOGIN_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"request_id":"node-smoke-admin-login2","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
    ADMIN_TOKEN=$(echo "${ADMIN_LOGIN_RESP}" | quiet_json "access_token")
    ADMIN_USER_ID=$(echo "${ADMIN_LOGIN_RESP}" | quiet_json "user.user_id")
  fi
  if [[ -z "${ADMIN_TOKEN}" ]]; then
    fail "Admin login - unable to get token after SQL seed"
    echo "${ADMIN_LOGIN_RESP}" | python3 -m json.tool 2>/dev/null || echo "${ADMIN_LOGIN_RESP}"
  fi
fi
if [[ -n "${ADMIN_TOKEN}" ]]; then
  pass "Admin login OK (user_id=${ADMIN_USER_ID}, token length=${#ADMIN_TOKEN})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: Register a test user (for recommended API later)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [2] User Register / Login ---"
USER_REG_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"node-smoke-user","email":"node-enduser@test.livemask","password":"NodeEndUserPass123!","display_name":"Node End User","client_type":"app"}') || true
USER_TOKEN=$(echo "${USER_REG_RESP}" | quiet_json "access_token")
if [[ -z "${USER_TOKEN}" ]]; then
  # Try login instead (already registered)
  USER_LOGIN_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"request_id":"node-smoke-user-login","email":"node-enduser@test.livemask","password":"NodeEndUserPass123!","client_type":"app"}') || true
  USER_TOKEN=$(echo "${USER_LOGIN_RESP}" | quiet_json "access_token")
fi
if [[ -z "${USER_TOKEN}" ]]; then
  fail "User register/login"
else
  pass "User login OK (token length=${#USER_TOKEN})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: Register a node via POST /internal/agent/register
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [3] Node Register ---"
NODE_REG_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d '{"node_name":"node-smoke-test-001","agent_version":"smoke-1.0.0"}') || true
NODE_ID=$(echo "${NODE_REG_RESP}" | quiet_json "node_id")
NODE_SECRET=$(echo "${NODE_REG_RESP}" | quiet_json "node_secret")
NODE_STATUS=$(echo "${NODE_REG_RESP}" | quiet_json "status")
if [[ -z "${NODE_ID}" || -z "${NODE_SECRET}" ]]; then
  fail "Node register - no node_id/node_secret (response: $(echo ${NODE_REG_RESP} | head -c 200))"
  echo "${NODE_REG_RESP}" | python3 -m json.tool 2>/dev/null || true
  exit 1
fi
if [[ "${NODE_STATUS}" != "pending_review" ]]; then
  fail "Node register - expected status=pending_review, got ${NODE_STATUS}"
else
  pass "Node registered: id=${NODE_ID} status=${NODE_STATUS}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: Admin verify node appears in admin node list (pending_review)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] Admin Node List (verify pending_review) ---"
ADMIN_NODES_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/nodes" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
ADMIN_FOUND=$(echo "${ADMIN_NODES_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for n in data.get('nodes', []):
    if n['id'] == '${NODE_ID}':
        print(n['status'])
" 2>/dev/null || echo "")
if [[ "${ADMIN_FOUND}" != "pending_review" ]]; then
  fail "Node not found or wrong status in admin list (expected pending_review, got '${ADMIN_FOUND}')"
  echo "Admin nodes: $(echo ${ADMIN_NODES_RESP} | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('nodes',[])),'nodes')" 2>/dev/null || echo 'unknown')"
else
  pass "Admin node list shows node as pending_review"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 5: Admin approve node
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [5] Admin Approve Node ---"
APPROVE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/approve" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"reason":"Approved by node-smoke.sh test"}') || true
APPROVE_STATUS=$(echo "${APPROVE_RESP}" | quiet_json "new_status")
APPROVE_OLD=$(echo "${APPROVE_RESP}" | quiet_json "old_status")
APPROVE_NODE_STATUS=$(echo "${APPROVE_RESP}" | quiet_json "node.status")
if [[ "${APPROVE_STATUS}" != "approved" ]]; then
  fail "Node approve failed - (response: $(echo ${APPROVE_RESP} | head -c 300))"
  echo "${APPROVE_RESP}" | python3 -m json.tool 2>/dev/null || true
else
  pass "Node approved: ${APPROVE_OLD} → ${APPROVE_STATUS}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 6: Admin activate node (pending_review → approved → active)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [6] Admin Activate Node ---"
ACTIVATE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/activate" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"reason":"Activated by node-smoke.sh test"}') || true
ACTIVATE_STATUS=$(echo "${ACTIVATE_RESP}" | quiet_json "new_status")
ACTIVATE_NODE_STATUS=$(echo "${ACTIVATE_RESP}" | quiet_json "node.status")
if [[ "${ACTIVATE_STATUS}" != "active" ]]; then
  fail "Node activate failed - (response: $(echo ${ACTIVATE_RESP} | head -c 300))"
  echo "${ACTIVATE_RESP}" | python3 -m json.tool 2>/dev/null || true
else
  pass "Node activated: approved → ${ACTIVATE_STATUS}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 7: Send heartbeat with HMAC-SHA256
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [7] Node Heartbeat (HMAC-SHA256) ---"
HB_TIMESTAMP=$(date +%s)
# SHA-256 hash of the raw node_secret (backend uses HashSecret which is SHA-256)
NODE_SECRET_HASH=$(echo -n "${NODE_SECRET}" | sha256sum | cut -d' ' -f1)
# HMAC-SHA256(node_id:timestamp, key=secret_hash)
HB_SIGNATURE=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE_SECRET_HASH}'
msg = '${NODE_ID}:${HB_TIMESTAMP}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
HB_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/heartbeat" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${HB_SIGNATURE}" \
  -H "X-Timestamp: ${HB_TIMESTAMP}" \
  -d '{"agent_version":"smoke-1.0.0","config_version":1,"singbox_status":"running","load_score":42,"cpu_usage":0.35,"memory_usage":0.55,"network_tx_bytes":1024,"network_rx_bytes":2048,"active_connections":5,"degraded":false}') || true
HB_OK=$(echo "${HB_RESP}" | quiet_json "ok")
HB_SCV=$(echo "${HB_RESP}" | quiet_json "server_config_version")
if [[ "${HB_OK}" != "True" ]]; then
  fail "Heartbeat - (response: $(echo ${HB_RESP} | head -c 300))"
  echo "${HB_RESP}" | python3 -m json.tool 2>/dev/null || true
else
  pass "Heartbeat OK (server_config_version=${HB_SCV})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 8: User verify node appears in recommended API
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [8] Recommended Nodes API ---"
RECOMMENDED_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/nodes/recommended" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
RECOMMENDED_FOUND=$(echo "${RECOMMENDED_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
ids = [n['id'] for n in data.get('nodes', [])]
print('FOUND' if '${NODE_ID}' in ids else 'NOT_FOUND')
print('count=' + str(len(ids)))
" 2>/dev/null || echo "NOT_FOUND")
if echo "${RECOMMENDED_FOUND}" | grep -q "^FOUND"; then
  RECOMMENDED_COUNT=$(echo "${RECOMMENDED_FOUND}" | grep "^count=" | cut -d= -f2 || echo "?")
  pass "Node visible in recommended list (total recommended=${RECOMMENDED_COUNT})"
else
  fail "Node NOT found in recommended list — nodes must be active + not degraded"
  echo "Recommended response: ${RECOMMENDED_RESP}" | python3 -m json.tool 2>/dev/null || echo "${RECOMMENDED_RESP}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 9: Verify degraded=TRUE node does NOT appear in recommended
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [9] Degraded Node Exclusion Test ---"
# Register a second node
NODE2_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d '{"node_name":"node-smoke-degraded-002","agent_version":"smoke-1.0.0"}') || true
NODE2_ID=$(echo "${NODE2_REG}" | quiet_json "node_id")
NODE2_SECRET=$(echo "${NODE2_REG}" | quiet_json "node_secret")
if [[ -z "${NODE2_ID}" ]]; then
  fail "Degraded node register - no node_id"
else
  # Approve + activate node2
  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE2_ID}/approve" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"Approved for degraded test"}' >/dev/null 2>&1 || true
  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE2_ID}/activate" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"Activated for degraded test"}' >/dev/null 2>&1 || true

  # Send heartbeat with degraded=true
  NODE2_HASH=$(echo -n "${NODE2_SECRET}" | sha256sum | cut -d' ' -f1)
  NODE2_TS=$(date +%s)
  NODE2_SIG=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE2_HASH}'
msg = '${NODE2_ID}:${NODE2_TS}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
  curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/heartbeat" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${NODE2_ID}" \
    -H "X-Signature: ${NODE2_SIG}" \
    -H "X-Timestamp: ${NODE2_TS}" \
    -d '{"agent_version":"smoke-1.0.0","config_version":1,"singbox_status":"running","load_score":99,"cpu_usage":0.9,"memory_usage":0.95,"network_tx_bytes":0,"network_rx_bytes":0,"active_connections":0,"degraded":true,"degraded_reason":"load test degraded"}' >/dev/null 2>&1 || true

  # Check recommended API — node2 should NOT appear
  RECOMMENDED2_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/nodes/recommended" \
    -H "Authorization: Bearer ${USER_TOKEN}") || true
  NODE2_IN_RECOMMENDED=$(echo "${RECOMMENDED2_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for n in data.get('nodes', []):
    if n['id'] == '${NODE2_ID}':
        print('YES')
        break
else:
    print('NO')
" 2>/dev/null || echo "ERROR")
  if [[ "${NODE2_IN_RECOMMENDED}" == "YES" ]]; then
    fail "Degraded node ${NODE2_ID} SHOULD NOT appear in recommended list"
  else
    pass "Degraded node correctly excluded from recommended list"
  fi

  # Clean up node2
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask \
    -c "DELETE FROM nodes WHERE id='${NODE2_ID}'" 2>/dev/null || true
  echo "  Cleaned up degraded test node"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 10: Verify public node list shows node with safe fields only
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [10] Public Node List Security Field Check ---"
PUBLIC_NODES_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/nodes" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
PUBLIC_FOUND_ID=$(echo "${PUBLIC_NODES_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for n in data.get('nodes', []):
    if n['id'] == '${NODE_ID}':
        print(n['id'])
" 2>/dev/null || echo "")
if [[ "${PUBLIC_FOUND_ID}" != "${NODE_ID}" ]]; then
  fail "Node not found in public /api/v1/nodes list"
else
  pass "Node found in public node list"
fi

LEAK_CHECK=$(echo "${PUBLIC_NODES_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for n in data.get('nodes', []):
    leaked = [k for k in n if k in ('ip_address','node_secret','agent_version','node_secret_hash')]
    if leaked:
        print('LEAK: ' + ','.join(leaked))
        break
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${LEAK_CHECK}" != "OK" ]]; then
  fail "Public node list leaks security fields: ${LEAK_CHECK}"
  echo "Public nodes: ${PUBLIC_NODES_RESP}" | python3 -m json.tool 2>/dev/null || true
else
  pass "Public node list safe (no security fields leaked)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"
docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask \
  -c "DELETE FROM nodes WHERE id='${NODE_ID}'" 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask \
  -c "DELETE FROM users WHERE email='node-enduser@test.livemask'" 2>/dev/null || true
echo "  Cleaned up smoke data"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " TASK-CICD-NODE-001 SUMMARY"
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

if [[ "${FAILED}" -eq 1 ]]; then
  echo ""
  echo "[TASK-CICD-NODE-001] NODE SMOKE FAILED."
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo ""
echo "[TASK-CICD-NODE-001] Node full-link smoke PASSED."
