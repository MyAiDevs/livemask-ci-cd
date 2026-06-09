#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-VPN-PROTOCOL-MATRIX-SMOKE-001
# VPN protocol closed-loop matrix smoke (Backend connect_config + credential)
# ═══════════════════════════════════════════════════════════════════════════════
# Per profile: endpoint → session → client block → credential shape
# Matrix output: PROFILE | connect_config | credential | RESULT
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.local.yml}"
API_BASE="$(lm_backend_base_url)"
SUFFIX="vpn-mx-$(date +%s)"

FAILED=0
MATRIX_LINES=()

fail()    { local m="$1"; echo "  FAIL: ${m}"; FAILED=1; }
pass()    { local m="$1"; echo "  PASS: ${m}"; }
record_matrix() { MATRIX_LINES+=("$1"); }

quiet_json() {
  local path="${1:-}"
  python3 -c "
import sys,json
data=json.load(sys.stdin)
parts='${path}'.split('.')
current=data
for p in parts:
    if isinstance(current, dict):
        if p not in current: print(''); sys.exit(0)
        current=current[p]
    elif isinstance(current, list):
        try: current=current[int(p)]
        except: print(''); sys.exit(0)
    else: print(''); sys.exit(0)
print(current)
" 2>/dev/null || echo ""
}

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}

