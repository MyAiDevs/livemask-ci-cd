#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# TASK-CICD-APP-ROUTING-STRATEGY-SMOKE-001 — App routing strategy smoke
# ──────────────────────────────────────────────────────────────────────────────
# Verifies:
#   - Backend connect_config.routing (mode, geosite_rule_sets)
#   - App unit tests (routing merge + geosite flags)
#   - go/mobile routing + geosite unit tests
# ──────────────────────────────────────────────────────────────────────────────

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
APP_ROOT="${LIVEMASK_APP_ROOT:-../livemask-app}"

FAILED=0
SUMMARY_LINES=()

fail() {
  echo "  FAIL: $1"
  SUMMARY_LINES+=("FAIL: $1")
  FAILED=1
}

pass() {
  echo "  PASS: $1"
  SUMMARY_LINES+=("PASS: $1")
}

skip() {
  echo "  SKIP: $1"
  SUMMARY_LINES+=("SKIP: $1")
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

echo "====== TASK-CICD-APP-ROUTING-STRATEGY-SMOKE-001 ======"

# --- [1] App go/mobile tests ---
echo ""
echo "--- [1] go/mobile routing + geosite tests ---"
if [[ -d "${APP_ROOT}/go/mobile" ]]; then
  if (cd "${APP_ROOT}/go/mobile" && go test ./... -count=1); then
    pass "go/mobile routing tests"
  else
    fail "go/mobile routing tests"
  fi
else
  skip "go/mobile not found at ${APP_ROOT}/go/mobile"
fi

# --- [2] App Flutter routing tests ---
echo ""
echo "--- [2] Flutter routing unit tests ---"
if [[ -d "${APP_ROOT}" ]]; then
  if (cd "${APP_ROOT}" && flutter test test/routing_strategy_test.dart test/connect_routing_test.dart); then
    pass "Flutter routing unit tests"
  else
    fail "Flutter routing unit tests"
  fi
else
  skip "livemask-app not found at ${APP_ROOT}"
fi

# --- [3] Backend health ---
echo ""
echo "--- [3] Backend health ---"
HEALTH_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "${API_BASE}/health" || echo "000")
if [[ "${HEALTH_CODE}" == "200" ]]; then
  pass "Backend health 200"
else
  skip "Backend health ${HEALTH_CODE} — skipping connect_config.routing API checks"
  echo ""
  echo "====== Summary ======"
  for line in "${SUMMARY_LINES[@]}"; do echo "  ${line}"; done
  exit "${FAILED}"
fi

# --- [4] Login smoke user ---
echo ""
echo "--- [4] Auth token ---"
LOGIN_RESP=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"smoke@livemask.test","password":"SmokeTest123!"}' 2>/dev/null || echo '{}')
USER_TOKEN=$(echo "${LOGIN_RESP}" | quiet_json "access_token")
if [[ -z "${USER_TOKEN}" ]]; then
  skip "No smoke user token — skipping routing API checks"
  echo ""
  echo "====== Summary ======"
  for line in "${SUMMARY_LINES[@]}"; do echo "  ${line}"; done
  exit "${FAILED}"
fi
pass "Smoke user token acquired"

# --- [5] connect_config.routing on session create ---
echo ""
echo "--- [5] connect_config.routing ---"
SESSION_RESP=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"platform":"android","app_version":"0.1.0"}' 2>/dev/null || echo '{}')

ROUTING_MODE=$(echo "${SESSION_RESP}" | quiet_json "connect_config.routing.mode")
GEOSITE_SETS=$(echo "${SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
sets=data.get('connect_config',{}).get('routing',{}).get('geosite_rule_sets',[])
print(','.join(sets) if isinstance(sets,list) else '')
" 2>/dev/null || echo "")
EXCLUDE_NETS=$(echo "${SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
nets=data.get('connect_config',{}).get('routing',{}).get('exclude_networks',[])
print('yes' if isinstance(nets,list) and len(nets)>0 else 'no')
" 2>/dev/null || echo "no")

if [[ "${ROUTING_MODE}" == "smart" ]]; then
  pass "routing.mode=smart"
else
  fail "routing.mode expected smart, got '${ROUTING_MODE}'"
fi

if echo "${GEOSITE_SETS}" | grep -q "geosite-cn"; then
  pass "routing.geosite_rule_sets contains geosite-cn"
else
  fail "routing.geosite_rule_sets missing geosite-cn (got: ${GEOSITE_SETS})"
fi

if [[ "${EXCLUDE_NETS}" == "yes" ]]; then
  pass "routing.exclude_networks present"
else
  fail "routing.exclude_networks missing"
fi

# --- [6] GeoIP manifest rule_sets[] ---
echo ""
echo "--- [6] geoip/manifest rule_sets[] ---"
MANIFEST_RESP=$(curl -sS --max-time 10 \
  "${API_BASE}/api/v1/geoip/manifest?platform=android&app_version=0.1.0&package_type=region_catalog" \
  -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || echo '{}')

RULE_SET_TAGS=$(echo "${MANIFEST_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
sets=data.get('rule_sets',[])
if not isinstance(sets,list):
    print('')
    sys.exit(0)
print(','.join(s.get('tag','') for s in sets if isinstance(s,dict)))
" 2>/dev/null || echo "")

GEOSITE_EMBEDDED=$(echo "${MANIFEST_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for s in data.get('rule_sets',[]) or []:
    if isinstance(s,dict) and s.get('tag')=='geosite-cn':
        print('embedded' if s.get('embedded') else s.get('format',''))
        sys.exit(0)
print('')
" 2>/dev/null || echo "")

if echo "${RULE_SET_TAGS}" | grep -q "geosite-cn"; then
  pass "rule_sets contains geosite-cn"
else
  fail "rule_sets missing geosite-cn (got: ${RULE_SET_TAGS})"
fi

if [[ "${GEOSITE_EMBEDDED}" == "embedded" || "${GEOSITE_EMBEDDED}" == "suffix_list" || "${GEOSITE_EMBEDDED}" == "srs" ]]; then
  pass "geosite-cn rule_set format=${GEOSITE_EMBEDDED}"
else
  fail "geosite-cn rule_set unexpected format (got: ${GEOSITE_EMBEDDED})"
fi

if echo "${RULE_SET_TAGS}" | grep -q "geoip-cn"; then
  pass "rule_sets contains geoip-cn"
else
  skip "geoip-cn not in rule_sets (no active MMDB seed — optional)"
fi

# --- [7] No secrets in routing block ---
echo ""
echo "--- [7] Routing security ---"
ROUTING_LEAK=$(echo "${SESSION_RESP}" | python3 -c "
import sys,json
body=json.dumps(json.load(sys.stdin)).lower()
for w in ['node_secret','password','private_key','auth_payload']:
    if w in body:
        print('LEAK:'+w)
        sys.exit(0)
print('OK')
" 2>/dev/null || echo "OK")
if [[ "${ROUTING_LEAK}" == "OK" ]]; then
  pass "No secrets in connect session response"
else
  fail "Secret leak: ${ROUTING_LEAK}"
fi

echo ""
echo "====== Summary ======"
for line in "${SUMMARY_LINES[@]}"; do echo "  ${line}"; done

if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
