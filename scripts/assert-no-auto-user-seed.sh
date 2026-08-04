#!/usr/bin/env bash
# Fail if deploy automation reintroduces seed-dev-test-data.sh.
# Manual SSH / local QA runs of the script are allowed; CI deploy must not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PATTERN='seed-dev-test-data\.sh'
SCAN_PATHS=(
  .github/workflows
  scripts/deploy-service.sh
  scripts/deploy-external-nodeagents.sh
)

hits=()
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  # Allow documentation / comments that forbid auto-seed.
  case "${line}" in
    *'#'*|*'must not'*|*'never'*|*'manual'*|*'do not'*|*"don't"*|*"Don't"*)
      continue
      ;;
  esac
  hits+=("${line}")
done < <(
  for path in "${SCAN_PATHS[@]}"; do
    [[ -e "${path}" ]] || continue
    if [[ -d "${path}" ]]; then
      grep -RInE "${PATTERN}" "${path}" 2>/dev/null || true
    else
      grep -nE "${PATTERN}" "${path}" 2>/dev/null || true
    fi
  done
)

if ((${#hits[@]} > 0)); then
  echo "[assert-no-auto-user-seed] ERROR: seed-dev-test-data.sh must not be invoked by deploy automation:" >&2
  printf '  %s\n' "${hits[@]}" >&2
  echo "[assert-no-auto-user-seed] Run the seed script manually via SSH only." >&2
  exit 1
fi

echo "[assert-no-auto-user-seed] OK — deploy automation does not invoke seed-dev-test-data.sh"
