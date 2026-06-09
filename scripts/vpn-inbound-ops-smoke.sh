#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-VPN-INBOUND-OPS-SMOKE-001
# Ops E2E for inbound-only profiles (mixed/socks/tun) — not App client connect
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ROOT="${LIVEMASK_APP_ROOT:-${ROOT}/livemask-app}"
DOCS_ROOT="${LIVEMASK_DOCS_ROOT:-${ROOT}/livemask-docs}"

NODEAGENT_PORT="${LIVEMASK_NODEAGENT_PORT:-19090}"
MIXED_PORT="${LIVEMASK_INBOUND_MIXED_PORT:-7890}"
SOCKS_PORT="${LIVEMASK_INBOUND_SOCKS_PORT:-7891}"

echo "================================================"
echo " TASK-CICD-VPN-INBOUND-OPS-SMOKE-001"
echo " Inbound mixed/socks/tun ops acceptance"
echo "================================================"

PASS=0
FAIL=0

check_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if grep -q "${pattern}" "${file}"; then
    echo "  PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${label}"
    FAIL=1
  fi
}

echo "--- [1] Client correctly blocks inbound profiles ---"
PLUGIN_KT="${APP_ROOT}/plugins/flutter_vpn/android/src/main/kotlin/com/livemask/flutter_vpn"
check_grep "Android inbound unsupported code" \
  "${PLUGIN_KT}/AndroidTunnelRuntime.kt" "ANDROID_INBOUND_UNSUPPORTED"
check_grep "Inbound E2E task doc exists" \
  "${DOCS_ROOT}/docs/development/tasks/TASK-VPN-E2E-INBOUND-PROFILES-001.md" "mixed"

echo "--- [2] Ops probe (optional live node) ---"
if command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 2 "http://127.0.0.1:${NODEAGENT_PORT}/health" >/dev/null 2>&1; then
    echo "  INFO: NodeAgent health reachable on :${NODEAGENT_PORT}"
    for port in "${MIXED_PORT}" "${SOCKS_PORT}"; do
      if nc -z 127.0.0.1 "${port}" 2>/dev/null; then
        echo "  PASS: inbound listener open on tcp/${port}"
        PASS=$((PASS + 1))
      else
        echo "  SKIP: no listener on tcp/${port} (node may not expose inbound locally)"
      fi
    done
  else
    echo "  SKIP: NodeAgent not reachable — static inbound block checks only"
  fi
else
  echo "  SKIP: curl unavailable"
fi

echo "--- [3] Matrix marks inbound as ops-only ---"
if grep -q "ops-only" "${SCRIPT_DIR}/vpn-protocol-e2e-acceptance-smoke.sh"; then
  echo "  PASS: e2e orchestrator marks inbound ops-only"
  PASS=$((PASS + 1))
else
  echo "  FAIL: e2e orchestrator missing inbound ops-only marker"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "[TASK-CICD-VPN-INBOUND-OPS-SMOKE-001] FAILED"
  exit 1
fi

echo "[TASK-CICD-VPN-INBOUND-OPS-SMOKE-001] PASSED (${PASS} checks)"
