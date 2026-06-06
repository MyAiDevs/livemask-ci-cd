#!/usr/bin/env bash
set -euo pipefail

# TASK-CICD-WORKSPACE-PATH-MIGRATION-001
# Local dev environment status report — workspace path verification + runtime overview.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"

LOCAL_COMPOSE_LIB="${SCRIPT_DIR}/lib/local-compose.sh"
if [[ -f "${LOCAL_COMPOSE_LIB}" ]]; then
  # shellcheck source=scripts/lib/local-compose.sh
  source "${LOCAL_COMPOSE_LIB}"
fi

# Source workspace check if available
BASE_SERVICE="${SCRIPT_DIR}/lib/base_service.sh"
if [[ -f "${BASE_SERVICE}" ]]; then
  # shellcheck source=scripts/lib/base_service.sh
  source "${BASE_SERVICE}"
fi

echo "============================================"
echo " Local Dev Status Report"
echo "============================================"
echo ""
echo "--- Environment ---"
echo "  PWD:                     $PWD"
echo "  REPO_DIR:                ${REPO_DIR}"
echo "  LIVEMASK_WORKSPACE_ROOT: ${LIVEMASK_WORKSPACE_ROOT}"
echo ""

# Git info
echo "--- Git Info ---"
if git rev-parse --git-dir &>/dev/null; then
  echo "  Branch:   $(git branch --show-current 2>/dev/null || echo 'unknown')"
  echo "  Remote:   $(git remote get-url origin 2>/dev/null || echo 'none')"
  echo "  Status:"
  git status --short 2>/dev/null || echo "    (clean)"
else
  echo "  (not a git repository)"
fi
echo ""

# Repo presence
echo "--- Repositories under ${LIVEMASK_WORKSPACE_ROOT} ---"
for repo in livemask-docs livemask-backend livemask-admin livemask-website \
            livemask-app livemask-nodeagent livemask-job-service livemask-ci-cd; do
  if [[ -d "${LIVEMASK_WORKSPACE_ROOT}/${repo}/.git" ]]; then
    echo "  * ${repo}: present"
  else
    echo "  - ${repo}: missing"
  fi
done
echo ""

# Docker
echo "--- Docker ---"
if command -v docker &>/dev/null; then
  echo "  CLI: available"
  if docker info &>/dev/null; then
    echo "  Daemon: running"
  else
    echo "  Daemon: not running or permission denied"
  fi
else
  echo "  docker CLI: not found"
fi
echo ""

# Runtime containers (optional)
echo "--- Runtime Containers ---"
if command -v docker &>/dev/null && docker info &>/dev/null; then
  local_compose="${REPO_DIR}/infra/docker-compose.local.yml"
  if [[ -f "${local_compose}" ]]; then
    local compose_file_args=(-f "${local_compose}")
    local hot_file
    hot_file="$(local_compose_hot_file "${REPO_DIR}")"
    if local_compose_hot_reload_enabled && [[ -f "${hot_file}" ]]; then
      compose_file_args+=(-f "${hot_file}")
      echo "  Compose files: ${local_compose} + docker-compose.hot.yml (default hot reload)"
    else
      echo "  Compose file: ${local_compose}"
    fi
    docker compose "${compose_file_args[@]}" ps --services --filter "status=running" 2>/dev/null || echo "  (compose status unavailable)"
  else
    echo "  Compose file not found: ${local_compose}"
  fi
else
  echo "  (docker info unavailable)"
fi
echo ""
echo "============================================"
