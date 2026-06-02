#!/usr/bin/env bash
# Audit the autonomous development loop for evidence and handoff gaps.
#
# This script is intentionally read-only. It turns the LiveMask control-plane
# truth sources into a machine-readable report so the role engine can refuse
# fake progress before it starts reasoning from stale or incomplete state.

set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${DOCS_DIR:-${LIVEMASK_ROOT}/livemask-docs}"
CI_CD_DIR="${CI_CD_DIR:-${LIVEMASK_ROOT}/livemask-ci-cd}"
OUTFILE=""
STRICT="false"
SUMMARY_ONLY="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --docs-dir PATH       livemask-docs path (default: ${DOCS_DIR})
  --livemask-root PATH  LiveMask workspace root (default: ${LIVEMASK_ROOT})
  --output PATH         Write JSON report to PATH
  --strict              Exit non-zero when blocking issues exist
  --summary             Print compact text summary instead of JSON
  --help                Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docs-dir) DOCS_DIR="${2:-}"; shift 2 ;;
    --livemask-root) LIVEMASK_ROOT="${2:-}"; shift 2 ;;
    --output) OUTFILE="${2:-}"; shift 2 ;;
    --strict) STRICT="true"; shift ;;
    --summary) SUMMARY_ONLY="true"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "autonomy-closed-loop-audit: unknown option: $1" >&2; exit 2 ;;
  esac
done

REPORT="$(
  LIVEMASK_ROOT="${LIVEMASK_ROOT}" DOCS_DIR="${DOCS_DIR}" CI_CD_DIR="${CI_CD_DIR}" python3 <<'PY'
import glob
import json
import os
import pathlib
import subprocess
import time

root = pathlib.Path(os.environ["LIVEMASK_ROOT"])
docs = pathlib.Path(os.environ["DOCS_DIR"])
ci_cd = pathlib.Path(os.environ["CI_CD_DIR"])
ledger_path = docs / "docs/development/task-state-ledger.json"
dispatch_dir = docs / "docs/development/dispatch-packets"
review_dir = docs / "docs/development/review-contracts"

runtime_repos = {
    "livemask-backend",
    "livemask-admin",
    "livemask-website",
    "livemask-app",
    "livemask-nodeagent",
    "livemask-job-service",
}
control_repos = {"livemask-docs", "livemask-ci-cd"}
canonical_repos = runtime_repos | control_repos
active_statuses = {
    "ready",
    "dispatched",
    "leased",
    "in_progress",
    "implementing",
    "revising",
    "under_review",
    "partial",
    "evidence_missing",
}
completion_statuses = {"completed", "completed_with_skip"}

issues = []
tasks = {}
repo_counts = {}
dispatch_packets = {}
review_contracts = {}

def add(severity, issue_type, task_id="", repo="", detail="", fix=""):
    issues.append({
        "severity": severity,
        "type": issue_type,
        "task_id": task_id,
        "repo": repo,
        "detail": detail,
        "fix": fix,
    })

def git(args, cwd):
    try:
        return subprocess.run(["git", "-C", str(cwd)] + args, text=True, capture_output=True, timeout=10)
    except Exception as exc:
        class R:
            returncode = 1
            stdout = ""
            stderr = str(exc)
        return R()

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        add("blocker", "json_unreadable", detail=f"{path}: {exc}", fix="repair malformed JSON before running the engine")
        return None

if not ledger_path.exists():
    add("blocker", "ledger_missing", detail=str(ledger_path), fix="restore docs/development/task-state-ledger.json")
    ledger = {}
else:
    ledger = read_json(ledger_path) or {}

seen = {}
for module in ledger.get("modules", []):
    module_id = module.get("module_id", "")
    for task in module.get("tasks", []):
        tid = task.get("task_id", "")
        repo = task.get("repo") or task.get("owner_repo") or ""
        if not tid:
            add("blocker", "task_id_missing", repo=repo, detail=f"module={module_id}", fix="assign a stable TASK-* id")
            continue
        if tid in seen:
            add("blocker", "duplicate_task_id", tid, repo, f"also seen in module {seen[tid]}", "merge duplicate ledger entries")
        seen[tid] = module_id
        tasks[tid] = {**task, "_module_id": module_id, "_repo": repo}
        repo_counts[repo] = repo_counts.get(repo, 0) + 1

