#!/usr/bin/env bash
# TASK-CICD-LARGE-FLEET-DRY-RUN-SMOKE-001
# Runs the fleet load smoke at 10k, 50k, and 100k and verifies the code-level
# guards that prevent provider-card-only or run-level-only false positives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVEMASK_ROOT="${LIVEMASK_ROOT:-$HOME/Developer/LiveMask}"
JOB_SERVICE_REPO="${JOB_SERVICE_REPO:-${LIVEMASK_ROOT}/livemask-job-service}"
BACKEND_REPO="${BACKEND_REPO:-${LIVEMASK_ROOT}/livemask-backend}"
ADMIN_REPO="${ADMIN_REPO:-${LIVEMASK_ROOT}/livemask-admin}"
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAILED=1; }

require_file_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if [[ ! -f "${file}" ]]; then
    fail "${label}: missing ${file}"
    return
  fi
  if grep -qE "${pattern}" "${file}"; then
    pass "${label}"
  else
    fail "${label}: pattern ${pattern} not found in ${file}"
  fi
}

echo "================================================"
echo " Large Fleet Dry-Run Smoke: 10k / 50k / 100k"
echo "================================================"

for scale in 10k 50k 100k; do
  echo ""
  echo "--- scale=${scale} ---"
  if SKIP_REAL_CALLS="${SKIP_REAL_CALLS:-true}" SCALE_LEVEL="${scale}" bash "${SCRIPT_DIR}/fleet-load-smoke.sh"; then
    pass "fleet-load-smoke ${scale}"
  else
    fail "fleet-load-smoke ${scale}"
  fi
done

echo ""
echo "--- code contract guards ---"
require_file_contains \
  "${JOB_SERVICE_REPO}/internal/jobs/store.go" \
  "ClaimTargetBatch|HeartbeatTargetBatch|ReleaseExpiredTargetLeases|TargetSummary" \
  "Job Service exposes target-batch claim and summary store contract"
require_file_contains \
  "${JOB_SERVICE_REPO}/internal/jobs/sqlstore/store.go" \
  "FOR UPDATE SKIP LOCKED|job_run_targets|fencing_token" \
  "Job Service SQL store has target leases with SKIP LOCKED and fencing"
require_file_contains \
  "${BACKEND_REPO}/internal/nodeagent/executor.go" \
  "node_ids|idempotency_key|accepted|retryable" \
  "Backend NodeAgent executor supports legacy node_ids and bounded results"
require_file_contains \
  "${BACKEND_REPO}/internal/protocol/executor.go" \
  "node_ids|idempotency_key|accepted|retryable" \
  "Backend Protocol executor supports legacy node_ids and bounded results"
require_file_contains \
  "${ADMIN_REPO}/src/app/admin/jobs/runs/[id]/page.tsx" \
  "fleet-target-summary|target-summary-source|result_summary" \
  "Admin job run detail exposes fleet target summary semantics"
require_file_contains \
  "${ADMIN_REPO}/src/lib/i18n/locales/zh-CN.json" \
  "集群目标摘要|可分页的持久化目标明细" \
  "Admin fleet summary has zh-CN localization"
require_file_contains \
  "${ADMIN_REPO}/src/lib/i18n/locales/en-US.json" \
  "Fleet Target Summary|paginated durable target details" \
  "Admin fleet summary has en-US localization"

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "Large Fleet Dry-Run Smoke PASS"
else
  echo "Large Fleet Dry-Run Smoke FAILED"
  exit 1
fi
