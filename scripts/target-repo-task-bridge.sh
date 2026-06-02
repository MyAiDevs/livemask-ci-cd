#!/usr/bin/env bash
# Prepare a docs-assigned task inside its target implementation repository.
#
# This is the hard handoff between the control plane (livemask-docs /
# livemask-ci-cd) and repo-local development. It does not write product code.
# It resolves the task, enters the target repo, creates or switches to the task
# branch, and writes machine-readable worker state plus an implementation brief.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_CD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${DOCS_DIR:-${LIVEMASK_ROOT}/livemask-docs}"
TASK_ID=""
TARGET_REPO=""
MODE="prepare"
ALLOW_DIRTY="false"
ALLOW_CURRENT_BRANCH="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --task-id TASK-ID [--repo REPO] [options]

Options:
  --task-id ID              Task id from docs/development/task-state-ledger.json
  --repo NAME               Target repo; resolved from ledger when omitted
  --mode prepare            Prepare branch/state/brief (default)
  --allow-dirty             Allow preparing a dirty target repo
  --allow-current-branch    Do not force/switch to task/TASK-ID
  --docs-dir PATH           livemask-docs path (default: ${DOCS_DIR})
  --livemask-root PATH      LiveMask workspace root (default: ${LIVEMASK_ROOT})
  --help                    Show this help

Outputs:
  .cursor-worker/current-task.json
  .cursor-worker/execution-plan-TASK-ID.json
  .cursor-worker/briefs/TASK-ID.md
  .cursor-worker-state.json
USAGE
}

die() {
  echo "target-repo-task-bridge: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --repo) TARGET_REPO="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY="true"; shift ;;
    --allow-current-branch) ALLOW_CURRENT_BRANCH="true"; shift ;;
    --docs-dir) DOCS_DIR="${2:-}"; shift 2 ;;
    --livemask-root) LIVEMASK_ROOT="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "${TASK_ID}" ]] || die "--task-id is required"
[[ "${MODE}" == "prepare" ]] || die "unsupported mode: ${MODE}"
[[ -d "${DOCS_DIR}" ]] || die "docs dir not found: ${DOCS_DIR}"

LEDGER_PATH="${DOCS_DIR}/docs/development/task-state-ledger.json"
[[ -f "${LEDGER_PATH}" ]] || die "ledger not found: ${LEDGER_PATH}"

TASK_CONTEXT="$(
  TASK_ID="${TASK_ID}" TARGET_REPO="${TARGET_REPO}" DOCS_DIR="${DOCS_DIR}" LEDGER_PATH="${LEDGER_PATH}" python3 <<'PY'
import glob, json, os, pathlib, sys

task_id = os.environ["TASK_ID"]
requested_repo = os.environ.get("TARGET_REPO", "")
docs_dir = pathlib.Path(os.environ["DOCS_DIR"])
ledger_path = pathlib.Path(os.environ["LEDGER_PATH"])

ledger = json.loads(ledger_path.read_text())
entry = None
module_id = ""
for module in ledger.get("modules", []):
    for task in module.get("tasks", []):
        if task.get("task_id") == task_id:
            entry = task
            module_id = module.get("module_id", "")
            break
    if entry:
        break

if not entry:
    print(json.dumps({"error": f"task not found in ledger: {task_id}"}))
    sys.exit(2)

repo = requested_repo or entry.get("repo") or entry.get("owner_repo") or ""
if requested_repo and entry.get("repo") and requested_repo != entry.get("repo"):
    print(json.dumps({
        "error": "requested repo does not match ledger",
        "requested_repo": requested_repo,
        "ledger_repo": entry.get("repo"),
    }))
    sys.exit(3)

task_doc = entry.get("task_doc") or f"docs/development/tasks/{task_id}.md"
task_doc_abs = docs_dir / task_doc
dispatch_matches = sorted(glob.glob(str(docs_dir / "docs/development/dispatch-packets" / f"*{task_id}*.json")))
review_matches = sorted(glob.glob(str(docs_dir / "docs/development/review-contracts" / f"*{task_id}*.json")))

