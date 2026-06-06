#!/usr/bin/env bash
# TASK-VPN-PACKAGE-C2C-MARKET-CLOSED-LOOP-001 — Gates A+B+C orchestrator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/../infra/docker-compose.local.yml}"
if [[ "${COMPOSE_FILE}" != /* ]]; then
  COMPOSE_FILE="${SCRIPT_DIR}/../${COMPOSE_FILE}"
fi
COMPOSE_FILE="$(cd "$(dirname "${COMPOSE_FILE}")" && pwd)/$(basename "${COMPOSE_FILE}")"
export COMPOSE_FILE

FAILED=0
SUMMARY_LINES=()
fail() { echo "  FAIL: $1"; SUMMARY_LINES+=("FAIL: $1"); FAILED=1; }
pass() { echo "  PASS: $1"; SUMMARY_LINES+=("PASS: $1"); }

run_smoke() {
  local name="$1"
  local script="$2"
  echo ""
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
  echo " Running ${name}"
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
  if bash "${SCRIPT_DIR}/${script}"; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

echo "========================================"
echo " VPN/C2C Closed Loop Smoke (Gates A+B+C)"
echo "========================================"

run_smoke "Gate A — C2C baseline" "c2c-points-market-smoke.sh"
run_smoke "Gate B — Traffic package" "traffic-package-plan-smoke.sh"
run_smoke "Gate C — Package→C2C bridge" "commerce-marketplace-bridge-smoke.sh"

echo ""
echo "Gate D — NodeAgent usage report is covered inside traffic-package-plan-smoke.sh [11]"

echo ""
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
if [[ "${FAILED}" -ne 0 ]]; then
  echo "VPN/C2C Closed Loop Smoke: FAIL"
  exit 1
fi
echo "VPN/C2C Closed Loop Smoke: PASS"
exit 0
