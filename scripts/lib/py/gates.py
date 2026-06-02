#!/usr/bin/env python3
"""gates.py — Completion gate and cross-source consistency checks.

Usage:
  python3 gates.py check TASK-ID              # → JSON {passed, failures}
  python3 gates.py complete TASK-ID [--caller] # → runs gate, updates status, returns JSON
  python3 gates.py consistency [TASK-ID]      # → JSON {checked, mismatches, details}
"""
import json, sys, argparse, os, subprocess
from pathlib import Path
from datetime import datetime, timezone

DOCS_DIR = Path(os.environ.get("DOCS_DIR", os.path.expanduser("~/Developer/LiveMask/livemask-docs")))
LEDGER_PATH = DOCS_DIR / "docs/development/task-state-ledger.json"
REVIEW_DIR = DOCS_DIR / "docs/development/review-contracts"
TASK_DIR = DOCS_DIR / "docs/development/tasks"
DISPATCH_DIR = DOCS_DIR / "docs/development/dispatch-packets"


def load_ledger():
    if not LEDGER_PATH.exists():
        return {"modules": []}
    return json.loads(LEDGER_PATH.read_text(encoding="utf-8"))

def find_task(ledger, task_id):
    for mod in ledger.get("modules", []):
        for t in mod.get("tasks", []):
            if t.get("task_id") == task_id:
                return t, mod
    return None, None


# ══════════════════════════════════════════════════════════════════════════════
# Completion gate — 4 hard checks before "completed" is allowed
# ══════════════════════════════════════════════════════════════════════════════

def completion_gate(task_id: str) -> dict:
    """Return {"passed": bool, "failures": [str...]}."""
    ledger = load_ledger()
    task, mod = find_task(ledger, task_id)

    if not task:
        return {"passed": False, "failures": [f"task {task_id} not found in ledger"], "task_id": task_id}

    failures = []
    repo = task.get("repo", "")

    # Gate 1: dev_merge_commit must be non-empty
    if not task.get("dev_merge_commit", ""):
        failures.append("GATE-1: dev_merge_commit is empty — no merge evidence in target repo")

    # Gate 2: Review contract with leader_approved + qa_passed
    review_files = list(REVIEW_DIR.glob(f"{task_id}*-review.json"))
    if not review_files:
        failures.append("GATE-2: no review contract found")
    else:
        try:
            review = json.loads(review_files[0].read_text(encoding="utf-8"))
            claude = review.get("claude", {})
            if not claude.get("leader_approved"):
                failures.append("GATE-2: review contract missing leader_approved")
            if not claude.get("qa_passed"):
                failures.append("GATE-2: review contract missing qa_passed")
        except Exception:
            failures.append("GATE-2: review contract unreadable")

    # Gate 3: QA validation evidence
    if not task.get("validation", ""):
        failures.append("GATE-3: no validation evidence recorded")

    # Gate 4: For non-docs repos, target repo should have evidence
    if repo and repo != "livemask-docs":
        remote_ref = task.get("remote_dev_ref", "")
        merge_commit = task.get("dev_merge_commit", "")
        if not remote_ref and not merge_commit:
            failures.append("GATE-4: non-docs task has no remote ref or merge commit")

    return {"passed": len(failures) == 0, "failures": failures, "task_id": task_id}


# ══════════════════════════════════════════════════════════════════════════════
# Complete task — gate check then status update
# ══════════════════════════════════════════════════════════════════════════════

def complete_task(task_id: str, caller: str = "gates.py") -> dict:
    """Run completion gate. If passed → completed. If failed → evidence_missing."""
    gate_result = completion_gate(task_id)

    if gate_result["passed"]:
        new_status = "completed"
    else:
        new_status = "evidence_missing"

    # Call ledger.py to do the actual status update (single writer)
    result = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "ledger.py"), "status",
         task_id, new_status, "--evidence", json.dumps(gate_result), "--caller", caller],
        capture_output=True, text=True, timeout=15
    )
    try:
        ledger_result = json.loads(result.stdout)
    except json.JSONDecodeError:
        ledger_result = {"status": "error", "message": result.stderr}

    return {
        "gate": gate_result,
        "ledger_update": ledger_result,
        "final_status": new_status,
        "task_id": task_id,
    }


