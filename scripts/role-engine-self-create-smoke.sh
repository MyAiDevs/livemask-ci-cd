#!/usr/bin/env bash
# Verify the role engine keeps a real idle self-task creation path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_ENGINE="${SCRIPT_DIR}/claude-loop-role-engine.sh"

pass_count=0
fail_count=0

pass() {
  echo "  PASS: $*"
  pass_count=$((pass_count + 1))
}

fail() {
  echo "  FAIL: $*" >&2
  fail_count=$((fail_count + 1))
}

require_present() {
  local label="$1" pattern="$2"
  if grep -q -- "${pattern}" "${ROLE_ENGINE}"; then
    pass "${label}"
  else
    fail "${label}"
  fi
}

require_absent() {
  local label="$1" pattern="$2"
  if grep -q -- "${pattern}" "${ROLE_ENGINE}"; then
    fail "${label}"
  else
    pass "${label}"
  fi
}

echo "Running role-engine self-create smoke..."

if bash -n "${ROLE_ENGINE}"; then
  pass "role-engine shell syntax"
else
  fail "role-engine shell syntax"
fi

require_present "idle self-create function exists" "self_create_tasks_when_idle()"
require_present "idle path invokes self-create function" "self_create_tasks_when_idle \"\${pkt_count}\""
require_present "closed-loop debt creates docs task" "PM-CLOSED-LOOP-DEBT"
require_present "closed-loop audit is a self-create source" "autonomy-closed-loop-audit.sh"
require_present "contract gap remains a self-create source" "Implement Ready contract gap"
require_present "findings file remains a self-create source" "FINDINGS_FILE"
require_present "issue URL guard remains enforced" "missing GitHub issue URL after issue guard"
require_present "auto task ledger module reopens when ready task is added" "module\\['overall_status'\\] = 'partial'"
require_present "failed docs landing removes generated task doc" 'rm -f "${task_doc}" "${dp_file}"'
require_present "docs auto-create refreshes dev before merge" "git pull --ff-only origin dev"

require_absent "old PM-3 no-auto-create instruction removed" "report Ready contract gaps for triage; do NOT auto-create"
require_absent "old PM-3 NOT auto-creating banner removed" "NOT auto-creating"
require_absent "broken inline Python fallback removed" "task creation skipped or failed"
require_absent "ledger issue refs are not accepted as new TASK-AUTO issue linkage" "or d.get('ledger_issue_refs')"
if awk '/^self_create_tasks_when_idle\(\)/,/^}/' "${ROLE_ENGINE}" | grep -q "| while IFS"; then
  fail "self-create while loops do not run in pipeline subshells"
else
  pass "self-create while loops do not run in pipeline subshells"
fi

if [[ "${fail_count}" -ne 0 ]]; then
  echo "role-engine self-create smoke failed: ${pass_count} passed, ${fail_count} failed" >&2
  exit 1
fi

echo "role-engine self-create smoke passed: ${pass_count} passed, ${fail_count} failed"
