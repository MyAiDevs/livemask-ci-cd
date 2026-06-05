#!/usr/bin/env bash
# verify-diff-scope.sh — gate that changed files match claimed task scope.
#
# Usage:
#   bash scripts/lib/verify-diff-scope.sh --repo PATH --task-id TASK-XXXX
#
# Returns 0 if scope matches, 2 if mismatch (blocks completion).
# Called automatically by dev-merge-guard.sh pre-commit hook.
set -euo pipefail

repo=""
task_id=""
verbose=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --task-id) task_id="$2"; shift 2 ;;
    --verbose) verbose=true; shift ;;
    *) shift ;;
  esac
done

[[ -n "${repo}" ]] || { echo "DIFF-SCOPE: --repo required"; exit 2; }
[[ -n "${task_id}" ]] || { echo "DIFF-SCOPE: --task-id required"; exit 2; }

repo_name="$(basename "${repo}")"
changed=$(git -C "${repo}" diff --name-only HEAD~1..HEAD 2>/dev/null || git -C "${repo}" diff --name-only --cached 2>/dev/null || echo "")

if [[ -z "${changed}" ]]; then
  echo "DIFF-SCOPE: no changed files — skipping scope check"
  exit 0
fi

# ── Scope mapping: task keywords → expected file paths ────────────────
# Each regex maps task-id patterns to expected file globs.
# If NO pattern matches, the gate passes (unknown task types are not blocked).
# If a pattern matches but files don't cover the expected paths, the gate fails.

mismatch=0
task_lower=$(echo "${task_id}" | tr '[:upper:]' '[:lower:]')

check_path() {
  local label="$1"; shift
  local found=0
  for pattern in "$@"; do
    if echo "${changed}" | grep -q "${pattern}"; then
      found=1
      break
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    echo "DIFF-SCOPE: ${task_id} claims ${label} but no files match: $*"
    mismatch=1
  else
    ${verbose} && echo "DIFF-SCOPE: ${label} ✅"
  fi
}

# Admin billing center
if echo "${task_lower}" | grep -qE "billing|billing-center|finance-billing"; then
  check_path "admin billing pages" "src/app/admin/billing/" "src/lib/billing-api" "src/hooks/use-billing" "src/types/billing"
fi

# Admin dashboard / KPI
if echo "${task_lower}" | grep -qE "dashboard|executive-kpi"; then
  check_path "admin dashboard" "src/app/admin/page.tsx\|src/app/admin/dashboard/"
fi

# Admin commerce / market
if echo "${task_lower}" | grep -qE "commerce|market|points-market|package"; then
  check_path "admin commerce pages" "src/app/admin/packages/\|src/app/admin/points-market/\|src/lib/commerce-api\|src/types/commerce\|e2e/"
fi

# Admin growth / ambassador rules
if echo "${task_lower}" | grep -qE "ambassador|growth|reward-rule|kpi-penalty"; then
  check_path "admin growth pages" "src/app/admin/growth/\|src/lib/ambassador-rules-api\|src/types/growth"
fi

# Admin system settings
if echo "${task_lower}" | grep -qE "system-settings|settings-gap|data-retention|security-policy|webhook-policy"; then
  check_path "admin settings" "src/app/admin/settings/\|src/lib/settings-api\|src/hooks/use-settings"
fi

# Backend billing
if echo "${task_lower}" | grep -qE "billing|billing-center" && echo "${repo_name}" | grep -q "backend"; then
  check_path "backend billing" "internal/billing/"
fi

# Backend growth / reward
if echo "${task_lower}" | grep -qE "growth|reward|kpi|penalty|attribution" && echo "${repo_name}" | grep -q "backend"; then
  check_path "backend growth" "internal/growth/"
fi

# Backend system settings
if echo "${task_lower}" | grep -qE "system-settings|data-retention|security-policy|webhook-policy" && echo "${repo_name}" | grep -q "backend"; then
  check_path "backend systemsettings" "internal/systemsettings/"
fi

# CI/CD smoke
if echo "${task_lower}" | grep -qE "smoke|smoke-test|ci-cd"; then
  check_path "CI/CD scripts" "scripts/.*smoke" "scripts/.*\.sh"
fi

if [[ "${mismatch}" -eq 1 ]]; then
  echo ""
  echo "DIFF-SCOPE: FAILED — task ${task_id} claims scope not covered by changed files."
  echo "Changed files:"
  echo "${changed}" | sed 's/^/  /'
  echo ""
  echo "Either:"
  echo "  1. Add the missing files to this commit"
  echo "  2. Update the task-id to match actual scope"
  echo "  3. Add a scope exception comment to the commit message"
  exit 2
fi

echo "DIFF-SCOPE: PASS — ${task_id} files match claimed scope"
exit 0
