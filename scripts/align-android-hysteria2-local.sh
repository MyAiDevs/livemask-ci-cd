#!/usr/bin/env bash
# align-android-hysteria2-local.sh — Align local stack for Android hysteria2 VPN proof.
#
# Brings Postgres endpoint, protocol template assignment, NodeAgent sing-box,
# and Backend connect_config into hysteria2/UDP agreement, then applies the
# assignment on NodeAgent.
#
# Usage:
#   bash scripts/align-android-hysteria2-local.sh
#   LAN_HOST=192.168.1.64 NODE_ID=<uuid> bash scripts/align-android-hysteria2-local.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${ROOT}/infra/docker-compose.local.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
NODEAGENT_PORT="${LIVEMASK_NODEAGENT_PORT:-19090}"
HY2_PORT="${SINGBOX_LISTEN_PORT:-8443}"
LAN_HOST="${LAN_HOST:-${SINGBOX_PUBLIC_ENDPOINT_HOST:-}}"
NODE_ID="${NODE_ID:-4877168a-8c89-436e-9209-e265faf41bd6}"
TEMPLATE_NAME="${TEMPLATE_NAME:-smoke-custom-vless-proto-1780042312}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-livemask-local-postgres-1}"
DEV_USER_EMAIL="${DEV_USER_EMAIL:-user@livemask.dev}"
DEV_USER_PASSWORD="${DEV_USER_PASSWORD:-UserPass123!}"
HY2_AUTH="${HYSTERIA2_AUTH:-local-dev-hy2-auth}"

API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
NODEAGENT_BASE="http://127.0.0.1:${NODEAGENT_PORT}"

if [[ -z "${LAN_HOST}" ]]; then
  LAN_HOST="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
if [[ -z "${LAN_HOST}" ]]; then
  echo "ERROR: set LAN_HOST to your Mac LAN IP (e.g. 192.168.1.64)" >&2
  exit 1
fi

# NodeAgent assignment profile_config allowlist rejects secret-like keys (e.g. auth).
# Backend connect_node_endpoints.profile_config keeps auth for session credential minting.
TEMPLATE_PROFILE_JSON='{"listen_host":"0.0.0.0","listen_port":'"${HY2_PORT}"',"up_mbps":50,"down_mbps":200}'
ENDPOINT_PROFILE_JSON='{"listen_host":"0.0.0.0","listen_port":'"${HY2_PORT}"',"up_mbps":50,"down_mbps":200,"auth":"'"${HY2_AUTH}"'"}'
CONFIG_HASH="$(python3 -c "import hashlib,json; p=json.dumps(json.loads('${TEMPLATE_PROFILE_JSON}'),separators=(',',':')).encode(); print(hashlib.sha256(p+b'[]').hexdigest())")"

echo "== Align Android hysteria2 local stack =="
echo "  LAN_HOST=${LAN_HOST}"
echo "  NODE_ID=${NODE_ID}"
echo "  HY2_PORT=${HY2_PORT} (UDP)"
echo "  TEMPLATE=${TEMPLATE_NAME}"
echo ""

pg() {
  docker exec "${POSTGRES_CONTAINER}" psql -U livemask -d livemask -v ON_ERROR_STOP=1 -c "$1"
}

echo "--- [1] Postgres connect_node_endpoints -> hysteria2/udp ---"
pg "UPDATE connect_node_endpoints SET
  public_endpoint_host = '${LAN_HOST}',
  public_endpoint_port = ${HY2_PORT},
  transport = 'udp',
  protocol_profile = 'hysteria2',
  profile_config = '${ENDPOINT_PROFILE_JSON}'::jsonb,
  enabled = true,
  updated_at = now()
WHERE node_id = '${NODE_ID}';"

echo "--- [2] Protocol template + assignment state -> hysteria2 ---"
TEMPLATE_ID="$(docker exec "${POSTGRES_CONTAINER}" psql -U livemask -d livemask -tAc \
  "SELECT template_id FROM protocol_templates WHERE name='${TEMPLATE_NAME}' LIMIT 1;")"
if [[ -z "${TEMPLATE_ID}" ]]; then
  echo "ERROR: template ${TEMPLATE_NAME} not found in protocol_templates" >&2
  exit 1
fi

pg "UPDATE protocol_templates SET protocol='hysteria2', transport='udp', latest_config_hash='${CONFIG_HASH}' WHERE template_id='${TEMPLATE_ID}';"
pg "UPDATE template_versions SET profile_config='${TEMPLATE_PROFILE_JSON}'::jsonb, config_hash='${CONFIG_HASH}'
  WHERE template_id='${TEMPLATE_ID}' AND version = (
    SELECT template_version FROM node_assignment_states WHERE node_id='${NODE_ID}' LIMIT 1
  );"
pg "UPDATE node_assignment_states SET
  target_config_hash='${CONFIG_HASH}',
  current_config_hash='',
  status='assigned',
  updated_at=now()
WHERE node_id='${NODE_ID}';"

