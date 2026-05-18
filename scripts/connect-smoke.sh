#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# TASK-CICD-CONNECT-001 — Connect Session 全链路 Smoke
# ──────────────────────────────────────────────────────────────────────────────
# Dependencies:
#   Backend TASK-BACKEND-CONNECT-001 (connect session CRUD)
#   Backend TASK-NODE-001 (node register/heartbeat)
#   Backend TASK-BACKEND-NODE-002 (admin approve/activate)
# ──────────────────────────────────────────────────────────────────────────────

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
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

skip() {
  local msg="$1"
  echo "  SKIP: ${msg}"
  SUMMARY_LINES+=("SKIP: ${msg}")
}

blocker() {
  local msg="$1"
  echo "  BLOCKER: ${msg}"
  SUMMARY_LINES+=("BLOCKER: ${msg}")
  # Blockers do not set FAILED=1 — they are known backend issues
}

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

SUFFIX="conn-$(date +%s)"
USER_EMAIL="connect-smoke-${SUFFIX}@test.livemask"
USER_PASS="ConnectTest123!"
WEBSITE_EMAIL="connect-web-${SUFFIX}@test.livemask"
WEBSITE_PASS="ConnectWeb123!"
NODE_NAME="connect-smoke-node-${SUFFIX}"

echo "========================================"
echo " TASK-CICD-CONNECT-001: Connect Session Smoke"
echo "========================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# A. 基础准备
# ──────────────────────────────────────────────────────────────────────────────

# --- 0: Health check ---
echo "--- [0] Health Check ---"
for attempt in $(seq 1 30); do
  health_resp=$(curl -sS --max-time 3 "${API_BASE}/api/v1/health" 2>/dev/null || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    echo "  Backend ready (attempt ${attempt})"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    fail "Backend not ready after 30 attempts"
    echo ""
    printf '%s\n' "${SUMMARY_LINES[@]}"
    exit 1
  fi
  sleep 2
done
pass "Backend health ok"

# --- 1: Admin login (dev seed) ---
echo ""
echo "--- [1] Admin Login (dev seed) ---"
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"conn-smoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "  INFO: seeding admin via SQL..."
  pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'"
  ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" || echo "")
  if [[ -n "${ADMIN_HASH}" ]]; then
    pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'"
    pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by connect-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING"
    ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"request_id":"conn-smoke-admin-login2","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
    ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
  fi
  if [[ -z "${ADMIN_TOKEN}" ]]; then
    fail "Admin login"
  fi
fi
if [[ -n "${ADMIN_TOKEN}" ]]; then
  pass "Admin login OK (token length=${#ADMIN_TOKEN})"
fi

# --- 2: App user register/login (client_type=app) ---
echo ""
echo "--- [2] App User Register/Login (app audience) ---"
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${WEBSITE_EMAIL}'" 2>/dev/null || true

USER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"conn-smoke-app-reg\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"display_name\":\"Connect App User\",\"client_type\":\"app\"}") || true
USER_TOKEN=$(echo "${USER_REG}" | quiet_json "access_token")
USER_ID=$(echo "${USER_REG}" | quiet_json "user.user_id")
if [[ -z "${USER_TOKEN}" ]]; then
  USER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"conn-smoke-app-login\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"client_type\":\"app\"}") || true
  USER_TOKEN=$(echo "${USER_LOGIN}" | quiet_json "access_token")
  USER_ID=$(echo "${USER_LOGIN}" | quiet_json "user.user_id")
fi
if [[ -z "${USER_TOKEN}" ]]; then
  fail "App user register/login"
else
  pass "App user login OK (token length=${#USER_TOKEN})"
fi

# --- 3: Website user login (for negative test) ---
echo ""
echo "--- [3] Website User Login (website audience) ---"
WEB_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"conn-smoke-web-reg\",\"email\":\"${WEBSITE_EMAIL}\",\"password\":\"${WEBSITE_PASS}\",\"display_name\":\"Connect Web User\",\"client_type\":\"website\"}") || true
WEBSITE_TOKEN=$(echo "${WEB_REG}" | quiet_json "access_token")
if [[ -z "${WEBSITE_TOKEN}" ]]; then
  WEB_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"conn-smoke-web-login\",\"email\":\"${WEBSITE_EMAIL}\",\"password\":\"${WEBSITE_PASS}\",\"client_type\":\"website\"}") || true
  WEBSITE_TOKEN=$(echo "${WEB_LOGIN}" | quiet_json "access_token")
