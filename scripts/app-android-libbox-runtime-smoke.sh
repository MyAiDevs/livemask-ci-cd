#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-APP-ANDROID-LIBBOX-RUNTIME-SMOKE-001
# Android unified Libbox engine routing + structured error codes smoke
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ROOT="${LIVEMASK_APP_ROOT:-${ROOT}/livemask-app}"
PLUGIN_KT="${APP_ROOT}/plugins/flutter_vpn/android/src/main/kotlin/com/livemask/flutter_vpn"

echo "================================================"
echo " TASK-CICD-APP-ANDROID-LIBBOX-RUNTIME-SMOKE-001"
echo " Android Libbox unified engine runtime smoke"
echo "================================================"

if [[ ! -d "${APP_ROOT}" ]]; then
  echo "BLOCKER: livemask-app not found at ${APP_ROOT}"
  exit 1
fi

PASS=0
FAIL=0
check() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if grep -q "${pattern}" "${file}"; then
    echo "  PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${label} (missing '${pattern}' in ${file})"
    FAIL=1
  fi
}

echo "--- [1] Kotlin unified routing sources ---"
check "AndroidTunnelRuntime.kt exists" "${PLUGIN_KT}/AndroidTunnelRuntime.kt" "object AndroidTunnelRuntime"
check "LibboxTunnelEngine.kt exists" "${PLUGIN_KT}/LibboxTunnelEngine.kt" "object LibboxTunnelEngine"
check "structured AAR missing code" "${PLUGIN_KT}/AndroidTunnelRuntime.kt" "ANDROID_LIBBOX_AAR_MISSING"
check "inbound unsupported code" "${PLUGIN_KT}/AndroidTunnelRuntime.kt" "ANDROID_INBOUND_UNSUPPORTED"
check "VpnHandler uses AndroidTunnelRuntime" "${PLUGIN_KT}/VpnHandler.kt" "AndroidTunnelRuntime.preStartDecision"
check "LiveMaskVpnService unified selectEngine" "${PLUGIN_KT}/LiveMaskVpnService.kt" "AndroidTunnelRuntime.resolveRoute"
if grep -q "VlessTunnelEngine" "${PLUGIN_KT}/LiveMaskVpnService.kt"; then
  echo "  FAIL: VlessTunnelEngine still referenced in LiveMaskVpnService.kt"
  FAIL=1
else
  echo "  PASS: VlessTunnelEngine removed from LiveMaskVpnService selectEngine"
  PASS=$((PASS + 1))
fi
check "build-libbox-android.sh exists" "${APP_ROOT}/scripts/build-libbox-android.sh" "libbox-release.aar"

echo "--- [2] Dart Android tunnel runtime tests ---"
cd "${APP_ROOT}"
flutter test test/app_android_tunnel_runtime_test.dart
flutter test test/app_libbox_tunnel_runtime_test.dart

if [[ "${FAIL}" -ne 0 ]]; then
  echo "[TASK-CICD-APP-ANDROID-LIBBOX-RUNTIME-SMOKE-001] FAILED (${PASS} checks, failures above)"
  exit 1
fi

echo "[TASK-CICD-APP-ANDROID-LIBBOX-RUNTIME-SMOKE-001] PASSED (${PASS} static checks + flutter tests)."
