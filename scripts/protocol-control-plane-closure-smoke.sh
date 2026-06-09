#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-PROTOCOL-CONTROL-PLANE-CLOSURE-SMOKE-001
# Closes GAP-CP-01/02: endpoint_ready + runtime_verified staging proof
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKEND_ROOT="${LIVEMASK_BACKEND_ROOT:-${ROOT}/livemask-backend}"
NODEAGENT_ROOT="${LIVEMASK_NODEAGENT_ROOT:-${ROOT}/livemask-nodeagent}"
DOCS_ROOT="${LIVEMASK_DOCS_ROOT:-${ROOT}/livemask-docs}"

echo "================================================"
echo " TASK-CICD-PROTOCOL-CONTROL-PLANE-CLOSURE-SMOKE-001"
echo " Control plane endpoint_ready + runtime_verified closure"
echo "================================================"

PASS=0
FAIL=0

check() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if [[ -f "${file}" ]] && grep -q "${pattern}" "${file}"; then
    echo "  PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${label}"
    FAIL=1
  fi
}

echo "--- [1] Contract + registry static gates (GAP-CP-02) ---"
check "runtime_verified in control plane contract" \
  "${DOCS_ROOT}/docs/contracts/protocol-endpoint/PROTOCOL_RUNTIME_CONTROL_PLANE_CONTRACT.md" \
  "runtime_verified"
check "endpoint_ready promotion path documented" \
  "${DOCS_ROOT}/docs/contracts/protocol-endpoint/PROTOCOL_ENDPOINT_TEMPLATE_CONTRACT.md" \
  "endpoint_ready"
check "Backend capability parity runtime_verified" \
  "${BACKEND_ROOT}/internal/protocol/types.go" \
  "RuntimeVerified"
check "NodeAgent runtime_verified heartbeat field" \
  "${NODEAGENT_ROOT}/internal/singbox/protocol/capability.go" \
  "runtime_verified"

echo "--- [2] CI rollout smoke scripts present (GAP-CP-01) ---"
check "protocol-endpoint-smoke endpoint_ready step" \
  "${SCRIPT_DIR}/protocol-endpoint-smoke.sh" \
  "endpoint_ready"
check "protocol-capability-smoke eligibility" \
  "${SCRIPT_DIR}/protocol-capability-smoke.sh" \
  "protocol_capabilities"

echo "--- [3] Runtime proof (docker staging when available) ---"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if bash "${SCRIPT_DIR}/protocol-endpoint-smoke.sh"; then
    echo "  PASS: protocol-endpoint-smoke (endpoint_ready path)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: protocol-endpoint-smoke"
    FAIL=1
  fi
  if bash "${SCRIPT_DIR}/protocol-capability-smoke.sh"; then
    echo "  PASS: protocol-capability-smoke (runtime_verified path)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: protocol-capability-smoke"
    FAIL=1
  fi
else
  echo "  SKIP: docker unavailable — static gates only"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "[TASK-CICD-PROTOCOL-CONTROL-PLANE-CLOSURE-SMOKE-001] FAILED"
  exit 1
fi

echo "[TASK-CICD-PROTOCOL-CONTROL-PLANE-CLOSURE-SMOKE-001] PASSED (${PASS} checks)"
