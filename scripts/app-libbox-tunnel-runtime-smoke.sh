#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-APP-LIBBOX-TUNNEL-RUNTIME-SMOKE-001
# App Libbox tunnel runtime rules + config matrix smoke
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ROOT="${LIVEMASK_APP_ROOT:-${ROOT}/livemask-app}"

echo "================================================"
echo " TASK-CICD-APP-LIBBOX-TUNNEL-RUNTIME-SMOKE-001"
echo " App Libbox tunnel runtime smoke"
echo "================================================"

if [[ ! -d "${APP_ROOT}" ]]; then
  echo "BLOCKER: livemask-app not found at ${APP_ROOT}"
  exit 1
fi

cd "${APP_ROOT}"

echo "--- [1] app_libbox_tunnel_runtime_test.dart ---"
flutter test test/app_libbox_tunnel_runtime_test.dart

echo "--- [2] singbox_config_builder_test.dart ---"
flutter test test/singbox_config_builder_test.dart

echo "[TASK-CICD-APP-LIBBOX-TUNNEL-RUNTIME-SMOKE-001] App Libbox tunnel runtime smoke PASSED."
