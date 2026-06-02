#!/usr/bin/env bash
# Deterministic smoke test for target-repo-task-bridge.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/target-repo-task-bridge.sh"
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

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "${path}" ]]; then
    echo "  PASS: ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: ${label} missing ${path}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/target-repo-bridge-smoke.XXXXXX")"
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
  printf '# TASK-SMOKE-TARGET-001\n' > docs/development/tasks/TASK-SMOKE-TARGET-001.md
  printf '{"task_id":"TASK-SMOKE-TARGET-001","repo":"livemask-backend"}\n' > docs/development/dispatch-packets/dispatch-TASK-SMOKE-TARGET-001.json
  python3 - <<'PY'
import json, pathlib
ledger = {
    "modules": [{
        "module_id": "BACKEND-SMOKE",
        "tasks": [{
            "task_id": "TASK-SMOKE-TARGET-001",
            "repo": "livemask-backend",
            "status": "ready",
            "priority": "P1",
            "task_doc": "docs/development/tasks/TASK-SMOKE-TARGET-001.md",
            "issue": "https://github.com/MyAiDevs/livemask-backend/issues/1",
            "validation": "go test ./... -count=1",
            "blocked_by": [],
            "notes": "smoke task"
        }]
    }]
}
pathlib.Path("docs/development/task-state-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
PY
  git add docs
  git commit -m "seed smoke docs" --no-gpg-sign >/dev/null
}

teardown_sandbox() {
  cd "${ORIG_DIR}"
  if [[ -n "${SANDBOX}" && -d "${SANDBOX}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

trap teardown_sandbox EXIT

setup_sandbox

echo "Running target repo bridge smoke..."
LIVEMASK_ROOT="${SANDBOX}" DOCS_DIR="${SANDBOX}/livemask-docs" \
  bash "${BRIDGE}" --task-id TASK-SMOKE-TARGET-001 --repo livemask-backend >/tmp/target-repo-bridge-smoke.out

backend="${SANDBOX}/livemask-backend"
branch="$(git -C "${backend}" branch --show-current)"
assert_eq "target branch created" "task/TASK-SMOKE-TARGET-001" "${branch}"
assert_file_exists "execution plan written" "${backend}/.cursor-worker/execution-plan-TASK-SMOKE-TARGET-001.json"
assert_file_exists "current task written" "${backend}/.cursor-worker/current-task.json"
assert_file_exists "brief written" "${backend}/.cursor-worker/briefs/TASK-SMOKE-TARGET-001.md"
assert_file_exists "worker state written" "${backend}/.cursor-worker-state.json"

repo_in_plan="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repo"])' "${backend}/.cursor-worker/current-task.json")"
assert_eq "plan repo is target repo" "livemask-backend" "${repo_in_plan}"

docs_dirty="$(git -C "${SANDBOX}/livemask-docs" status --porcelain | wc -l | tr -d ' ')"
assert_eq "docs repo untouched" "0" "${docs_dirty}"

backend_dirty="$(git -C "${backend}" status --porcelain | wc -l | tr -d ' ')"
assert_eq "target local worker files excluded" "0" "${backend_dirty}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "target-repo-task-bridge smoke failed: ${FAIL_COUNT} failed, ${PASS_COUNT} passed"
  exit 1
fi

echo "target-repo-task-bridge smoke passed: ${PASS_COUNT} passed, 0 failed"