for path in sorted(dispatch_dir.glob("*.json")) if dispatch_dir.exists() else []:
    if path.name == ".gitkeep":
        continue
    data = read_json(path)
    if not isinstance(data, dict):
        continue
    tid = data.get("task_id", "")
    repo = data.get("repo", "")
    if not tid:
        add("blocker", "dispatch_task_id_missing", detail=str(path), fix="repair or archive malformed dispatch packet")
        continue
    dispatch_packets[tid] = {"path": str(path), "data": data}
    task = tasks.get(tid)
    if not task:
        add("blocker", "dispatch_without_ledger_task", tid, repo, str(path), "create ledger task or archive packet")
        continue
    ledger_repo = task.get("_repo", "")
    if repo and ledger_repo and repo != ledger_repo:
        add("blocker", "dispatch_repo_mismatch", tid, repo, f"ledger_repo={ledger_repo} packet={path}", "make packet repo match ledger repo")
    if not data.get("assigned_to"):
        add("warning", "dispatch_missing_assignee", tid, repo, str(path), "set assigned_to so executor ownership is explicit")

for path in sorted(review_dir.glob("*-review.json")) if review_dir.exists() else []:
    data = read_json(path)
    if not isinstance(data, dict):
        continue
    tid = data.get("task_id") or path.name.removesuffix("-review.json")
    review_contracts[tid] = {"path": str(path), "data": data}
    if tid not in tasks:
        add("warning", "review_without_ledger_task", tid, data.get("repo", ""), str(path), "link review to a ledger task or archive stale review")

for tid, task in sorted(tasks.items()):
    repo = task.get("_repo", "")
    status = task.get("status", "")
    task_doc_rel = task.get("task_doc") or f"docs/development/tasks/{tid}.md"
    task_doc = docs / task_doc_rel

    if repo not in canonical_repos:
        add("blocker", "unknown_repo", tid, repo, "repo is not a canonical livemask repo", "decompose into a canonical repo task")
    if not task_doc.exists():
        add("blocker", "task_doc_missing", tid, repo, str(task_doc), "create task doc before dispatch or completion")

    if status in active_statuses and repo in runtime_repos:
        if tid not in dispatch_packets and status in {"ready", "dispatched", "leased", "in_progress", "implementing"}:
            add("blocker", "runtime_task_without_dispatch", tid, repo, f"status={status}", "create dispatch packet or archive false-ready task")
        if not str(task.get("issue", "")).strip():
            add("warning", "active_task_missing_issue", tid, repo, "no GitHub issue link", "link issue so execution has external audit trail")
        repo_dir = root / repo
        if not repo_dir.exists():
            add("blocker", "target_repo_missing", tid, repo, str(repo_dir), "clone or restore target repo before dispatch")
        elif status in {"implementing", "revising", "under_review"}:
            branch = f"task/{tid}"
            branch_check = git(["show-ref", "--verify", "--quiet", f"refs/heads/{branch}"], repo_dir)
            if branch_check.returncode != 0:
                add("blocker", "target_task_branch_missing", tid, repo, branch, "run target-repo-task-bridge.sh")
            current_plan = repo_dir / ".cursor-worker/current-task.json"
            if not current_plan.exists():
                add("blocker", "target_handoff_missing", tid, repo, str(current_plan), "run target-repo-task-bridge.sh")
            else:
                try:
                    plan = json.loads(current_plan.read_text(encoding="utf-8"))
                    if plan.get("task_id") != tid or plan.get("repo") != repo:
                        add("blocker", "target_handoff_wrong_task", tid, repo, str(current_plan), "regenerate handoff for the active task")
                except Exception as exc:
                    add("blocker", "target_handoff_unreadable", tid, repo, f"{current_plan}: {exc}", "regenerate handoff JSON")

    if status in completion_statuses:
        missing = []
        for key in ("validation", "dev_merge_commit", "remote_dev_ref"):
            if not str(task.get(key, "")).strip():
                missing.append(key)
        if missing:
            add("blocker", "completed_task_missing_evidence", tid, repo, ",".join(missing), "revert status or add real merge/validation evidence")
        review = review_contracts.get(tid)
        if not review:
            add("blocker", "completed_task_missing_review", tid, repo, "no review contract", "run executor_submit_review/qa_verify/leader_approve")
        else:
            rounds = review["data"].get("rounds") or []
            last = rounds[-1] if rounds else {}
            qa = last.get("qa", {})
            leader = last.get("leader", {})
            if not qa.get("passed"):
                add("blocker", "completed_task_without_qa_pass", tid, repo, review["path"], "run QA and keep task open until QA passes")
            if leader.get("verdict") not in {"approved", "APPROVED"} and review["data"].get("state") not in {"approved", "completed"}:
                add("warning", "completed_task_without_leader_approval", tid, repo, review["path"], "record leader approval before closure")
        validation = str(task.get("validation", "")).lower()
        if repo in runtime_repos and "check-docs" in validation and not any(x in validation for x in ("go test", "npm", "flutter", "smoke", "build")):
            add("blocker", "runtime_task_docs_only_validation", tid, repo, task.get("validation", ""), "run repo-native validation and smoke")

