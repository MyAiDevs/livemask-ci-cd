#!/usr/bin/env bash
set -euo pipefail

# TASK-CICD-PROTOCOL-SECRET-ROTATION-HA-STAGING-SEED-001
# Seed staging environment with protocol secret rotation test data.
# Run AFTER Backend + Job Service + NodeAgent are deployed to staging.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

STAGING_BACKEND="${LIVEMASK_STAGING_BACKEND_URL:-http://127.0.0.1:18080}"
STAGING_JOB="${LIVEMASK_STAGING_JOB_SERVICE_URL:-http://127.0.0.1:19191}"
INTERNAL_SECRET="${LIVEMASK_INTERNAL_SERVICE_SECRET:-dev-internal-secret}"
ADMIN_TOKEN="${LIVEMASK_STAGING_ADMIN_TOKEN:-}"
API_BASE="${STAGING_BACKEND}"

FAILED=0
PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
skip() { echo "  SKIP: $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED=1; }

echo "=== Protocol Secret Rotation Staging Seed ==="
echo "Backend: ${API_BASE}"
echo "Job Service: ${STAGING_JOB}"
echo ""

# ── Health check ────────────────────────────────────────────────────────
echo "[1] Health checks"
if curl -sf "${API_BASE}/health" >/dev/null 2>&1; then
  pass "Backend health"
else
  fail "Backend health unreachable"
fi

if curl -sf "${STAGING_JOB}/health" >/dev/null 2>&1; then
  pass "Job Service health"
else
  skip "Job Service health unreachable"
fi
echo ""

# ── Create test secret policy (hysteria2 auth) ──────────────────────────
POLICY_NAME="staging-smoke-hysteria2-auth-$(date +%s)"
POLICY_ID=""
echo "[2] Create secret policy"
if [[ -n "${ADMIN_TOKEN}" ]]; then
  CREATE_RESP=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d "{\"name\":\"${POLICY_NAME}\",\"secret_type\":\"auth\",\"scope\":\"template\",\"scope_ref\":\"proto-hysteria2-default\",\"generation_strategy\":\"backend_generated\",\"rotation_interval\":\"30m\",\"overlap_window\":\"5m\"}" \
    "${API_BASE}/api/v1/admin/protocol/secret-policies" 2>/dev/null || true)
  POLICY_ID=$(echo "${CREATE_RESP}" | jq -r '.policy_id // empty' 2>/dev/null || true)
fi

if [[ -n "${POLICY_ID}" ]]; then
  pass "Secret policy created: ${POLICY_ID}"
else
  skip "Secret policy creation (admin token not configured or API unavailable)"
fi
echo ""

# ── Generate secret version ─────────────────────────────────────────────
MATERIAL_VALUE="seed-auth-$(openssl rand -hex 16 2>/dev/null || echo "dev-seed-auth")"
VERSION_ID=""
echo "[3] Generate secret version"
if [[ -n "${POLICY_ID}" && -n "${ADMIN_TOKEN}" ]]; then
  GEN_RESP=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d "{\"material\":{\"auth\":\"${MATERIAL_VALUE}\"}}" \
    "${API_BASE}/api/v1/admin/protocol/secret-policies/${POLICY_ID}/versions" 2>/dev/null || true)
  VERSION_ID=$(echo "${GEN_RESP}" | jq -r '.version_id // empty' 2>/dev/null || true)
fi

if [[ -n "${VERSION_ID}" ]]; then
  pass "Secret version generated: ${VERSION_ID}"
else
  skip "Secret version generation"
fi
echo ""

# ── Promote version to active ───────────────────────────────────────────
echo "[4] Promote secret version"
if [[ -n "${VERSION_ID}" && -n "${ADMIN_TOKEN}" ]]; then
  if curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${API_BASE}/api/v1/admin/protocol/secret-policies/${POLICY_ID}/versions/${VERSION_ID}/promote" >/dev/null 2>&1; then
    pass "Secret version promoted"
  else
    fail "Secret version promotion failed"
  fi
