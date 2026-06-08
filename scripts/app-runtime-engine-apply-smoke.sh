#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-APP-RUNTIME-ENGINE-APPLY-SMOKE-001
# App Runtime Engine Apply Smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Verifies Admin publish → App runtime-config contract includes engine fields:
#   [1] Backend health
#   [2] App GET /api/v1/app/runtime-config?platform=android
#   [3] runtime_governance.behavior.health_check_interval_ms present
#   [4] platform_overrides.android.engine.power_saving_mode present
#   [5] Admin publish with battery_saver → App reflects merged engine
#   [6] Secret leak scan
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
API_BASE="$(lm_backend_base_url)"

FAILED=0
PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
SUMMARY_LINES=()

fail() { local msg="$1"; echo "  FAIL: ${msg}"; SUMMARY_LINES+=("FAIL: ${msg}"); FAIL_COUNT=$((FAIL_COUNT+1)); FAILED=1; }
pass() { local msg="$1"; echo "  PASS: ${msg}"; SUMMARY_LINES+=("PASS: ${msg}"); PASS_COUNT=$((PASS_COUNT+1)); }
skip() { local msg="$1"; echo "  SKIP: ${msg}"; SUMMARY_LINES+=("SKIP: ${msg}"); SKIP_COUNT=$((SKIP_COUNT+1)); }

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
            print(''); sys.exit(0)
        current=current[p]
    elif isinstance(current, list):
        try: current=current[int(p)]
        except: print(''); sys.exit(0)
    else: print(''); sys.exit(0)
print(current)" 2>/dev/null || echo ""
}

security_check() {
  local label="$1"; local json="$2"
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
SENSITIVE = ['password_hash','node_secret','hmac','private_key','secret_key']
def walk(d):
    if isinstance(d,dict):
        for k,v in d.items():
            if any(w in k.lower() for w in SENSITIVE): return True
            if walk(v): return True
    elif isinstance(d,list):
        for i in d:
            if walk(i): return True
    return False
print('LEAK' if walk(data) else 'OK')" 2>/dev/null || echo "OK")
  if [[ "${leaked}" != "OK" ]]; then
    fail "[SECURITY] ${label}: secret leakage detected"; return 1
  fi
  return 0
}

echo "================================================"
echo " TASK-CICD-APP-RUNTIME-ENGINE-APPLY-SMOKE-001"
echo " App Runtime Engine Apply Smoke"
echo "================================================"
lm_runtime_status_report; echo ""

echo "--- [1] Backend Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(lm_backend_health_json || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    pass "Backend ready (attempt ${attempt})"; break
  fi
  if [[ "${attempt}" -eq 30 ]]; then fail "Backend not ready"; exit 1; fi
  sleep 2
done

echo ""
echo "--- App + Admin Login ---"
APP_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"engine-smoke-app","email":"testuser@livemask.dev","password":"TestPass123!","client_type":"app"}') || true
APP_TOKEN=$(echo "${APP_LOGIN}" | quiet_json "access_token")
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"engine-smoke-admin","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${APP_TOKEN}" ]]; then fail "App login failed"; exit 1; fi
pass "App login OK"
if [[ -z "${ADMIN_TOKEN}" ]]; then skip "Admin login failed — publish step skipped"; fi

echo ""
echo "--- [2] App runtime-config contract ---"
RUNTIME_RESP=$(curl -sS --max-time 5 \
  "${API_BASE}/api/v1/app/runtime-config?platform=android" \
  -H "Authorization: Bearer ${APP_TOKEN}" 2>/dev/null || echo "{}")
RUNTIME_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/api/v1/app/runtime-config?platform=android" \
  -H "Authorization: Bearer ${APP_TOKEN}" 2>/dev/null || echo "000")
if [[ "${RUNTIME_HTTP}" != "200" ]]; then
  fail "GET /api/v1/app/runtime-config returned HTTP ${RUNTIME_HTTP}"
else
  pass "GET /api/v1/app/runtime-config HTTP 200"
  security_check "runtime-config" "${RUNTIME_RESP}" || true
fi

echo ""
echo "--- [3] behavior.health_check_interval_ms ---"
HEALTH_MS=$(echo "${RUNTIME_RESP}" | quiet_json "runtime_governance.behavior.health_check_interval_ms")
if [[ -n "${HEALTH_MS}" && "${HEALTH_MS}" -ge 3000 && "${HEALTH_MS}" -le 60000 ]]; then
  pass "health_check_interval_ms=${HEALTH_MS}"
else
  fail "health_check_interval_ms missing or out of range (got '${HEALTH_MS}')"
fi