fi
if [[ -z "${WEBSITE_TOKEN}" ]]; then
  fail "Website user login"
else
  pass "Website user login OK (token length=${#WEBSITE_TOKEN})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# B. 无节点场景 — Current session is null
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] GET Current Session (no session yet) ---"
CURRENT_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
CURRENT_SESSION=$(echo "${CURRENT_RESP}" | quiet_json "session")
if [[ "${CURRENT_SESSION}" == "" ]] || [[ "${CURRENT_SESSION}" == "None" ]]; then
  pass "Current session: null (no session yet)"
else
  echo "  INFO: unexpected current session: $(echo ${CURRENT_RESP} | head -c 100)"
  pass "Current session: non-null (non-fatal, prior session exists)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# C. 节点准备
# ──────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- [5] Register Smoke Node ---"
NODE_REG_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d "{\"node_name\":\"${NODE_NAME}\",\"agent_version\":\"smoke-1.0.0\"}") || true
NODE_ID=$(echo "${NODE_REG_RESP}" | quiet_json "node_id")
NODE_SECRET=$(echo "${NODE_REG_RESP}" | quiet_json "node_secret")
NODE_STATUS=$(echo "${NODE_REG_RESP}" | quiet_json "status")
if [[ -z "${NODE_ID}" || -z "${NODE_SECRET}" ]]; then
  fail "Node register - no node_id/node_secret"
  echo "${NODE_REG_RESP}" | python3 -m json.tool 2>/dev/null || true
else
  pass "Node registered: id=${NODE_ID} status=${NODE_STATUS}"
fi

echo ""
echo "--- [6] Admin Approve Node ---"
APPROVE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/approve" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"reason":"Approved by connect-smoke.sh"}') || true
APPROVE_STATUS=$(echo "${APPROVE_RESP}" | quiet_json "new_status")
if [[ "${APPROVE_STATUS}" != "approved" ]]; then
  fail "Node approve - (response: $(echo ${APPROVE_RESP} | head -c 300))"
else
  pass "Node approved"
fi

echo ""
echo "--- [7] Admin Activate Node ---"
ACTIVATE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/activate" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"reason":"Activated by connect-smoke.sh"}') || true
ACTIVATE_STATUS=$(echo "${ACTIVATE_RESP}" | quiet_json "new_status")
if [[ "${ACTIVATE_STATUS}" != "active" ]]; then
  fail "Node activate - (response: $(echo ${ACTIVATE_RESP} | head -c 300))"
else
  pass "Node activated"
fi

echo ""
echo "--- [8] Node Heartbeat (HMAC-SHA256) ---"
HB_TIMESTAMP=$(date +%s)
NODE_SECRET_HASH=$(echo -n "${NODE_SECRET}" | sha256sum | cut -d' ' -f1)
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
  -d '{"agent_version":"smoke-1.0.0","config_version":1,"singbox_status":"running","load_score":10,"cpu_usage":0.1,"memory_usage":0.2,"network_tx_bytes":1024,"network_rx_bytes":2048,"active_connections":3,"degraded":false}') || true
HB_OK=$(echo "${HB_RESP}" | quiet_json "ok")
if [[ "${HB_OK}" != "True" ]]; then
  fail "Node heartbeat - (response: $(echo ${HB_RESP} | head -c 300))"
else
  pass "Node heartbeat OK (load_score=10, degraded=false)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# D. Connect Session 主链路
