#!/usr/bin/env bash
# Smoke tests for autonomy-closed-loop-audit.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${SCRIPT_DIR}/autonomy-closed-loop-audit.sh"
SANDBOX=""
ORIG_DIR="$(pwd)"
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label}"
    echo "    Expected: ${expected}"
    echo "    Actual:   ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label}"
    echo "    Missing: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/autonomy-audit-smoke.XXXXXX")"
  mkdir -p "${SANDBOX}/livemask-docs/docs/development/tasks"
  mkdir -p "${SANDBOX}/livemask-docs/docs/development/dispatch-packets"
  mkdir -p "${SANDBOX}/livemask-docs/docs/development/review-contracts"
  mkdir -p "${SANDBOX}/livemask-backend"

  cd "${SANDBOX}/livemask-backend"
  git init --initial-branch=dev >/dev/null
  git config user.email "smoke@test.livemask"
  git config user.name "Smoke Test"
  printf '# backend smoke\n' > README.md
  git add README.md
  git commit -m "initial dev" --no-gpg-sign >/dev/null

  cd "${SANDBOX}/livemask-docs"
  git init --initial-branch=dev >/dev/null
  git config user.email "smoke@test.livemask"
  git config user.name "Smoke Test"
}

write_healthy_docs() {
  cd "${SANDBOX}/livemask-docs"
  printf '# TASK-SMOKE-AUDIT-READY-OK\n' > docs/development/tasks/TASK-SMOKE-AUDIT-READY-OK.md
  printf '# TASK-SMOKE-AUDIT-DONE-OK\n' > docs/development/tasks/TASK-SMOKE-AUDIT-DONE-OK.md
  printf '{"task_id":"TASK-SMOKE-AUDIT-READY-OK","repo":"livemask-backend","assigned_to":"claude-executor"}\n' > docs/development/dispatch-packets/TASK-SMOKE-AUDIT-READY-OK.json
  python3 - <<'PY'
import json, pathlib
ledger = {
    "modules": [{
        "module_id": "BACKEND-SMOKE",
        "tasks": [
            {
                "task_id": "TASK-SMOKE-AUDIT-READY-OK",
                "repo": "livemask-backend",
                "status": "ready",
                "task_doc": "docs/development/tasks/TASK-SMOKE-AUDIT-READY-OK.md",
                "issue": "https://github.com/MyAiDevs/livemask-backend/issues/1",
                "blocked_by": []
            },
            {
                "task_id": "TASK-SMOKE-AUDIT-DONE-OK",
                "repo": "livemask-backend",
                "status": "completed",
                "task_doc": "docs/development/tasks/TASK-SMOKE-AUDIT-DONE-OK.md",
                "issue": "https://github.com/MyAiDevs/livemask-backend/issues/2",
                "validation": "go test ./... -count=1 PASS; backend smoke PASS",
                "dev_merge_commit": "abc1234",
                "remote_dev_ref": "abc1234",
                "blocked_by": []
            }
        ]
    }]
}
review = {
    "schema_version": 2,
    "task_id": "TASK-SMOKE-AUDIT-DONE-OK",
    "repo": "livemask-backend",
    "state": "approved",
    "rounds": [{
        "round": 1,
        "qa": {"passed": True, "verdict": "QA_PASSED"},
        "leader": {"verdict": "approved"}
    }]
}
pathlib.Path("docs/development/task-state-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
pathlib.Path("docs/development/review-contracts/TASK-SMOKE-AUDIT-DONE-OK-review.json").write_text(json.dumps(review, indent=2) + "\n")
PY
}

write_broken_docs() {
  cd "${SANDBOX}/livemask-docs"
  printf '# TASK-SMOKE-AUDIT-READY-NO-DISPATCH\n' > docs/development/tasks/TASK-SMOKE-AUDIT-READY-NO-DISPATCH.md
  printf '# TASK-SMOKE-AUDIT-DONE-BAD\n' > docs/development/tasks/TASK-SMOKE-AUDIT-DONE-BAD.md
  python3 - <<'PY'
import json, pathlib
ledger = {
    "modules": [{
        "module_id": "BACKEND-SMOKE",
        "tasks": [
            {
                "task_id": "TASK-SMOKE-AUDIT-READY-NO-DISPATCH",
                "repo": "livemask-backend",
                "status": "ready",
                "task_doc": "docs/development/tasks/TASK-SMOKE-AUDIT-READY-NO-DISPATCH.md",
                "issue": "https://github.com/MyAiDevs/livemask-backend/issues/3",
                "blocked_by": []
            },
            {
                "task_id": "TASK-SMOKE-AUDIT-DONE-BAD",
                "repo": "livemask-backend",
                "status": "completed",
                "task_doc": "docs/development/tasks/TASK-SMOKE-AUDIT-DONE-BAD.md",
                "issue": "https://github.com/MyAiDevs/livemask-backend/issues/4",
                "validation": "bash scripts/check-docs.sh PASS",
                "blocked_by": []
            }
        ]
    }]
}
pathlib.Path("docs/development/task-state-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
PY
}

teardown_sandbox() {
  cd "${ORIG_DIR}"
  if [[ -n "${SANDBOX}" && -d "${SANDBOX}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

trap teardown_sandbox EXIT

setup_sandbox

echo "Running autonomy closed-loop audit smoke..."
write_healthy_docs
healthy="$(LIVEMASK_ROOT="${SANDBOX}" DOCS_DIR="${SANDBOX}/livemask-docs" bash "${AUDIT}" --strict)"
healthy_status="$(printf '%s' "${healthy}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
assert_eq "healthy fixture passes" "pass" "${healthy_status}"

write_broken_docs
set +e
broken="$(LIVEMASK_ROOT="${SANDBOX}" DOCS_DIR="${SANDBOX}/livemask-docs" bash "${AUDIT}" --strict 2>&1)"
broken_rc=$?
set -e
assert_eq "broken fixture fails strict" "1" "${broken_rc}"
assert_contains "detects missing dispatch" "${broken}" "runtime_task_without_dispatch"
assert_contains "detects missing completion evidence" "${broken}" "completed_task_missing_evidence"
assert_contains "detects missing review" "${broken}" "completed_task_missing_review"
assert_contains "detects docs-only validation" "${broken}" "runtime_task_docs_only_validation"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "autonomy closed-loop audit smoke failed: ${FAIL_COUNT} failed, ${PASS_COUNT} passed"
  exit 1
fi

echo "autonomy closed-loop audit smoke passed: ${PASS_COUNT} passed, 0 failed"