validation_by_repo = {
    "livemask-docs": ["bash scripts/check-docs.sh", "git diff --check"],
    "livemask-ci-cd": ["bash scripts/validate-workflow-syntax.sh", "bash scripts/validate-role-engine-flow.sh", "bash scripts/worker-harness-smoke.sh", "git diff --check"],
    "livemask-backend": ["go test ./... -count=1", "go build ./..."],
    "livemask-admin": ["npm test", "npm run build"],
    "livemask-website": ["npm run build"],
    "livemask-app": ["flutter analyze", "flutter test"],
    "livemask-nodeagent": ["go test ./... -count=1", "go build ./cmd/nodeagent"],
    "livemask-job-service": ["go test ./... -count=1", "go build ./cmd/job-service"],
}

payload = {
    "task_id": task_id,
    "repo": repo,
    "module_id": module_id,
    "status": entry.get("status", ""),
    "priority": entry.get("priority", ""),
    "issue": entry.get("issue", ""),
    "task_doc": str(task_doc_abs),
    "task_doc_exists": task_doc_abs.exists(),
    "dispatch_packet": dispatch_matches[0] if dispatch_matches else "",
    "review_contract": review_matches[0] if review_matches else "",
    "ledger_validation": entry.get("validation", ""),
    "validation_commands": validation_by_repo.get(repo, ["git diff --check"]),
    "blocked_by": entry.get("blocked_by", []),
    "notes": entry.get("notes", ""),
}
print(json.dumps(payload, ensure_ascii=False))
PY
)" || die "failed to resolve task context"

context_error="$(printf '%s' "${TASK_CONTEXT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error",""))' 2>/dev/null || true)"
[[ -z "${context_error}" ]] || die "${context_error}"

TARGET_REPO="$(printf '%s' "${TASK_CONTEXT}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("repo",""))')"
[[ -n "${TARGET_REPO}" ]] || die "target repo is empty for ${TASK_ID}"

case "${TARGET_REPO}" in
  livemask-docs|livemask-ci-cd|livemask-backend|livemask-admin|livemask-website|livemask-app|livemask-nodeagent|livemask-job-service) ;;
  *) die "unknown target repo: ${TARGET_REPO}" ;;
esac

REPO_DIR="${LIVEMASK_ROOT}/${TARGET_REPO}"
[[ -d "${REPO_DIR}/.git" ]] || die "target repo git dir not found: ${REPO_DIR}"

if [[ "${ALLOW_DIRTY}" != "true" ]]; then
  dirty_count="$(git -C "${REPO_DIR}" status --porcelain | wc -l | tr -d ' ')"
  [[ "${dirty_count}" == "0" ]] || die "target repo is dirty (${dirty_count} paths): ${REPO_DIR}"
fi

TASK_BRANCH="task/${TASK_ID}"
if [[ "${ALLOW_CURRENT_BRANCH}" != "true" ]]; then
  if git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${TASK_BRANCH}"; then
    git -C "${REPO_DIR}" switch "${TASK_BRANCH}" >/dev/null
  else
    if git -C "${REPO_DIR}" show-ref --verify --quiet refs/heads/dev; then
      git -C "${REPO_DIR}" switch dev >/dev/null
    fi
    git -C "${REPO_DIR}" switch -c "${TASK_BRANCH}" >/dev/null
  fi
fi

CURRENT_BRANCH="$(git -C "${REPO_DIR}" branch --show-current)"
CURRENT_HEAD="$(git -C "${REPO_DIR}" rev-parse --short HEAD)"
PREPARED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "${REPO_DIR}/.cursor-worker/briefs"
mkdir -p "${REPO_DIR}/.git/info"
touch "${REPO_DIR}/.git/info/exclude"
for local_only in ".cursor-worker/" ".cursor-worker-state.json"; do
  if ! grep -qxF "${local_only}" "${REPO_DIR}/.git/info/exclude"; then
    printf '%s\n' "${local_only}" >> "${REPO_DIR}/.git/info/exclude"
  fi
done

TASK_CONTEXT="${TASK_CONTEXT}" REPO_DIR="${REPO_DIR}" TASK_BRANCH="${TASK_BRANCH}" CURRENT_BRANCH="${CURRENT_BRANCH}" CURRENT_HEAD="${CURRENT_HEAD}" PREPARED_AT="${PREPARED_AT}" CI_CD_DIR="${CI_CD_DIR}" python3 <<'PY'
import json, os, pathlib, textwrap

ctx = json.loads(os.environ["TASK_CONTEXT"])
repo_dir = pathlib.Path(os.environ["REPO_DIR"])
task_id = ctx["task_id"]
branch = os.environ["CURRENT_BRANCH"]
expected_branch = os.environ["TASK_BRANCH"]
head = os.environ["CURRENT_HEAD"]
prepared_at = os.environ["PREPARED_AT"]
ci_cd_dir = os.environ["CI_CD_DIR"]

