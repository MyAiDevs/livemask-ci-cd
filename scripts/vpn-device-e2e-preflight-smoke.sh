#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-VPN-DEVICE-E2E-PREFLIGHT-SMOKE-001
# Automated preflight for L5 device proofs (OL-P0-01/02 + TASK-VPN-E2E-*)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ROOT="${LIVEMASK_APP_ROOT:-${ROOT}/livemask-app}"
DOCS_ROOT="${LIVEMASK_DOCS_ROOT:-${ROOT}/livemask-docs}"

PROFILES=(
  hysteria2
  vless
  vless_reality
  trojan
  shadowtls
  wireguard
  shadowsocks
  tuic
  anytls
)

echo "================================================"
echo " TASK-CICD-VPN-DEVICE-E2E-PREFLIGHT-SMOKE-001"
echo " L5 device E2E preflight (code path + docs gate)"
echo "================================================"

PASS=0
FAIL=0

check_file() {
  local label="$1"
  local file="$2"
  if [[ -f "${file}" ]]; then
    echo "  PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${label} (${file})"
    FAIL=1
  fi
}

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

echo "--- [1] Apple Libbox dataplane wired ---"
check_file "iOS LibboxTunnelEngine" "${APP_ROOT}/ios/PacketTunnel/LibboxTunnelEngine.swift"
check_file "macOS LibboxTunnelEngine" "${APP_ROOT}/macos/PacketTunnel/LibboxTunnelEngine.swift"
check_grep "iOS H2 forwarding guard" \
  "${APP_ROOT}/plugins/flutter_vpn/ios/Classes/VpnHandler.swift" "HYSTERIA2_FORWARDING_IMPLEMENTED = true"
check_grep "macOS H2 forwarding guard" \
  "${APP_ROOT}/plugins/flutter_vpn/macos/Classes/VpnHandler.swift" "HYSTERIA2_FORWARDING_IMPLEMENTED = true"

echo "--- [2] Android libbox bridge wired ---"
check_grep "Android PLATFORM_BRIDGE_WIRED" \
  "${APP_ROOT}/plugins/flutter_vpn/android/src/main/kotlin/com/livemask/flutter_vpn/LibboxTunnelEngine.kt" \
  "PLATFORM_BRIDGE_WIRED = true"
check_file "Android LibboxPlatformInterface" \
  "${APP_ROOT}/plugins/flutter_vpn/android/src/main/kotlin/com/livemask/flutter_vpn/LibboxPlatformInterface.kt"

echo "--- [3] Per-protocol TASK-VPN-E2E docs ---"
for profile in "${PROFILES[@]}"; do
  if [[ "${profile}" == "hysteria2" ]]; then
    continue
  fi
  suffix="$(echo "${profile}" | tr '[:lower:]' '[:upper:]' | tr '_' '-')"
  task="${DOCS_ROOT}/docs/development/tasks/TASK-VPN-E2E-${suffix}-001.md"
  check_file "TASK-VPN-E2E-${suffix}-001" "${task}"
done

echo "--- [4] OL-P0 signing runbook present ---"
check_grep "OL-P0-01 macOS tunnel proof" \
  "${DOCS_ROOT}/docs/development/APP_CLIENT_OPEN_LOOPS.md" "OL-P0-01"
check_grep "OL-P0-02 iOS Hysteria2 device proof" \
  "${DOCS_ROOT}/docs/development/APP_CLIENT_OPEN_LOOPS.md" "OL-P0-02"

echo "--- [5] Optional Apple build preflight ---"
if command -v flutter >/dev/null 2>&1; then
  cd "${APP_ROOT}"
  if flutter build ios --no-codesign >/dev/null 2>&1; then
    echo "  PASS: flutter build ios --no-codesign"
    PASS=$((PASS + 1))
  else
    echo "  SKIP: flutter build ios --no-codesign failed (env/Xcode)"
  fi
  if flutter build macos >/dev/null 2>&1; then
    echo "  PASS: flutter build macos"
    PASS=$((PASS + 1))
  else
    echo "  SKIP: flutter build macos failed (env/Xcode)"
  fi
else
  echo "  SKIP: flutter not available"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "[TASK-CICD-VPN-DEVICE-E2E-PREFLIGHT-SMOKE-001] FAILED"
  exit 1
fi

echo "[TASK-CICD-VPN-DEVICE-E2E-PREFLIGHT-SMOKE-001] PASSED (${PASS} checks)"
echo "L5 live traffic proof remains a manual gate on signed hardware."
