#!/usr/bin/env bash
# Admin user detail smoke — payout_methods + contact_channels on GET /admin/api/v1/users/{id}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.local.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
TIMESTAMP="${TIMESTAMP:-$(date +%s)}"
SMOKE_USER_ID="678bebc4-3466-49e0-81bb-8433bd6aef6d"

FAILED=0
PASSED=0

fail() { echo "  FAIL: $1"; FAILED=1; }
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }

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

echo "=== Admin User Detail Smoke ==="

ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by admin-user-detail-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi

ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"admin-user-detail-smoke-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  fail "Admin login — no access token"
  echo "${PASSED}P ${FAILED}F"
  exit 1
fi
pass "Admin login OK"

pg_exec -c "INSERT INTO users (id, email, password_hash, display_name, usdt_address_1_protocol, usdt_address_1)
  VALUES ('${SMOKE_USER_ID}', 'smoke-user-detail-${TIMESTAMP}@test.livemask', 'x', 'Smoke User Detail', 'trc20', 'TXYZ1234567890ABCDEFGHIJK')
  ON CONFLICT (id) DO UPDATE SET usdt_address_1_protocol='trc20', usdt_address_1='TXYZ1234567890ABCDEFGHIJK'" 2>/dev/null

pg_exec -c "DELETE FROM user_contact_channels WHERE user_id='${SMOKE_USER_ID}'" 2>/dev/null
pg_exec -c "INSERT INTO user_contact_channels (user_id, channel_type, channel_identifier, display_label, status, source, verified_at)
  VALUES ('${SMOKE_USER_ID}', 'telegram', '123456789', '@smoke_masked', 'verified', 'admin_added', NOW())" 2>/dev/null

DETAIL=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/users/${SMOKE_USER_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

HTTP_CODE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/admin/api/v1/users/${SMOKE_USER_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
if [[ "${HTTP_CODE}" == "200" ]]; then
  pass "GET /admin/api/v1/users/{id} → 200"
else
  fail "GET /admin/api/v1/users/{id} → ${HTTP_CODE}"
fi

HAS_PAYOUT=$(echo "${DETAIL}" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print('yes' if 'payout_methods' in u else 'no')" 2>/dev/null || echo "no")
if [[ "${HAS_PAYOUT}" == "yes" ]]; then
  pass "user.payout_methods present"
else
  fail "user.payout_methods missing"
fi

HAS_CONTACT=$(echo "${DETAIL}" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print('yes' if 'contact_channels' in u else 'no')" 2>/dev/null || echo "no")
if [[ "${HAS_CONTACT}" == "yes" ]]; then
  pass "user.contact_channels present"
else
  fail "user.contact_channels missing"
fi

PAYOUT_MASKED=$(echo "${DETAIL}" | quiet_json "user.payout_methods.0.account_masked")
if [[ -n "${PAYOUT_MASKED}" && "${PAYOUT_MASKED}" != *"TXYZ1234567890ABCDEFGHIJK"* ]]; then
  pass "payout address masked (${PAYOUT_MASKED})"
else
  fail "payout address not masked"
fi

LEAKED=$(echo "${DETAIL}" | python3 -c "
import sys,json
raw=sys.stdin.read()
if 'channel_identifier' in raw:
    print('yes')
    sys.exit(0)
data=json.loads(raw)
u=data.get('user',{})
for ch in u.get('contact_channels',[]) or []:
    if 'channel_identifier' in ch:
        print('yes'); sys.exit(0)
for pm in u.get('payout_methods',[]) or []:
    if pm.get('address'):
        print('yes'); sys.exit(0)
print('no')
" 2>/dev/null || echo "yes")
if [[ "${LEAKED}" == "no" ]]; then
  pass "no raw payout/contact secrets in response"
else
  fail "response leaked raw payout/contact fields"
fi

CONTACT_COUNT=$(echo "${DETAIL}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('user',{}).get('contact_channels',[]) or []))" 2>/dev/null || echo "0")
if [[ "${CONTACT_COUNT}" -ge 1 ]]; then
  pass "contact_channels has ${CONTACT_COUNT} item(s)"
else
  fail "expected at least one contact channel"
fi

echo ""
echo "Summary: ${PASSED}P ${FAILED}F"
[[ "${FAILED}" -eq 0 ]]