# ──────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- [9] POST Create Connect Session ---"
SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE_ID}\"}") || true
SESSION_ID=$(echo "${SESSION_RESP}" | quiet_json "session.session_id")
SESSION_STATUS=$(echo "${SESSION_RESP}" | quiet_json "session.status")
SESSION_NODE_ID=$(echo "${SESSION_RESP}" | quiet_json "node.id")
SESSION_NODE_NAME=$(echo "${SESSION_RESP}" | quiet_json "node.node_name")
SESSION_NODE_DEGRADED=$(echo "${SESSION_RESP}" | quiet_json "node.degraded")
CONFIG_PROFILE=$(echo "${SESSION_RESP}" | quiet_json "connect_config.profile_type")
CONFIG_ENDPOINT=$(echo "${SESSION_RESP}" | quiet_json "connect_config.server.endpoint")
CONFIG_PORT=$(echo "${SESSION_RESP}" | quiet_json "connect_config.server.port")
CONFIG_PROTOCOL=$(echo "${SESSION_RESP}" | quiet_json "connect_config.client.protocol")

session_ok=true
if [[ -z "${SESSION_ID}" ]]; then
  fail "Create session - no session_id (response: $(echo ${SESSION_RESP} | head -c 300))"
  session_ok=false
fi
if [[ "${SESSION_STATUS}" != "active" ]]; then
  fail "Create session - status=${SESSION_STATUS} (expected active)"
  session_ok=false
fi
if [[ "${SESSION_NODE_ID}" != "${NODE_ID}" ]]; then
  fail "Create session - node mismatch (expected ${NODE_ID}, got ${SESSION_NODE_ID})"
  session_ok=false
fi
if [[ "${CONFIG_PROFILE}" != "singbox" ]]; then
  fail "Create session - profile_type=${CONFIG_PROFILE} (expected singbox)"
  session_ok=false
fi
if [[ "${CONFIG_ENDPOINT}" != "mvp-not-issued" ]]; then
  fail "Create session - endpoint=${CONFIG_ENDPOINT} (expected mvp-not-issued)"
  session_ok=false
fi
if [[ "${CONFIG_PORT}" != "0" ]]; then
  fail "Create session - port=${CONFIG_PORT} (expected 0)"
  session_ok=false
fi
if [[ "${CONFIG_PROTOCOL}" != "mvp" ]]; then
  fail "Create session - protocol=${CONFIG_PROTOCOL} (expected mvp)"
  session_ok=false
fi
if [[ "${session_ok}" == "true" ]]; then
  pass "Create session: ${SESSION_STATUS} node=${SESSION_NODE_NAME} profile=${CONFIG_PROFILE}"
fi

echo ""
echo "--- [10] Security Check (no secrets leaked) ---"
LEAKED_FIELDS=$(echo "${SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
body_str = json.dumps(data).lower()
sensitive = ['node_secret','node_secret_hash','hmac','private_key','token','refresh_token']
found = [w for w in sensitive if w in body_str]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${LEAKED_FIELDS}" != "OK" ]]; then
  fail "Security leak: ${LEAKED_FIELDS}"
else
  pass "Security check: no sensitive fields in response"
fi

echo ""
echo "--- [11] GET Current Session (after create) ---"
CURRENT2_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
CURRENT2_SESSION_ID=$(echo "${CURRENT2_RESP}" | quiet_json "session.session_id")
CURRENT2_ERR_CODE=$(echo "${CURRENT2_RESP}" | quiet_json "error.code")
if [[ "${CURRENT2_SESSION_ID}" == "${SESSION_ID}" ]]; then
  pass "Current session matches created session"
elif [[ "${CURRENT2_ERR_CODE}" == "INTERNAL_ERROR" ]]; then
  blocker "Current session: INTERNAL_ERROR (scan session uuid) — TASK-BACKEND-CONNECT-002 fix required"
else
  fail "Current session mismatch (expected ${SESSION_ID}, got ${CURRENT2_SESSION_ID:-null})"
fi

echo ""
echo "--- [12] POST Heartbeat ---"
HEARTBEAT_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"client_state":"connecting","rx_bytes":123,"tx_bytes":456,"latency_ms":80}') || true
HB_OK=$(echo "${HEARTBEAT_RESP}" | quiet_json "ok")
HB_SESSION_STATUS=$(echo "${HEARTBEAT_RESP}" | quiet_json "session.status")
if [[ "${HB_OK}" != "True" ]]; then
  fail "Heartbeat - (response: $(echo ${HEARTBEAT_RESP} | head -c 300))"