plan = {
    "schema_version": 1,
    "prepared_at": prepared_at,
    "task_id": task_id,
    "repo": ctx["repo"],
    "repo_dir": str(repo_dir),
    "branch": branch,
    "expected_branch": expected_branch,
    "head": head,
    "source": "target-repo-task-bridge",
    "must_read": [p for p in [ctx.get("task_doc"), ctx.get("dispatch_packet"), ctx.get("review_contract")] if p],
    "issue": ctx.get("issue", ""),
    "module_id": ctx.get("module_id", ""),
    "validation_commands": ctx.get("validation_commands", []),
    "completion_gates": [
        "implementation_changes_exist_in_target_repo",
        "repo_native_validation_passes",
        "worker_harness_review_packet_written",
        "codex_approval_artifact_exists_before_commit",
        "dev_merge_commit_and_remote_dev_ref_recorded",
        "completion_report_dispatched_and_acknowledged",
    ],
    "forbidden_actions": [
        "edit_livemask_docs_as_primary_implementation_for_runtime_task",
        "mark_ledger_completed_before_dev_merge",
        "skip_repo_native_validation",
        "claim_done_without_review_packet",
    ],
}

state = {
    "current_task": {
        "task_id": task_id,
        "target_repo": ctx["repo"],
        "branch": branch,
        "phase": "implementing",
        "prepared_at": prepared_at,
        "execution_plan": f".cursor-worker/execution-plan-{task_id}.json",
        "brief": f".cursor-worker/briefs/{task_id}.md",
    }
}

brief_lines = [
    f"# {task_id}",
    "",
    f"- Repo: {ctx['repo']}",
    f"- Branch: {branch}",
    f"- Prepared: {prepared_at}",
    f"- Issue: {ctx.get('issue') or 'none'}",
    f"- Task doc: {ctx.get('task_doc')}",
    f"- Dispatch packet: {ctx.get('dispatch_packet') or 'none'}",
    f"- Review contract: {ctx.get('review_contract') or 'none'}",
    "",
    "## Required Context Intake",
    "",
    "- Read every path listed in `.cursor-worker/current-task.json` and the execution plan before editing.",
    "- Implement inside this target repo first. Use docs updates only for contracts or completion reporting.",
    "- Reuse repo-native patterns before adding helpers or abstractions.",
    "",
    "## Validation",
    "",
]
for cmd in ctx.get("validation_commands", []):
    brief_lines.append(f"- `{cmd}`")

brief_lines.extend([
    "",
    "## Worker Harness",
    "",
    "```bash",
    f"cd {repo_dir}",
    f"export WORKER_HARNESS_TASK_ID={task_id}",
    "export CURSOR_WORKER_MODE=implement-for-review",
    "export WORKER_HARNESS_VALIDATION_CMDS=$(python3 - <<'PY'",
    "import json",
    f"print(json.dumps({ctx.get('validation_commands', [])!r}, ensure_ascii=True))",
    "PY",
    ")",
    f"source {ci_cd_dir}/scripts/lib/worker-harness.sh",
    "worker_harness_init",
    "worker_harness_require_mode implement-for-review",
    "worker_harness_run_review_gate",
    "```",
    "",
    "## Done Means",
    "",
])
for gate in plan["completion_gates"]:
    brief_lines.append(f"- {gate}")

(repo_dir / ".cursor-worker" / f"execution-plan-{task_id}.json").write_text(json.dumps(plan, indent=2, ensure_ascii=False) + "\n")
(repo_dir / ".cursor-worker" / "current-task.json").write_text(json.dumps(plan, indent=2, ensure_ascii=False) + "\n")
(repo_dir / ".cursor-worker-state.json").write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n")
(repo_dir / ".cursor-worker" / "briefs" / f"{task_id}.md").write_text("\n".join(brief_lines) + "\n")
print(json.dumps({
    "status": "prepared",
    "task_id": task_id,
    "repo": ctx["repo"],
    "repo_dir": str(repo_dir),
    "branch": branch,
    "execution_plan": str(repo_dir / ".cursor-worker" / f"execution-plan-{task_id}.json"),
    "brief": str(repo_dir / ".cursor-worker" / "briefs" / f"{task_id}.md"),
}, indent=2, ensure_ascii=False))
PY