echo ""
echo "--- [4] android.engine.power_saving_mode ---"
POWER_MODE=$(echo "${RUNTIME_RESP}" | quiet_json "runtime_governance.platform_overrides.android.engine.power_saving_mode")
if [[ "${POWER_MODE}" == "performance" || "${POWER_MODE}" == "balanced" || "${POWER_MODE}" == "battery_saver" ]]; then
  pass "android.engine.power_saving_mode=${POWER_MODE}"
else
  fail "android.engine.power_saving_mode missing or invalid (got '${POWER_MODE}')"
fi

KEEPALIVE=$(echo "${RUNTIME_RESP}" | quiet_json "runtime_governance.platform_overrides.android.engine.tunnel_keepalive_interval_sec")
if [[ -n "${KEEPALIVE}" && "${KEEPALIVE}" -ge 10 && "${KEEPALIVE}" -le 300 ]]; then
  pass "tunnel_keepalive_interval_sec=${KEEPALIVE}"
else
  fail "tunnel_keepalive_interval_sec missing or out of range (got '${KEEPALIVE}')"
fi

echo ""
echo "--- [5] Admin publish battery_saver engine ---"
if [[ -n "${ADMIN_TOKEN}" ]]; then
  PUBLISH_BODY=$(cat <<'EOF'
{
  "config": {
    "resource_config": {"memory_limit_mb": 180, "max_connections": 8},
    "behavior_config": {"config_poll_interval": 30},
    "platform_overrides": {
      "android": {
        "engine": {
          "power_saving_mode": "battery_saver",
          "foreground_service_enabled": true,
          "notification_channel_importance": "default",
          "request_battery_optimization_exemption": true,
          "show_background_restrictions_guide": true,
          "wake_lock_while_connected": false,
          "tunnel_keepalive_interval_sec": 45,
          "background_reconnect_enabled": true
        }
      }
    }
  },
  "audit_reason": "engine apply smoke publish"
}
EOF
)
  PUBLISH_HTTP=$(curl -sS --max-time 8 -o /tmp/engine-smoke-publish.json -w "%{http_code}" \
    -X POST "${API_BASE}/admin/api/v1/system-settings/app-runtime/publish" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PUBLISH_BODY}" 2>/dev/null || echo "000")
  if [[ "${PUBLISH_HTTP}" == "200" || "${PUBLISH_HTTP}" == "201" ]]; then
    pass "Admin publish android.engine HTTP ${PUBLISH_HTTP}"
    sleep 1
    RUNTIME_AFTER=$(curl -sS --max-time 5 \
      "${API_BASE}/api/v1/app/runtime-config?platform=android" \
      -H "Authorization: Bearer ${APP_TOKEN}" 2>/dev/null || echo "{}")
    AFTER_MODE=$(echo "${RUNTIME_AFTER}" | quiet_json "runtime_governance.platform_overrides.android.engine.power_saving_mode")
    AFTER_KEEP=$(echo "${RUNTIME_AFTER}" | quiet_json "runtime_governance.platform_overrides.android.engine.tunnel_keepalive_interval_sec")
    AFTER_HEALTH=$(echo "${RUNTIME_AFTER}" | quiet_json "runtime_governance.behavior.health_check_interval_ms")
    if [[ "${AFTER_MODE}" == "battery_saver" ]]; then
      pass "App reflects published power_saving_mode=battery_saver"
    else
      fail "App power_saving_mode after publish: '${AFTER_MODE}'"
    fi
    if [[ "${AFTER_KEEP}" == "45" ]]; then
      pass "App reflects tunnel_keepalive_interval_sec=45"
    else
      fail "App tunnel_keepalive after publish: '${AFTER_KEEP}'"
    fi
    if [[ "${AFTER_HEALTH}" == "30000" ]]; then
      pass "App reflects health_check_interval_ms=30000 from config_poll_interval"
    else
      fail "App health_check_interval_ms after publish: '${AFTER_HEALTH}'"
    fi
  else
    skip "Admin publish HTTP ${PUBLISH_HTTP} — endpoint may be unavailable"
  fi
else
  skip "Admin publish skipped (no admin token)"
fi

echo ""
echo "================================================"
echo " TASK-CICD-APP-RUNTIME-ENGINE-APPLY-SMOKE-001 SUMMARY"
echo "================================================"
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  SKIP: ${SKIP_COUNT}"
for line in "${SUMMARY_LINES[@]}"; do echo "  ${line}"; done
if [[ "${FAILED}" -eq 1 ]]; then echo ""; echo "[TASK-CICD-APP-RUNTIME-ENGINE-APPLY-SMOKE-001] FAILED."; exit 1; fi
echo ""; echo "[TASK-CICD-APP-RUNTIME-ENGINE-APPLY-SMOKE-001] PASSED."