# ══════════════════════════════════════════════════════════════════════════════
# Cross-source consistency check
# ══════════════════════════════════════════════════════════════════════════════

def consistency_check(task_id_filter: str = "") -> dict:
    """Cross-check ledger ↔ task docs ↔ dispatch packets ↔ review contracts ↔ GitHub issues."""
    ledger = load_ledger()
    mismatches = []

    # Build task set
    target_tasks = {}
    for mod in ledger.get("modules", []):
        for t in mod.get("tasks", []):
            tid = t.get("task_id", "")
            if not tid:
                continue
            if task_id_filter and tid != task_id_filter:
                continue
            target_tasks[tid] = (t, mod)

    terminal = {"completed", "completed_with_skip", "cancelled", "rejected", "closed"}

    for tid, (task, mod) in target_tasks.items():
        status = task.get("status", "")
        task_doc_rel = task.get("task_doc", "")
        issue_url = task.get("issue", "")

        # 1. Task doc exists
        if task_doc_rel:
            doc_path = DOCS_DIR / task_doc_rel
            if not doc_path.exists():
                mismatches.append({"task_id": tid, "source": "task_doc", "issue": f"file missing: {task_doc_rel}"})

        # 2. Dispatch packet for non-terminal tasks
        if status not in terminal:
            dp_path = DISPATCH_DIR / f"{tid}.json"
            if dp_path.exists():
                try:
                    dp = json.loads(dp_path.read_text(encoding="utf-8"))
                    dp_status = dp.get("readiness", "")
                    if dp_status == "dispatched" and status not in ("dispatched", "in_progress", "implemented"):
                        mismatches.append({"task_id": tid, "source": "dispatch_packet",
                                          "issue": f"packet says dispatched but ledger says {status}"})
                except Exception:
                    mismatches.append({"task_id": tid, "source": "dispatch_packet", "issue": "packet unreadable"})

        # 3. Review contract for review-adjacent statuses
        if status in {"review_ready", "review_in_progress", "review_approved", "completed"}:
            review_files = list(REVIEW_DIR.glob(f"{tid}*-review.json"))
            if not review_files and status != "review_ready":
                mismatches.append({"task_id": tid, "source": "review_contract",
                                  "issue": f"status={status} but no review contract found"})

        # 4. GitHub issue linkage (non-blocking)
        if issue_url and ("placeholder" in issue_url.lower() or "auto-create failed" in issue_url):
            mismatches.append({"task_id": tid, "source": "github_issue",
                              "issue": f"placeholder issue URL: {issue_url[:80]}"})

    return {
        "checked": len(target_tasks),
        "mismatches": len(mismatches),
        "details": mismatches[:50],
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


# ══════════════════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="Completion gate + consistency checks")
    sub = parser.add_subparsers(dest="command", required=True)

    p_check = sub.add_parser("check", help="Run completion gate (read-only)")
    p_check.add_argument("task_id")

    p_complete = sub.add_parser("complete", help="Run gate + update status")
    p_complete.add_argument("task_id")
    p_complete.add_argument("--caller", "-c", default="gates.py")

    p_consistency = sub.add_parser("consistency", help="Cross-source consistency check")
    p_consistency.add_argument("task_id", nargs="?", default="")

    args = parser.parse_args()

    if args.command == "check":
        result = completion_gate(args.task_id)
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["passed"] else 2)

    elif args.command == "complete":
        result = complete_task(args.task_id, args.caller)
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["gate"]["passed"] else 2)

    elif args.command == "consistency":
        result = consistency_check(args.task_id)
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["mismatches"] == 0 else 1)


if __name__ == "__main__":
    main()
