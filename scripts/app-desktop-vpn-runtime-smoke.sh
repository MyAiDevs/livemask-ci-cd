#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-APP-DESKTOP-VPN-RUNTIME-SMOKE-001
# Windows/Linux desktop VPN runtime Dart smoke
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ROOT="${LIVEMASK_APP_ROOT:-${ROOT}/livemask-app}"

echo "================================================"
echo " TASK-CICD-APP-DESKTOP-VPN-RUNTIME-SMOKE-001"
echo " App desktop VPN runtime smoke"
echo "================================================"

if [[ ! -d "${APP_ROOT}" ]]; then
  echo "BLOCKER: livemask-app not found at ${APP_ROOT}"
  exit 1
fi

cd "${APP_ROOT}"

echo "--- [1] desktop_tunnel_runtime_test.dart ---"
flutter test test/desktop_tunnel_runtime_test.dart

echo "--- [2] singbox_config_builder_test.dart ---"
flutter test test/singbox_config_builder_test.dart

echo "--- [3] plugin scaffold (windows/linux) ---"
test -f plugins/flutter_vpn/windows/flutter_vpn_plugin.cpp
test -f plugins/flutter_vpn/linux/flutter_vpn_plugin.cc
test -f plugins/flutter_vpn/shared/desktop_singbox_engine.cc
grep -q "windows:" plugins/flutter_vpn/pubspec.yaml
grep -q "linux:" plugins/flutter_vpn/pubspec.yaml

echo "[TASK-CICD-APP-DESKTOP-VPN-RUNTIME-SMOKE-001] App desktop VPN runtime smoke PASSED."
