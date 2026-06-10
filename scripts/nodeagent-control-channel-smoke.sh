#!/usr/bin/env bash
# TASK-BACKEND-NODEAGENT-CONTROL-CHANNEL-001
# Verifies the Backend <-> NodeAgent reverse control-channel contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKEND_ROOT="${LIVEMASK_BACKEND_ROOT:-${ROOT}/livemask-backend}"
NODEAGENT_ROOT="${LIVEMASK_NODEAGENT_ROOT:-${ROOT}/livemask-nodeagent}"
ADMIN_ROOT="${LIVEMASK_ADMIN_ROOT:-${ROOT}/livemask-admin}"
API_BASE="${API_BASE_URL:-http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}}"

PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=1
}

check_file_pattern() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [[ -f "${file}" ]] && grep -q "${pattern}" "${file}"; then
    pass "${label}"
  else
    fail "${label}"
  fi
}

quiet_json() {
  local path="${1:-}"
  python3 -c "
import sys,json
try:
    data=json.load(sys.stdin)
except Exception:
    print('')
    sys.exit(0)
cur=data
for part in '${path}'.split('.'):
    if not part:
        continue
    if isinstance(cur, dict):
        cur=cur.get(part, '')
    elif isinstance(cur, list):
        try:
            cur=cur[int(part)]
        except Exception:
            cur=''
    else:
        cur=''
print(cur if cur is not None else '')
" 2>/dev/null || echo ""
}

echo "================================================"
echo " TASK-BACKEND-NODEAGENT-CONTROL-CHANNEL-001"
echo " NodeAgent reverse control-channel smoke"
echo "================================================"

echo "--- [1] Backend contract static gates ---"
check_file_pattern "Backend SSE stream route registered" \
  "${BACKEND_ROOT}/main.go" \
  "/internal/agent/control/stream"
check_file_pattern "Backend result route registered" \
  "${BACKEND_ROOT}/main.go" \
  "/internal/agent/control/results"
check_file_pattern "Backend admin command route registered" \
  "${BACKEND_ROOT}/main.go" \
  "/admin/api/v1/node-control/commands"
check_file_pattern "Backend admin session route registered" \
  "${BACKEND_ROOT}/main.go" \
  "/admin/api/v1/node-control/sessions/"
check_file_pattern "Backend command list implemented" \
  "${BACKEND_ROOT}/internal/nodecontrol/store.go" \
  "ListCommands"
check_file_pattern "Backend audit event written" \
  "${BACKEND_ROOT}/internal/nodecontrol/store.go" \
  "node_control.command_result"
check_file_pattern "Backend command allowlist includes speedtest" \
  "${BACKEND_ROOT}/internal/nodecontrol/types.go" \
  "speedtest_run"

echo "--- [2] NodeAgent outbound client static gates ---"
check_file_pattern "NodeAgent outbound stream client" \
  "${NODEAGENT_ROOT}/internal/controlchannel/client.go" \
  "text/event-stream"
check_file_pattern "NodeAgent signed result POST" \
  "${NODEAGENT_ROOT}/internal/controlchannel/client.go" \
  "/internal/agent/control/results"
check_file_pattern "NodeAgent config status adapter" \
  "${NODEAGENT_ROOT}/cmd/nodeagent/main.go" \
  "CommandConfigStatus"
check_file_pattern "NodeAgent GeoIP status adapter" \
  "${NODEAGENT_ROOT}/cmd/nodeagent/main.go" \
  "CommandGeoIPStatus"
check_file_pattern "NodeAgent speedtest adapter" \
  "${NODEAGENT_ROOT}/cmd/nodeagent/main.go" \
  "CommandSpeedtestRun"
if grep -R "exec.Command\\|/bin/sh\\|bash -c" "${NODEAGENT_ROOT}/internal/controlchannel" >/dev/null 2>&1; then
  fail "NodeAgent control channel must not shell out"
else
  pass "NodeAgent control channel does not shell out"
fi

echo "--- [3] Admin UI static gates ---"
check_file_pattern "Admin node control API client" \
  "${ADMIN_ROOT}/src/lib/node-control-api.ts" \
  "/node-control/commands"
check_file_pattern "Admin node detail renders control panel" \
  "${ADMIN_ROOT}/src/app/admin/nodes/[id]/page.tsx" \
  "NodeControlChannelCard"
check_file_pattern "Admin i18n contains control channel label" \
  "${ADMIN_ROOT}/src/lib/i18n/locales/zh-CN.json" \
  "控制通道"

echo "--- [4] Optional Backend runtime route gate ---"
health_resp=$(curl -sS --max-time 3 "${API_BASE}/api/v1/health" 2>/dev/null || true)
health_status=$(echo "${health_resp}" | quiet_json "status")
if [[ "${health_status}" != "ok" ]]; then
  echo "  SKIP: Backend runtime not available at ${API_BASE}"
else
  pass "Backend health ok"
  login_resp=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"request_id":"nodeagent-control-smoke-admin","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}' 2>/dev/null || true)
  token=$(echo "${login_resp}" | quiet_json "access_token")
  if [[ -z "${token}" ]]; then
    echo "  SKIP: admin token unavailable; static gates already covered"
  else
    list_resp=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/node-control/commands?page=1&page_size=1" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || true)
    page=$(echo "${list_resp}" | quiet_json "page")
    if [[ "${page}" == "1" ]]; then
      pass "Backend admin command list route responds"
    else
      fail "Backend admin command list route did not return page=1"
    fi
  fi
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "[TASK-BACKEND-NODEAGENT-CONTROL-CHANNEL-001] FAILED"
  exit 1
fi

echo "[TASK-BACKEND-NODEAGENT-CONTROL-CHANNEL-001] PASSED (${PASS} checks)"