node_hmac() {
  local node_id="$1" node_secret="$2"
  local ts hash sig
  ts=$(date +%s)
  hash=$(echo -n "${node_secret}" | shasum -a 256 | awk '{print $1}')
  sig=$(NODE_ID="${node_id}" TS="${ts}" HASH="${hash}" python3 -c "
import hmac, hashlib, os
print(hmac.new(os.environ['HASH'].encode(), f\"{os.environ['NODE_ID']}:{os.environ['TS']}\".encode(), hashlib.sha256).hexdigest())
")
  echo "${ts} ${sig}"
}

echo "================================================"
echo " TASK-CICD-VPN-PROTOCOL-MATRIX-SMOKE-001"
echo " VPN protocol matrix smoke"
echo "================================================"
lm_runtime_status_report
echo ""

# Health + admin
for attempt in $(seq 1 30); do
  lm_backend_ready && break
  [[ "${attempt}" -eq 30 ]] && { echo "BLOCKER: backend not ready"; exit 1; }
  sleep 2
done

ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"vpn-mx","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
[[ -z "${ADMIN_TOKEN}" ]] && { echo "BLOCKER: admin login"; exit 1; }

# Dev-seed app user (has traffic entitlement when DEV_SEED_USERS=true)
USER_EMAIL="${DEV_USER_EMAIL:-user@livemask.dev}"
USER_PASS="${DEV_USER_PASSWORD:-UserPass123!}"
USER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"vpn-mx-login\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"client_type\":\"app\"}") || true
USER_TOKEN=$(echo "${USER_LOGIN}" | quiet_json "access_token")
APP_USER_ID=$(echo "${USER_LOGIN}" | quiet_json "user.user_id")
[[ -z "${USER_TOKEN}" ]] && { echo "BLOCKER: dev user login (${USER_EMAIL})"; exit 1; }

pg_exec -c "DELETE FROM user_devices WHERE user_id='${APP_USER_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${APP_USER_ID}'" 2>/dev/null || true

# Admin catalog parity via capabilities API
echo "--- [1] Admin/Backend protocol catalog parity ---"
CAPS=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/protocol/capabilities" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
CAP_COUNT=$(echo "${CAPS}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d.get('capabilities',d.get('items',[]))
print(len(items) if isinstance(items,list) else 0)
" 2>/dev/null || echo "0")
if [[ "${CAP_COUNT}" -ge 10 ]]; then
  pass "protocol capabilities API returns ${CAP_COUNT} entries"
  record_matrix "catalog_parity|PASS|PASS|PASS"
else
  fail "protocol capabilities count=${CAP_COUNT}"
  record_matrix "catalog_parity|FAIL|SKIP|FAIL"
fi

MATRIX_CASES=(
  'hysteria2|udp|connect_config.client.hysteria2|{"up_mbps":50,"down_mbps":100,"obfs_type":"salamander","port":8443,"auth":"mx-hy2-auth"}|hysteria2_auth|yes'
  'vless|tcp|connect_config.client.vless|{"vless_flow":"none","vless_uuid":"mx-vless-uuid"}|vless_uuid|yes'
  'vless_reality|tcp|connect_config.client.vless|{"vless_flow":"xtls-rprx-vision","vless_uuid":"mx-vr-uuid","reality_public_key":"pk","reality_short_id":"abcd"}|vless_uuid|yes'
  'trojan|tcp|connect_config.client.trojan|{"trojan_flow":"none","trojan_password":"mx-trojan-pass"}|trojan_password|yes'
  'shadowtls|tcp|connect_config.client.shadowtls|{"shadowtls_version":3,"shadowtls_password":"mx-stls-pass"}|shadowtls_password|yes'
  'wireguard|udp|connect_config.client.wireguard|{"wireguard_peer_pub_key":"peerpub","wireguard_allowed_ips":"0.0.0.0/0","wireguard_private_key":"mx-wg-key"}|wireguard_private_key|yes'
  'shadowsocks|tcp|connect_config.client.shadowsocks|{"shadowsocks_method":"2022-blake3-aes-256-gcm","shadowsocks_password":"mx-ss-pass"}|shadowsocks_password|yes'
  'tuic|udp|connect_config.client.tuic|{"tuic_congestion_control":1,"tuic_uuid":"mx-tuic-uuid","tuic_password":"mx-tuic-pass"}|tuic_auth|yes'
  'anytls|tcp|connect_config.client.anytls|{"anytls_padding":"x","anytls_password":"mx-any-pass"}|anytls_password|yes'
  'mixed|tcp|.|{}|.|no'
  'socks|tcp|.|{}|.|no'
  'tun|tcp|.|{}|.|no'
)

test_profile_case() {
  local profile="$1" transport="$2" client_path="$3" profile_cfg="$4" cred_type="$5" expect_client="$6"
  local node_name="vpn-mx-${profile}-${SUFFIX}"
  local conn_result="FAIL" cred_result="SKIP" overall="FAIL"

  local reg
  reg=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
    -H "Content-Type: application/json" \
    -d "{\"node_name\":\"${node_name}\",\"agent_version\":\"vpn-mx-1.0\"}") || true
  local node_id node_secret
  node_id=$(echo "${reg}" | quiet_json "node_id")
  node_secret=$(echo "${reg}" | quiet_json "node_secret")
  if [[ -z "${node_id}" ]]; then
    record_matrix "${profile}|FAIL|SKIP|FAIL"
    fail "${profile}: node register"
    return
  fi

  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${node_id}/approve" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" \
    -d '{"reason":"vpn matrix"}' >/dev/null 2>&1 || true
  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${node_id}/activate" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" \
    -d '{"reason":"vpn matrix"}' >/dev/null 2>&1 || true

  read -r ts sig < <(node_hmac "${node_id}" "${node_secret}")
  local port=443
  [[ "${transport}" == "udp" && "${profile}" == "hysteria2" ]] && port=8443
  curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/node-endpoint" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${node_id}" -H "X-Signature: ${sig}" -H "X-Timestamp: ${ts}" \
    -d "{\"public_endpoint_host\":\"mx.${profile}.livemask.io\",\"public_endpoint_port\":${port},\"transport\":\"${transport}\",\"sni\":\"mx.${profile}.livemask.io\",\"protocol_profile\":\"${profile}\",\"profile_config\":${profile_cfg},\"enabled\":true}" >/dev/null 2>&1 || true

  pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${APP_USER_ID}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM user_devices WHERE user_id='${APP_USER_ID}'" 2>/dev/null || true
  local sess_resp
  sess_resp=$(curl -sS --max-time 10 -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"android\",\"app_version\":\"9.0.0\",\"preferred_node_id\":\"${node_id}\"}") || true

  local err_code ptype is_skel sid
  err_code=$(echo "${sess_resp}" | quiet_json "error.code")
  ptype=$(echo "${sess_resp}" | quiet_json "connect_config.profile_type")
  is_skel=$(echo "${sess_resp}" | quiet_json "connect_config.is_skeleton")
  sid=$(echo "${sess_resp}" | quiet_json "session.session_id")

  if [[ "${err_code}" == "DEVICE_LIMIT_EXCEEDED" ]]; then
    record_matrix "${profile}|SKIP|SKIP|SKIP"
    pg_exec -c "DELETE FROM nodes WHERE id='${node_id}'" 2>/dev/null || true
    return
  fi

  if [[ "${ptype}" == "${profile}" && "${is_skel}" == "False" ]]; then
    conn_result="PASS"
    if [[ "${expect_client}" == "yes" && "${client_path}" != "." ]]; then
      local has_block
      has_block=$(echo "${sess_resp}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
path='${client_path}'.split('.')
cur=d
for p in path:
    if not isinstance(cur,dict) or p not in cur or cur[p] in (None,{}):
        print('no'); raise SystemExit(0)
    cur=cur[p]
print('yes')
" 2>/dev/null || echo "no")
      if [[ "${has_block}" != "yes" ]]; then conn_result="FAIL"; fi
    fi
  fi

  if [[ "${cred_type}" != "." && -n "${sid}" && "${conn_result}" == "PASS" ]]; then
    local cred_resp cred_kind
    cred_resp=$(curl -sS --max-time 10 "${API_BASE}/api/v1/connect/session/${sid}/credential" \
      -H "Authorization: Bearer ${USER_TOKEN}") || true
    cred_kind=$(echo "${cred_resp}" | quiet_json "credential_type")
    if [[ "${cred_kind}" == "${cred_type}" ]]; then
      cred_result="PASS"
    else
      cred_result="FAIL"
    fi
    curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${sid}/disconnect" \
      -H "Authorization: Bearer ${USER_TOKEN}" -H "Content-Type: application/json" \
      -d '{"reason":"matrix"}' >/dev/null 2>&1 || true
  elif [[ "${cred_type}" == "." ]]; then
    cred_result="N/A"
    if [[ -n "${sid}" ]]; then
      local cred_http
      cred_http=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        "${API_BASE}/api/v1/connect/session/${sid}/credential" \
        -H "Authorization: Bearer ${USER_TOKEN}") || true
      if [[ "${cred_http}" == "400" || "${cred_http}" == "404" || "${cred_http}" == "503" ]]; then
        cred_result="PASS"
      else
        cred_result="FAIL"
      fi
      curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${sid}/disconnect" \
        -H "Authorization: Bearer ${USER_TOKEN}" -H "Content-Type: application/json" \
        -d '{"reason":"matrix"}' >/dev/null 2>&1 || true
    fi
  fi

  if [[ "${conn_result}" == "PASS" && ( "${cred_result}" == "PASS" || "${cred_result}" == "N/A" ) ]]; then
    overall="PASS"
  elif [[ "${conn_result}" == "PASS" && "${cred_result}" == "FAIL" ]]; then
    overall="FAIL"
  else
    overall="FAIL"
  fi

  record_matrix "${profile}|${conn_result}|${cred_result}|${overall}"
  [[ "${overall}" == "PASS" ]] || fail "${profile}: connect=${conn_result} cred=${cred_result}"

  pg_exec -c "DELETE FROM connect_sessions WHERE node_id='${node_id}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM node_endpoints WHERE node_id='${node_id}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM nodes WHERE id='${node_id}'" 2>/dev/null || true
}

echo ""
echo "--- [2] Per-profile connect_config + credential matrix ---"
for matrix_line in "${MATRIX_CASES[@]}"; do
  IFS='|' read -r profile transport client_path profile_cfg cred_type expect_client <<< "${matrix_line}"
  echo "  >> ${profile}"
  test_profile_case "${profile}" "${transport}" "${client_path}" "${profile_cfg}" "${cred_type}" "${expect_client}" || true
done

echo ""
echo "================================================"
echo " PROTOCOL MATRIX SUMMARY"
echo "================================================"
printf '%s\n' "PROFILE | connect_config | credential | RESULT"
printf '%s\n' "${MATRIX_LINES[@]}"

PASS_COUNT=$(printf '%s\n' "${MATRIX_LINES[@]}" | grep -c '|PASS$' || true)
FAIL_COUNT=$(printf '%s\n' "${MATRIX_LINES[@]}" | grep -c '|FAIL$' || true)
SKIP_COUNT=$(printf '%s\n' "${MATRIX_LINES[@]}" | grep -c '|SKIP$' || true)
echo ""
echo "  PASS rows: ${PASS_COUNT}  FAIL rows: ${FAIL_COUNT}  SKIP rows: ${SKIP_COUNT}"

if [[ "${FAILED}" -eq 1 ]]; then
  echo "[TASK-CICD-VPN-PROTOCOL-MATRIX-SMOKE-001] VPN PROTOCOL MATRIX SMOKE FAILED."
  exit 1
fi
echo "[TASK-CICD-VPN-PROTOCOL-MATRIX-SMOKE-001] VPN protocol matrix smoke PASSED."