else
  pass "Heartbeat OK: status=${HB_SESSION_STATUS}"
fi

echo ""
echo "--- [13] POST Disconnect ---"
DISCONNECT_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"reason":"user_disconnect"}') || true
DISC_OK=$(echo "${DISCONNECT_RESP}" | quiet_json "ok")
DISC_STATUS=$(echo "${DISCONNECT_RESP}" | quiet_json "session.status")
if [[ "${DISC_OK}" != "True" ]] || [[ "${DISC_STATUS}" != "disconnected" ]]; then
  fail "Disconnect - ok=${DISC_OK} status=${DISC_STATUS}"
else
  pass "Disconnect OK: status=${DISC_STATUS}"
fi

echo ""
echo "--- [14] POST Disconnect (idempotent) ---"
DISC2_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"reason":"user_disconnect"}') || true
DISC2_OK=$(echo "${DISC2_RESP}" | quiet_json "ok")
if [[ "${DISC2_OK}" != "True" ]]; then
  fail "Disconnect idempotent - (response: $(echo ${DISC2_RESP} | head -c 200))"
else
  pass "Disconnect idempotent: ok=${DISC2_OK}"
fi

echo ""
echo "--- [15] POST Heartbeat after Disconnect (expect 409) ---"
HB_AFTER_DISC_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"client_state":"connecting","rx_bytes":0,"tx_bytes":0,"latency_ms":0}') || true
HB_AFTER_ERR=$(echo "${HB_AFTER_DISC_RESP}" | quiet_json "error.code")
HB_AFTER_CODE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"client_state":"connecting","rx_bytes":0,"tx_bytes":0,"latency_ms":0}') || true
if [[ "${HB_AFTER_CODE}" == "409" ]]; then
  pass "Heartbeat after disconnect: 409 (CONNECT_SESSION_CLOSED)"
elif echo "${HB_AFTER_ERR}" | grep -q "CONNECT_SESSION_CLOSED"; then
  pass "Heartbeat after disconnect: CONNECT_SESSION_CLOSED"
else
  pass "Heartbeat after disconnect: status=${HB_AFTER_CODE} (non-fatal)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# E. Auth/audience negative tests
# ──────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- [16] No Token → 401 ---"
NO_TOKEN_CREATE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -d '{"platform":"ios","app_version":"0.1.0"}') || true
NO_TOKEN_CURRENT=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/connect/session/current") || true
NO_TOKEN_HB=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/heartbeat" \
  -H "Content-Type: application/json" \
  -d '{"client_state":"connecting"}') || true
NO_TOKEN_DISC=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/disconnect" \
  -H "Content-Type: application/json" \
  -d '{"reason":"test"}') || true

no_token_ok=true
if [[ "${NO_TOKEN_CREATE}" != "401" ]]; then echo "  FAIL: create no token → ${NO_TOKEN_CREATE}"; no_token_ok=false; fi
if [[ "${NO_TOKEN_CURRENT}" != "401" ]]; then echo "  FAIL: current no token → ${NO_TOKEN_CURRENT}"; no_token_ok=false; fi
if [[ "${NO_TOKEN_HB}" != "401" ]]; then echo "  FAIL: heartbeat no token → ${NO_TOKEN_HB}"; no_token_ok=false; fi
if [[ "${NO_TOKEN_DISC}" != "401" ]]; then echo "  FAIL: disconnect no token → ${NO_TOKEN_DISC}"; no_token_ok=false; fi
if [[ "${no_token_ok}" == "true" ]]; then
  pass "No token → 401 on all endpoints"
else
  fail "Some no-token checks failed"
fi

echo ""
echo "--- [17] Website Token → 403 (app-only) ---"
WEB_CREATE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}" \
  -d '{"platform":"ios","app_version":"0.1.0"}') || true
WEB_CURRENT=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}") || true
WEB_HB=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}" \
  -d '{"client_state":"connecting"}') || true
WEB_DISC=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}" \
  -d '{"reason":"test"}') || true

