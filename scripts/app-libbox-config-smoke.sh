#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-APP-LIBBOX-CONFIG-SMOKE-001
# App Libbox sing-box config builder matrix smoke (Dart unit tests)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ROOT="${LIVEMASK_APP_ROOT:-${ROOT}/livemask-app}"

echo "================================================"
echo " TASK-CICD-APP-LIBBOX-CONFIG-SMOKE-001"
echo " App Libbox config builder smoke"
echo "================================================"

if [[ ! -d "${APP_ROOT}" ]]; then
  echo "BLOCKER: livemask-app not found at ${APP_ROOT}"
  exit 1
fi

cd "${APP_ROOT}"

echo "--- [1] singbox_config_builder_test.dart ---"
flutter test test/singbox_config_builder_test.dart

echo "--- [2] connect_models regression ---"
flutter test test/connect_models_test.dart

echo "[TASK-CICD-APP-LIBBOX-CONFIG-SMOKE-001] App Libbox config smoke PASSED."