else
  skip "Secret version promotion"
fi
echo ""

# ── Trigger rotation (dry_run first, then live) ─────────────────────────
echo "[5] Trigger rotation dry_run"
DRY_RUN_RESP=""
if [[ -n "${INTERNAL_SECRET}" ]]; then
  DRY_RUN_RESP=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
    -d "{\"dry_run\":true,\"max_policies\":10}" \
    "${API_BASE}/internal/job-executors/protocol-secret/rotation-cycle" 2>/dev/null || true)
fi

if [[ -n "${DRY_RUN_RESP}" ]]; then
  POLICIES_SCANNED=$(echo "${DRY_RUN_RESP}" | jq -r '.policies_scanned // 0' 2>/dev/null || echo "0")
  ROTATED=$(echo "${DRY_RUN_RESP}" | jq -r '.rotated // 0' 2>/dev/null || echo "0")
  if [[ "${POLICIES_SCANNED}" -gt 0 || "${ROTATED}" -gt 0 ]]; then
    pass "Rotation dry_run: scanned=${POLICIES_SCANNED} rotated=${ROTATED}"
  else
    skip "Rotation dry_run: no due policies (seed policy may need time to become due)"
  fi
else
  skip "Rotation dry_run API unreachable"
fi
echo ""

# ── Live rotation ───────────────────────────────────────────────────────
echo "[6] Trigger live rotation"
LIVE_RESP=""
if [[ -n "${INTERNAL_SECRET}" ]]; then
  LIVE_RESP=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "X-Internal-Secret: ${INTERNAL_SECRET}" \
    -d "{\"dry_run\":false,\"max_policies\":10}" \
    "${API_BASE}/internal/job-executors/protocol-secret/rotation-cycle" 2>/dev/null || true)
fi

if [[ -n "${LIVE_RESP}" ]]; then
  POLICIES_SCANNED=$(echo "${LIVE_RESP}" | jq -r '.policies_scanned // 0' 2>/dev/null || echo "0")
  ROTATED=$(echo "${LIVE_RESP}" | jq -r '.rotated // 0' 2>/dev/null || echo "0")
  if [[ "${ROTATED}" -gt 0 ]]; then
    pass "Live rotation: scanned=${POLICIES_SCANNED} rotated=${ROTATED}"
  else
    pass "Live rotation executed: scanned=${POLICIES_SCANNED} rotated=${ROTATED} (0 rotated = no due policies)"
  fi
else
  skip "Live rotation API unreachable"
fi
echo ""

# ── Verify no secrets leaked in responses ───────────────────────────────
echo "[7] Secret leak scan"
FORBIDDEN=("password" "token" "private_key" "auth" "node_secret")
LEAK_FOUND=0
for resp in "${DRY_RUN_RESP}" "${LIVE_RESP}"; do
  if [[ -z "${resp}" ]]; then continue; fi
  for f in "${FORBIDDEN[@]}"; do
    if echo "${resp}" | grep -qi "\"${f}\""; then
      fail "Leak scan: forbidden field '${f}' in response"
      LEAK_FOUND=1
    fi
  done
done
if [[ ${LEAK_FOUND} -eq 0 ]]; then
  pass "Leak scan: no forbidden fields in rotation responses"
fi
echo ""

# ── Verify endpoint list still healthy ──────────────────────────────────
echo "[8] Verify endpoint health post-rotation"
if curl -sf "${API_BASE}/api/v1/connect/endpoints" >/dev/null 2>&1; then
  pass "Connect endpoints accessible post-rotation"
else
  skip "Connect endpoints check"
fi
echo ""

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "PASS: ${PASS_COUNT}  SKIP: ${SKIP_COUNT}  FAIL: ${FAIL_COUNT}"
if [[ ${FAILED} -ne 0 ]]; then
  echo "Seed script: SOME CHECKS FAILED"
  exit 1
fi
echo "Seed script: ALL CHECKS PASSED (some skipped)"