echo "--- [3] Ensure NodeAgent container (UDP ${HY2_PORT}, TLS, HYSTERIA2_AUTH) ---"
export SINGBOX_PUBLIC_ENDPOINT_HOST="${LAN_HOST}"
export SINGBOX_PUBLIC_ENDPOINT_PORT="${HY2_PORT}"
export SINGBOX_LISTEN_PORT="${HY2_PORT}"
export HYSTERIA2_AUTH="${HY2_AUTH}"
docker compose -f "${COMPOSE_FILE}" --profile nodeagent up -d nodeagent

echo "--- [4] Wait for NodeAgent HTTP :${NODEAGENT_PORT} ---"
for i in $(seq 1 60); do
  if curl -sf --max-time 2 "${NODEAGENT_BASE}/healthz" >/dev/null 2>&1; then
    echo "  NodeAgent HTTP ready (${i}s)"
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: NodeAgent HTTP not ready after 60s" >&2
    docker logs livemask-local-nodeagent-1 2>&1 | tail -20 >&2 || true
    exit 1
  fi
  sleep 2
done

echo "--- [5] POST /protocol/apply ---"
APPLY_RESP="$(curl -sf --max-time 120 -X POST "${NODEAGENT_BASE}/protocol/apply" || true)"
if [[ -z "${APPLY_RESP}" ]]; then
  echo "WARN: protocol/apply returned empty (assignment may already be current; check status)"
else
  echo "${APPLY_RESP}" | python3 -m json.tool 2>/dev/null | head -20 || echo "${APPLY_RESP}"
fi

echo "--- [6] Verify NodeAgent sing-box hysteria2 ---"
curl -sf "${NODEAGENT_BASE}/agent/status" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('singbox', {})
ok = (
    d.get('singbox_status') == 'running'
    and s.get('protocol_profile') == 'hysteria2'
    and s.get('listen_port') == ${HY2_PORT}
)
print(f\"  singbox_status={d.get('singbox_status')} profile={s.get('protocol_profile')} port={s.get('listen_port')} endpoint_ready={s.get('endpoint_ready')}\")
if not ok:
    raise SystemExit('NodeAgent sing-box not in expected hysteria2 running state')
print('  PASS: NodeAgent hysteria2 inbound running')
"

echo "--- [7] Verify Backend connect_config profile_type=hysteria2 ---"
USER_ID="$(docker exec "${POSTGRES_CONTAINER}" psql -U livemask -d livemask -tAc \
  "SELECT id FROM users WHERE email='${DEV_USER_EMAIL}' LIMIT 1;" | tr -d '[:space:]')"
if [[ -n "${USER_ID}" ]]; then
  # Clear active sessions only; keep user_devices so phones with cached device_id still connect.
  pg "DELETE FROM connect_sessions WHERE user_id='${USER_ID}';" >/dev/null 2>&1 || true
fi
TOKEN="$(curl -sf -X POST "${API_BASE}/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"request_id\":\"align-hy2-login\",\"email\":\"${DEV_USER_EMAIL}\",\"password\":\"${DEV_USER_PASSWORD}\",\"client_type\":\"app\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")"
if [[ -z "${TOKEN}" ]]; then
  echo "WARN: could not login as ${DEV_USER_EMAIL}; skip connect_config check"
else
  SESSION_RESP="$(curl -sf -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"request_id\":\"align-hy2-session\",\"platform\":\"android\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE_ID}\"}" || true)"
  PROFILE="$(echo "${SESSION_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connect_config',{}).get('profile_type',''))" 2>/dev/null || true)"
  ENDPOINT="$(echo "${SESSION_RESP}" | python3 -c "import sys,json; c=json.load(sys.stdin).get('connect_config',{}); print(c.get('server',{}).get('endpoint',''))" 2>/dev/null || true)"
  PORT="$(echo "${SESSION_RESP}" | python3 -c "import sys,json; c=json.load(sys.stdin).get('connect_config',{}); print(c.get('server',{}).get('port',''))" 2>/dev/null || true)"
  TRANSPORT="$(echo "${SESSION_RESP}" | python3 -c "import sys,json; c=json.load(sys.stdin).get('connect_config',{}); print(c.get('server',{}).get('transport',''))" 2>/dev/null || true)"
  echo "  connect_config profile_type=${PROFILE} endpoint=${ENDPOINT}:${PORT} transport=${TRANSPORT}"
  if [[ "${PROFILE}" != "hysteria2" ]]; then
    echo "ERROR: expected profile_type=hysteria2, got ${PROFILE}" >&2
    exit 1
  fi
  echo "  PASS: Backend issues hysteria2 connect_config"
fi

echo ""
echo "== Done. Android APK rebuild/install =="
echo "  cd livemask-app"
echo "  flutter run -d <device-id> --dart-define=API_BASE_URL=http://${LAN_HOST}:${BACKEND_HTTP_PORT}"
echo ""
echo "After connect, expect UI 'connected' (not shell ready) and NodeAgent logs:"
echo "  docker logs livemask-local-nodeagent-1 2>&1 | grep -E 'sessionauth|traffic.*client'"
