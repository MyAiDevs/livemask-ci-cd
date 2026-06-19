#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# TASK-CICD-DOCKER-BUILD-PRIVATE-REPO-001
#
# Prepares infra/_build_deps/ directories for staging Docker builds.
# Provides source code to Dockerfiles via local build context,
# eliminating the need for git clone/fetch inside Dockerfiles.
#
# CI workflow:
#   1. actions/checkout@v4 places repo source into infra/_build_deps/<name>/
#   2. This script runs with --ci to create .exists markers
#   3. docker compose build succeeds via local COPY
#
# Local dev:
#   1. This script copies source from LIVEMASK_WORKSPACE_ROOT (e.g. ~/Developer/LiveMask)
#   2. docker compose build succeeds via local COPY
#
# Usage:
#   bash scripts/prepare-staging-build-context.sh [--workspace PATH] [--ci]
#
# Options:
#   --workspace PATH   LiveMask workspace root (default: $LIVEMASK_WORKSPACE_ROOT or ~/Developer/LiveMask)
#   --ci               CI mode: only create .exists markers, don't copy source (use with actions/checkout)
#   --help             Show this help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"
BUILD_DEPS="${REPO_ROOT}/infra/_build_deps"
CI_MODE=false
DEPLOY_SERVICE_FILTER="${DEPLOY_SERVICE:-all}"

# Map rows: build-dest dir | workspace repo name
REPO_ROWS="
backend|livemask-backend
admin|livemask-admin
website|livemask-website
job-service|livemask-job-service
nodeagent|livemask-nodeagent
"

required_ci_files() {
  case "$1" in
    backend)
      printf '%s\n' "go.mod"
      ;;
    admin|website)
      printf '%s\n' "package.json"
      ;;
    job-service)
      printf '%s\n' "go.mod"
      ;;
    nodeagent)
      printf '%s\n' "go.mod" "scripts/install-singbox.sh" "docker/entrypoint.sh"
      ;;
  esac
}

copy_workspace_source() {
  local ws_repo="$1"
  local target="$2"
  local repo_name="$3"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude='.git' \
      --exclude='.cache' \
      --exclude='.gomodcache' \
      --exclude='node_modules' \
      --exclude='.next' \
      --exclude='dist' \
      --exclude='build' \
      "${ws_repo}/" "${target}/"
  else
    # Keep the fallback content-shaped like rsync's source-root copy. The old
    # cp fallback copied `${repo_name}/` as a nested directory, which breaks
    # Dockerfiles that expect package.json/go.mod at infra/_build_deps/<name>/.
    if [[ -d "${target}/${repo_name}" ]]; then
      echo "[prepare]  [cleanup] removing legacy nested copy: ${target}/${repo_name}"
      rm -rf "${target:?}/${repo_name}"
    fi
    (
      cd "${ws_repo}"
      tar \
        --exclude='./.git' \
        --exclude='./.cache' \
        --exclude='./.gomodcache' \
        --exclude='./node_modules' \
        --exclude='./.next' \
        --exclude='./dist' \
        --exclude='./build' \
        -cf - .
    ) | (
      cd "${target}"
      tar -xf -
    )
  fi
}

verify_build_context() {
  local dir_name="$1"
  local repo_name="$2"
  local target="$3"
  local missing=()

  while IFS= read -r required_file; do
    [[ -z "${required_file}" ]] && continue
    if [[ ! -f "${target}/${required_file}" ]]; then
      missing+=("${required_file}")
    fi
  done < <(required_ci_files "${dir_name}")

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "ERROR: build context for ${repo_name} is incomplete at ${target}" >&2
    printf '  missing: %s\n' "${missing[@]}" >&2
    echo "Verify LIVEMASK_WORKSPACE_ROOT and the copy fallback before docker compose build." >&2
    exit 2
  fi
}