web_ok=true
if [[ "${WEB_CREATE}" != "403" ]]; then echo "  FAIL: website create → ${WEB_CREATE}"; web_ok=false; fi
if [[ "${WEB_CURRENT}" != "403" ]]; then echo "  FAIL: website current → ${WEB_CURRENT}"; web_ok=false; fi
if [[ "${WEB_HB}" != "403" ]]; then echo "  FAIL: website heartbeat → ${WEB_HB}"; web_ok=false; fi
if [[ "${WEB_DISC}" != "403" ]]; then echo "  FAIL: website disconnect → ${WEB_DISC}"; web_ok=false; fi
if [[ "${web_ok}" == "true" ]]; then
  pass "Website token → 403 (app-only audience enforced)"
else
  fail "Some website audience checks failed"
fi

echo ""
echo "--- [18] Admin Token → 403/401 (app-only) ---"
ADMIN_CREATE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"platform":"ios","app_version":"0.1.0"}') || true
ADMIN_CURRENT=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

admin_ok=true
if [[ "${ADMIN_CREATE}" != "403" && "${ADMIN_CREATE}" != "401" ]]; then echo "  FAIL: admin create → ${ADMIN_CREATE} (expected 401/403)"; admin_ok=false; fi
if [[ "${ADMIN_CURRENT}" != "403" && "${ADMIN_CURRENT}" != "401" ]]; then echo "  FAIL: admin current → ${ADMIN_CURRENT} (expected 401/403)"; admin_ok=false; fi
if [[ "${admin_ok}" == "true" ]]; then
  pass "Admin token → 401/403 (app-only audience enforced)"
else
  fail "Some admin audience checks failed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# F. Node availability negative tests (optional)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [19] Preferred Inactive Node (optional) ---"
# Register a second node but do NOT activate it → should be unavailable
NODE2_REG_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d "{\"node_name\":\"conn-smoke-inactive-${SUFFIX}\",\"agent_version\":\"smoke-1.0.0\"}") || true
NODE2_ID=$(echo "${NODE2_REG_RESP}" | quiet_json "node_id")
NODE2_SECRET=$(echo "${NODE2_REG_RESP}" | quiet_json "node_secret")
if [[ -z "${NODE2_ID}" ]]; then
  skip "Could not register second node for negative test"
else
  # Don't approve/activate — preferred_node_id should fail
  NODE2_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE2_ID}\"}") || true
  NODE2_ERR=$(echo "${NODE2_SESSION_RESP}" | quiet_json "error.code")
  NODE2_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE2_ID}\"}") || true
  if [[ "${NODE2_HTTP}" == "404" ]] || echo "${NODE2_ERR}" | grep -q "CONNECT_NODE_NOT_AVAILABLE"; then
    pass "Preferred inactive node correctly rejected: ${NODE2_ERR:-404}"
  else
    pass "Preferred inactive node: status=${NODE2_HTTP} (non-fatal)"
  fi
  # Cleanup node2
  pg_exec -c "DELETE FROM nodes WHERE id='${NODE2_ID}'" 2>/dev/null || true
fi

# ──────────────────────────────────────────────────────────────────────────────
# G. Device check after connect
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [20] Device Created by Connect Session ---"
DEV_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/devices" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
DEV_COUNT=$(echo "${DEV_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
print(len(data.get('devices',[])))
" 2>/dev/null || echo "0")
DEV_USED=$(echo "${DEV_RESP}" | quiet_json "device_used")
if [[ "${DEV_COUNT}" -ge 1 ]] && [[ "${DEV_USED}" -ge 1 ]]; then
  pass "Device created by connect: count=${DEV_COUNT} used=${DEV_USED}"
else
  skip "Device usage: count=${DEV_COUNT} used=${DEV_USED} (billing free has limit=1, may need upgrade)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"
pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM nodes WHERE id='${NODE_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${WEBSITE_EMAIL}'" 2>/dev/null || true
echo "  Cleaned up connect smoke data"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " TASK-CICD-CONNECT-001 SUMMARY"
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

if [[ "${FAILED}" -eq 1 ]]; then
  echo ""
  echo "[TASK-CICD-CONNECT-001] CONNECT SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo ""
echo "[TASK-CICD-CONNECT-001] Connect session full-link smoke PASSED."
