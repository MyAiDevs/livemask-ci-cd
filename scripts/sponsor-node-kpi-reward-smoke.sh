#!/usr/bin/env bash
# TASK-SPONSOR-NODEAGENT-QUICK-INSTALL-KPI-SMOKE-CLOSURE-001
# Local smoke: sponsor node KPI freeze -> reward materialize -> growth points ledger.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/../infra/docker-compose.local.yml}"
if [[ "${COMPOSE_FILE}" != /* ]]; then
  COMPOSE_FILE="${SCRIPT_DIR}/../${COMPOSE_FILE}"
fi
COMPOSE_FILE="$(cd "$(dirname "${COMPOSE_FILE}")" && pwd)/$(basename "${COMPOSE_FILE}")"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
INTERNAL_SECRET="${INTERNAL_JOB_SECRET:-${INTERNAL_SERVICE_SECRET:-local-dev-secret}}"
export JWT_SECRET="${JWT_SECRET:-local-dev-sponsor-node-kpi-smoke-jwt-secret-20260624}"

SMOKE_SPONSOR_ID="00000000-0000-0000-0000-00000000f201"
SMOKE_NODE_ID="00000000-0000-0000-0000-00000000f301"
SMOKE_EMAIL="sponsor-node-kpi-smoke@test.livemask"
SMOKE_CONFIG_BY="sponsor-node-kpi-reward-smoke"
PERIOD_START="${SPONSOR_KPI_PERIOD_START:-2026-06-24T00:00:00Z}"
PERIOD_END="${SPONSOR_KPI_PERIOD_END:-2026-06-24T01:00:00Z}"

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
        try:
            cur=cur[int(p)]
        except Exception:
            cur=''
    else:
        cur=''
print(cur if cur is not None else '')
" 2>/dev/null || echo ""
}

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -q -U livemask -tA "$@"
}

cleanup_smoke_rows() {
  pg_exec -c "DELETE FROM growth_points_ledger WHERE source_event_id IN (SELECT 'sponsor_node_kpi:' || id::text FROM sponsor_node_kpi_windows WHERE node_id='${SMOKE_NODE_ID}' OR sponsor_user_id='${SMOKE_SPONSOR_ID}')" >/dev/null || true
  pg_exec -c "DELETE FROM growth_earnings_ledger WHERE source_event_id IN (SELECT 'sponsor_node_kpi:' || id::text FROM sponsor_node_kpi_windows WHERE node_id='${SMOKE_NODE_ID}' OR sponsor_user_id='${SMOKE_SPONSOR_ID}')" >/dev/null || true
  pg_exec -c "DELETE FROM sponsor_node_kpi_windows WHERE node_id='${SMOKE_NODE_ID}' OR sponsor_user_id='${SMOKE_SPONSOR_ID}'" >/dev/null || true
  pg_exec -c "DELETE FROM node_bandwidth_capacity WHERE node_id='${SMOKE_NODE_ID}'" >/dev/null || true
  pg_exec -c "DELETE FROM node_speedtest_reports WHERE node_id='${SMOKE_NODE_ID}'" >/dev/null || true
  pg_exec -c "DELETE FROM node_heartbeats WHERE node_id='${SMOKE_NODE_ID}'" >/dev/null || true
  pg_exec -c "DELETE FROM nodes WHERE id='${SMOKE_NODE_ID}'" >/dev/null || true
  pg_exec -c "DELETE FROM user_roles WHERE user_id='${SMOKE_SPONSOR_ID}'" >/dev/null || true
  pg_exec -c "DELETE FROM users WHERE id='${SMOKE_SPONSOR_ID}' OR email='${SMOKE_EMAIL}'" >/dev/null || true
  pg_exec -c "DELETE FROM product_config_versions WHERE created_by='${SMOKE_CONFIG_BY}'" >/dev/null || true
}

echo "=============================================="
echo " Sponsor Node KPI Reward Smoke"
echo "=============================================="

echo ""
echo "--- [0] Backend health ---"
for attempt in $(seq 1 30); do
  if curl -sS --max-time 3 "${API_BASE}/api/v1/health" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    break
  fi
  [[ "${attempt}" -eq 30 ]] && fail "backend not ready" && printf '%s\n' "${SUMMARY_LINES[@]}" && exit 1
  sleep 2
done
pass "backend health"

echo ""
echo "--- [1] Seed temporary sponsor node evidence ---"
cleanup_smoke_rows
pg_exec -c "INSERT INTO roles (role_key, description) VALUES ('sponsor_ambassador','Sponsor ambassador') ON CONFLICT (role_key) DO NOTHING" >/dev/null
pg_exec -c "INSERT INTO users (id, email, password_hash, display_name, status) VALUES ('${SMOKE_SPONSOR_ID}','${SMOKE_EMAIL}','smoke','Sponsor KPI Smoke','active')" >/dev/null
pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) VALUES ('${SMOKE_SPONSOR_ID}','sponsor_ambassador','sponsor node kpi smoke')" >/dev/null
pg_exec -c "INSERT INTO nodes (id, node_name, owner_user_id, owner_ambassador_id, ownership_type, node_secret_hash, agent_version, ip_address, node_region, status, load_score, degraded, quality_score, registered_bandwidth_mbps, network_tx_bytes, network_rx_bytes, current_uplink_bps, current_downlink_bps, last_heartbeat_at) VALUES ('${SMOKE_NODE_ID}','sponsor-kpi-smoke','${SMOKE_SPONSOR_ID}','${SMOKE_SPONSOR_ID}','sponsor','smokehash','smoke','203.0.113.88','JP','active',12,false,92,1000,1073741824,3221225472,80000000,120000000,'${PERIOD_END}')" >/dev/null
pg_exec -c "INSERT INTO node_heartbeats (node_id, agent_version, singbox_status, load_score, cpu_usage, memory_usage, network_tx_bytes, network_rx_bytes, active_connections, degraded, reported_at, quality_score, uptime_pct, sla_availability, traffic_contribution_gb, speedtest_success_rate) VALUES ('${SMOKE_NODE_ID}','smoke','running',12,18,32,1073741824,2147483648,12,false,'${PERIOD_START}',92,0.99,0.99,2.0,1.0), ('${SMOKE_NODE_ID}','smoke','running',12,20,35,3221225472,5368709120,16,false,'${PERIOD_END}',94,0.99,0.99,4.0,1.0)" >/dev/null
pg_exec -c "INSERT INTO node_speedtest_reports (node_id, trigger_type, provider, server_country, latency_ms, jitter_ms, download_mbps, upload_mbps, packet_loss_percent, measured_at, result, direction) VALUES ('${SMOKE_NODE_ID}','scheduled','smoke','JP',28,3,900,500,0,'${PERIOD_END}','succeeded','local')" >/dev/null
pg_exec -c "INSERT INTO node_bandwidth_capacity (node_id, measured_download_mbps, measured_upload_mbps, safe_capacity_mbps, max_load_ratio, enforced_max_bandwidth_mbps, current_observed_bandwidth_mbps, current_load_ratio, state, updated_at) VALUES ('${SMOKE_NODE_ID}',900,500,720,0.90,650,180,0.25,'healthy','${PERIOD_END}')" >/dev/null
pass "temporary sponsor node evidence"

echo ""
echo "--- [2] Publish temporary ambassador commission config ---"
FAMILY_ID=$(pg_exec -c "INSERT INTO product_config_families (key, label, description) VALUES ('ambassador-commissions','Ambassador Commissions','Smoke config') ON CONFLICT (key) DO UPDATE SET updated_at=now() RETURNING id")
NEXT_VERSION=$(pg_exec -c "SELECT COALESCE(MAX(version),0)+1 FROM product_config_versions WHERE family_id='${FAMILY_ID}'")
CONFIG_JSON='{"platform_min_profit_ratio":0.50,"sponsor_node_reward_usdt_per_gb":0.04,"sponsor_node_points_per_gb":25,"sponsor_node_platform_revenue_usdt_per_gb":0.20,"sponsor_node_procurement_cost_usdt_per_gb":0.02,"points_budget_per_period":100000,"traffic_basis":"billable_user_traffic","quality_multiplier_min":0.5,"quality_multiplier_max":1.5,"sponsor_node_region_rates":[{"region":"JP","reward_usdt_per_gb":0.05,"points_per_gb":30,"platform_revenue_usdt_per_gb":0.24,"procurement_cost_usdt_per_gb":0.03}]}'
pg_exec -c "INSERT INTO product_config_versions (family_id, version, status, config, created_by, created_at, published_at) VALUES ('${FAMILY_ID}', ${NEXT_VERSION}, 'published', '${CONFIG_JSON}'::jsonb, '${SMOKE_CONFIG_BY}', now(), now())" >/dev/null
pass "temporary ambassador-commissions config version ${NEXT_VERSION}"

echo ""
echo "--- [3] Freeze sponsor node KPI window ---"
FREEZE=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/growth/sponsor-node-kpi-freeze" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d "{\"period_start\":\"${PERIOD_START}\",\"period_end\":\"${PERIOD_END}\",\"node_ids\":[\"${SMOKE_NODE_ID}\"],\"dry_run\":false,\"limit\":10}") || true
FREEZE_OK=$(echo "${FREEZE}" | quiet_json "ok")
FREEZE_COUNT=$(echo "${FREEZE}" | quiet_json "count")
WINDOW_ID=$(echo "${FREEZE}" | quiet_json "frozen.0.id")
if [[ "${FREEZE_OK}" == "True" || "${FREEZE_OK}" == "true" ]] && [[ "${FREEZE_COUNT}" != "0" ]] && [[ -n "${WINDOW_ID}" ]]; then
  pass "kpi window frozen (${WINDOW_ID})"
else
  fail "kpi freeze failed (${FREEZE})"
fi

echo ""
echo "--- [4] Materialize sponsor node reward and points ---"
MATERIALIZE=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/growth/sponsor-node-reward-materialize" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d "{\"period_start\":\"${PERIOD_START}\",\"period_end\":\"${PERIOD_END}\",\"sponsor_user_id\":\"${SMOKE_SPONSOR_ID}\",\"node_ids\":[\"${SMOKE_NODE_ID}\"],\"dry_run\":false,\"limit\":10}") || true
MAT_OK=$(echo "${MATERIALIZE}" | quiet_json "ok")
MAT_POINTS=$(echo "${MATERIALIZE}" | quiet_json "points_total")
POINT_ROWS=$(pg_exec -c "SELECT COUNT(*) FROM growth_points_ledger WHERE user_id='${SMOKE_SPONSOR_ID}' AND source_event_id='sponsor_node_kpi:${WINDOW_ID}' AND earning_type='sponsor_node_production' AND attribution_level='sponsor_node' AND points_delta > 0")
if [[ "${MAT_OK}" == "True" || "${MAT_OK}" == "true" ]] && [[ "${MAT_POINTS}" != "0" ]] && [[ "${POINT_ROWS}" == "1" ]]; then
  pass "sponsor node points materialized (${MAT_POINTS})"
else
  fail "reward materialize/points ledger failed (response=${MATERIALIZE}, rows=${POINT_ROWS})"
fi

echo ""
echo "--- [5] Idempotency: duplicate materialize skips source ---"
DUP=$(curl -sS --max-time 10 -X POST "${API_BASE}/internal/job-executors/growth/sponsor-node-reward-materialize" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
  -d "{\"period_start\":\"${PERIOD_START}\",\"period_end\":\"${PERIOD_END}\",\"sponsor_user_id\":\"${SMOKE_SPONSOR_ID}\",\"node_ids\":[\"${SMOKE_NODE_ID}\"],\"dry_run\":false,\"limit\":10}") || true
DUP_SKIPPED=$(echo "${DUP}" | quiet_json "skipped_count")
POINT_ROWS_AFTER_DUP=$(pg_exec -c "SELECT COUNT(*) FROM growth_points_ledger WHERE user_id='${SMOKE_SPONSOR_ID}' AND source_event_id='sponsor_node_kpi:${WINDOW_ID}'")
[[ "${DUP_SKIPPED}" != "0" && "${POINT_ROWS_AFTER_DUP}" == "1" ]] && pass "duplicate materialize skipped" || fail "duplicate materialize not idempotent (skipped=${DUP_SKIPPED}, rows=${POINT_ROWS_AFTER_DUP})"

echo ""
echo "--- [6] Cleanup temporary smoke rows ---"
cleanup_smoke_rows
pass "cleanup complete"

echo ""
echo "=============================================="
printf '%s\n' "${SUMMARY_LINES[@]}"
echo "=============================================="

if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
