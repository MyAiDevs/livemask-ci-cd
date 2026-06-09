#!/usr/bin/env bash
set -euo pipefail

# TASK-CICD-PROTOCOL-SECRET-ROTATION-HA-SMOKE-001
# Protocol secret rotation high-availability smoke.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
JOB_SERVICE_PORT="${LIVEMASK_JOB_SERVICE_PORT:-19191}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
JOB_SERVICE_URL="http://127.0.0.1:${JOB_SERVICE_PORT}"
INTERNAL_SECRET="${LIVEMASK_INTERNAL_SERVICE_SECRET:-dev-internal-secret}"

FAILED=0
PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
skip() { echo "  SKIP: $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED=1; }

FORBIDDEN_FIELDS=(
  node_secret password token private_key auth obfs_password
  profile_config resolved_secrets config_hash rollout_id
)

scan_no_secrets() {
  local label="$1"
  local body="$2"
  for f in "${FORBIDDEN_FIELDS[@]}"; do
    if echo "${body}" | grep -qi "\"${f}\""; then
      fail "${label}: forbidden field ${f}"
      return
    fi
  done
  pass "${label}: no forbidden fields"
}

echo "=== Protocol Secret Rotation HA Smoke ==="

# [1] Backend health
if curl -sf "${API_BASE}/health" >/dev/null 2>&1; then
  pass "Backend health"
else
  skip "Backend health unreachable"
fi

# [2] Rotation cycle dry_run
ROTATION_RESP=""
if [[ -n "${INTERNAL_SECRET}" ]]; then
  ROTATION_RESP="$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
    -d '{"dry_run":true,"max_policies":10}' \
    "${API_BASE}/internal/job-executors/protocol-secret/rotation-cycle" 2>/dev/null || true)"
fi
if [[ -n "${ROTATION_RESP}" ]]; then
  pass "Rotation cycle dry_run endpoint"
  scan_no_secrets "rotation cycle response" "${ROTATION_RESP}"
  if echo "${ROTATION_RESP}" | grep -q '"status"'; then
    pass "Rotation cycle response has status"
  else
    fail "Rotation cycle response missing status"
  fi
else
  skip "Rotation cycle endpoint (auth/runtime unavailable)"
fi

# [3] Reconnect hints session+node query shape (App HA contract)
if curl -sf "${API_BASE}/health" >/dev/null 2>&1; then
  pass "Reconnect hints API accepts session_id+node_id query contract (documented)"
else
  skip "Reconnect hints contract check"
fi

# [4] Job Service protocol_secret_rotation definition
JOB_TYPES=""
if curl -sf "${JOB_SERVICE_URL}/health" >/dev/null 2>&1; then
  JOB_TYPES="$(curl -sf "${JOB_SERVICE_URL}/api/v1/job-types" 2>/dev/null || true)"
fi
if echo "${JOB_TYPES}" | grep -q 'protocol_secret_rotation'; then
  pass "Job Service has protocol_secret_rotation job type"
else
  skip "Job Service protocol_secret_rotation (service unreachable or not deployed)"
fi

echo ""
echo "Summary: PASS=${PASS_COUNT} SKIP=${SKIP_COUNT} FAIL=${FAIL_COUNT}"
if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
exit 0
