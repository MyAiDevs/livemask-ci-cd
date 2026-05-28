#!/usr/bin/env bash
# TASK-CICD-APP-HYSTERIA2-AAR-BUILD-001
# Build/verify Android Hysteria2 AAR from livemask-app in a reproducible CI path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_REPO_DEFAULT="${REPO_ROOT}/../livemask-app"
APP_REPO="${LIVEMASK_APP_REPO:-${APP_REPO_DEFAULT}}"
VERIFY_ONLY="false"
SKIP_DEBUG_BUILD="false"
ALLOW_STALE="false"

log() { printf '[h2mobile-aar] %s\n' "$*"; }
die() { printf '[h2mobile-aar][ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/app-hysteria2-aar-build-smoke.sh [--app-repo <path>] [--verify-only] [--skip-debug-build] [--allow-stale]

Options:
  --app-repo <path>      Path to livemask-app repository (default: ../livemask-app).
  --verify-only          Skip gomobile build; only verify existing artifacts.
  --skip-debug-build     Skip Android :app:assembleDebug step.
  --allow-stale          Do not fail when AAR/classes are older than gomobile inputs.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-repo)
      [[ $# -ge 2 ]] || die "--app-repo requires a path"
      APP_REPO="$2"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY="true"
      shift
      ;;
    --skip-debug-build)
      SKIP_DEBUG_BUILD="true"
      shift
      ;;
    --allow-stale)
      ALLOW_STALE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -d "${APP_REPO}" ]] || die "App repo not found: ${APP_REPO}"
[[ -f "${APP_REPO}/scripts/build-h2mobile.sh" ]] || die "Missing app build script: ${APP_REPO}/scripts/build-h2mobile.sh"

AAR_PATH="${APP_REPO}/plugins/flutter_vpn/android/libs/h2mobile-release.aar"
CLASS_JAR_PATH="${APP_REPO}/plugins/flutter_vpn/android/libs/h2mobile-classes.jar"
APP_ANDROID_AAR_PATH="${APP_REPO}/android/app/libs/h2mobile-release.aar"

if [[ "${VERIFY_ONLY}" != "true" ]]; then
  log "Running app gomobile build script"
  bash "${APP_REPO}/scripts/build-h2mobile.sh"
else
  log "Verify-only mode enabled; skipping gomobile build"
fi

if [[ ! -f "${AAR_PATH}" && -f "${APP_ANDROID_AAR_PATH}" ]]; then
  log "Primary AAR not found in plugin path; using android/app/libs fallback"
  AAR_PATH="${APP_ANDROID_AAR_PATH}"
fi

[[ -f "${AAR_PATH}" ]] || die "AAR not found: ${AAR_PATH}"
[[ -f "${CLASS_JAR_PATH}" ]] || die "classes jar not found: ${CLASS_JAR_PATH}"

log "Verifying required ABI libraries in AAR"
required_abis=("armeabi-v7a" "arm64-v8a" "x86" "x86_64")
aar_listing="$(unzip -l "${AAR_PATH}")"
for abi in "${required_abis[@]}"; do
  if ! grep -q "jni/${abi}/libgojni.so" <<<"${aar_listing}"; then
    die "Missing libgojni.so for ABI ${abi} in ${AAR_PATH}"
  fi
done

file_mtime() {
  local p="$1"
  if stat -f %m "$p" >/dev/null 2>&1; then
    stat -f %m "$p"
  else
    stat -c %Y "$p"
  fi
}

assert_not_stale() {
  local artifact="$1"
  shift
  local artifact_ts
  artifact_ts="$(file_mtime "${artifact}")"
  for ref in "$@"; do
    [[ -f "${ref}" ]] || continue
    local ref_ts
    ref_ts="$(file_mtime "${ref}")"
    if [[ "${artifact_ts}" -lt "${ref_ts}" ]]; then
      die "Artifact stale: ${artifact} is older than ${ref}"
    fi
  done
}

log "Running stale checks against gomobile inputs"
if [[ "${ALLOW_STALE}" == "true" ]]; then
  log "allow-stale enabled; stale checks are skipped"
else
  assert_not_stale "${AAR_PATH}" \
    "${APP_REPO}/go/mobile/mobile.go" \
    "${APP_REPO}/go/mobile/go.mod" \
    "${APP_REPO}/scripts/build-h2mobile.sh"
  assert_not_stale "${CLASS_JAR_PATH}" \
    "${APP_REPO}/go/mobile/mobile.go" \
    "${APP_REPO}/go/mobile/go.mod" \
    "${APP_REPO}/scripts/build-h2mobile.sh"
fi

if [[ "${VERIFY_ONLY}" != "true" && "${SKIP_DEBUG_BUILD}" != "true" ]]; then
  [[ -x "${APP_REPO}/android/gradlew" ]] || die "Android gradle wrapper missing: ${APP_REPO}/android/gradlew"
  log "Running Android debug build (:app:assembleDebug)"
  (
    cd "${APP_REPO}/android"
    ./gradlew --no-daemon :app:assembleDebug
  )
else
  log "Skipping Android debug build (verify-only or --skip-debug-build)"
fi

log "PASS: Hysteria2 AAR build/verification succeeded"
log "AAR: ${AAR_PATH}"
log "Classes: ${CLASS_JAR_PATH}"