should_prepare_dir() {
  local dir_name="$1"
  case "${DEPLOY_SERVICE_FILTER}" in
    all|"")
      return 0
      ;;
    backend|admin|website|nodeagent)
      [[ "${dir_name}" == "${DEPLOY_SERVICE_FILTER}" ]]
      return
      ;;
    job-service|job_service|jobservice)
      [[ "${dir_name}" == "job-service" ]]
      return
      ;;
    *)
      echo "ERROR: unknown DEPLOY_SERVICE=${DEPLOY_SERVICE_FILTER}" >&2
      echo "Expected one of: all, backend, admin, website, job-service, nodeagent" >&2
      exit 2
      ;;
  esac
}

# ============================================================
# Parse args
# ============================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE_ROOT="${2:-}"
      shift 2
      ;;
    --ci)
      CI_MODE=true
      shift
      ;;
    --help|-h)
      sed -n '3,/^# =/p' "${BASH_SOURCE[0]}" | sed 's/^# //;s/^#$//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# ============================================================
# Main
# ============================================================

echo "[prepare] Preparing staging build context at: ${BUILD_DEPS}"
echo "[prepare] Deploy service filter: ${DEPLOY_SERVICE_FILTER}"
mkdir -p "${BUILD_DEPS}"

printf "%s" "${REPO_ROWS}" | while IFS='|' read -r dir_name repo_name; do
  [[ -z "${dir_name}" ]] && continue
  if ! should_prepare_dir "${dir_name}"; then
    echo "[prepare]  [skip] ${repo_name} — not required for DEPLOY_SERVICE=${DEPLOY_SERVICE_FILTER}"
    continue
  fi
  target="${BUILD_DEPS}/${dir_name}"

  if [[ "${CI_MODE}" == "true" ]]; then
    # CI mode: actions/checkout placed source files.
    # Fail closed if checkout did not place the expected source files. Creating
    # stubs in CI hides broken checkout paths and later produces misleading
    # Docker build errors.
    mkdir -p "${target}"
    missing=()
    while IFS= read -r required_file; do
      [[ -z "${required_file}" ]] && continue
      if [[ ! -f "${target}/${required_file}" ]]; then
        missing+=("${required_file}")
      fi
    done < <(required_ci_files "${dir_name}")
    if [[ "${#missing[@]}" -gt 0 ]]; then
      echo "ERROR: CI build context for ${repo_name} is incomplete at ${target}" >&2
      printf '  missing: %s\n' "${missing[@]}" >&2
      echo "Verify actions/checkout path and ref before running docker compose build." >&2
      exit 2
    fi
    echo "[prepare]  [CI] ${target} — source from checkout found"
    touch "${target}/.exists"
    continue
  fi

  # Local dev mode: copy from workspace repos, or create stub
  ws_repo="${WORKSPACE_ROOT}/${repo_name}"
  if [[ -d "${ws_repo}" ]]; then
    echo "[prepare]  [workspace] ${ws_repo} → ${target}"
    mkdir -p "${target}"
    # Use rsync or tar fallback to copy source, excluding VCS/dependency/build caches.
    # Do not rm -rf the target first: local Docker builds may have left
    # root-owned cache directories under infra/_build_deps.
    copy_workspace_source "${ws_repo}" "${target}" "${repo_name}"
    verify_build_context "${dir_name}" "${repo_name}" "${target}"
    touch "${target}/.exists"
  else
    echo "[prepare]  [warn] ${repo_name} not found at ${ws_repo}; creating stub"
    mkdir -p "${target}"
    cat > "${target}/.no-source" <<-STUB_EOF
		# This directory is a stub. Source was not available.
		# Run scripts/prepare-staging-build-context.sh with the correct --workspace,
		# or ensure the repo exists at: ${ws_repo}
		# 
		# In CI, actions/checkout should place source here before running compose build.
		STUB_EOF
    touch "${target}/.exists"
  fi
done

# Always ensure .exists at the dir root so compose file validation never fails
touch "${BUILD_DEPS}/.exists"

echo "[prepare] Build context prepared. Contents:"
find "${BUILD_DEPS}" -maxdepth 2 \
  \( -name '.exists' -o -name 'go.mod' -o -name '.no-source' \) \
  | sort | sed 's/^/  /'
echo "[prepare] Done."