def issue_priority(issue):
    type_order = {
        "runtime_task_without_dispatch": 10,
        "target_handoff_missing": 11,
        "target_task_branch_missing": 12,
        "target_handoff_wrong_task": 13,
        "target_handoff_unreadable": 14,
        "completed_task_missing_evidence": 20,
        "runtime_task_docs_only_validation": 21,
        "completed_task_without_qa_pass": 22,
        "task_doc_missing": 30,
        "completed_task_missing_review": 40,
        "completed_task_without_leader_approval": 50,
    }
    severity_order = {"blocker": 0, "warning": 1}
    return (
        severity_order.get(issue.get("severity"), 9),
        type_order.get(issue.get("type"), 99),
        issue.get("repo", ""),
        issue.get("task_id", ""),
    )

issues.sort(key=issue_priority)
blockers = [i for i in issues if i["severity"] == "blocker"]
warnings = [i for i in issues if i["severity"] == "warning"]
active_blockers = [
    i for i in blockers
    if i["type"] in {
        "runtime_task_without_dispatch",
        "target_handoff_missing",
        "target_task_branch_missing",
        "target_handoff_wrong_task",
        "target_handoff_unreadable",
        "dispatch_without_ledger_task",
        "dispatch_repo_mismatch",
    }
]
completion_debt = [
    i for i in blockers
    if i["type"].startswith("completed_task_") or i["type"] == "runtime_task_docs_only_validation"
]
issue_type_counts = {}
for issue in issues:
    issue_type_counts[issue["type"]] = issue_type_counts.get(issue["type"], 0) + 1
report = {
    "schema_version": 1,
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": "fail" if blockers else ("warn" if warnings else "pass"),
    "summary": {
        "task_count": len(tasks),
        "repo_counts": repo_counts,
        "dispatch_packet_count": len(dispatch_packets),
        "review_contract_count": len(review_contracts),
        "blocker_count": len(blockers),
        "warning_count": len(warnings),
        "active_blocker_count": len(active_blockers),
        "completion_debt_count": len(completion_debt),
        "issue_type_counts": issue_type_counts,
    },
    "issues": issues,
    "next_actions": [
        "Run target-repo-task-bridge.sh for runtime tasks stuck in implementing/revising/under_review without handoff.",
        "Create dispatch packets for ready runtime tasks before claiming queue health.",
        "Revert completed statuses that lack validation/dev_merge_commit/remote_dev_ref/review QA evidence.",
        "Run repo-native verify_repo plus smoke before ledger closure.",
    ],
}
print(json.dumps(report, indent=2, ensure_ascii=False))
PY
)"

if [[ -n "${OUTFILE}" ]]; then
  mkdir -p "$(dirname "${OUTFILE}")"
  printf '%s\n' "${REPORT}" > "${OUTFILE}"
fi

if [[ "${SUMMARY_ONLY}" == "true" ]]; then
  REPORT_JSON="${REPORT}" python3 <<'PY'
import json, sys
d = json.loads(__import__("os").environ["REPORT_JSON"])
s = d["summary"]
print(f"closed-loop audit: status={d['status']} tasks={s['task_count']} dispatch={s['dispatch_packet_count']} reviews={s['review_contract_count']} blockers={s['blocker_count']} active_blockers={s['active_blocker_count']} completion_debt={s['completion_debt_count']} warnings={s['warning_count']}")
for name, count in sorted(s.get("issue_type_counts", {}).items(), key=lambda kv: (-kv[1], kv[0]))[:5]:
    print(f"  type_count: {name}={count}")
for issue in d.get("issues", [])[:8]:
    print(f"  - [{issue['severity']}] {issue['type']} {issue.get('task_id','')} repo={issue.get('repo','')} :: {issue.get('detail','')}")
PY
else
  printf '%s\n' "${REPORT}"
fi

blocker_count="$(printf '%s\n' "${REPORT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"]["blocker_count"])')"
if [[ "${STRICT}" == "true" && "${blocker_count}" -gt 0 ]]; then
  exit 1
fi
