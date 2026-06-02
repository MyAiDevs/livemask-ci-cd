#!/usr/bin/env python3
"""ledger.py — Single source of truth for task-state-ledger.json mutations.
All status changes MUST go through this module. Direct JSON writes are forbidden.

Usage:
  python3 ledger.py find TASK-ID
  python3 ledger.py status TASK-ID NEW-STATUS [--evidence E] [--caller C]
  python3 ledger.py list [--status S] [--repo R]
  python3 ledger.py add '{"task_id":"...",...}'

Output: JSON to stdout, errors to stderr, exit code 0=success 1=error 2=rejected
"""
import json, sys, argparse, os
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional

LEDGER_PATH = Path(os.environ.get("LEDGER_FILE", ""))
if not LEDGER_PATH.is_absolute() or not str(LEDGER_PATH):
    # Default: derive from DOCS_DIR or LIVEMASK_ROOT
    docs = Path(os.environ.get("DOCS_DIR", os.path.expanduser("~/Developer/LiveMask/livemask-docs")))
    LEDGER_PATH = docs / "docs/development/task-state-ledger.json"

# ── State machine ──────────────────────────────────────────────────────────
# All legal transitions.  "->X" means creation.  "any->X" is a wildcard source.
LEGAL_TRANSITIONS = {
    # Creation
    "->ready", "->dispatched",
    # Forward flow
    "ready->dispatched", "dispatched->in_progress",
    "in_progress->implemented", "implemented->verified",
    "verified->completed",
    # Review path
    "implemented->review_ready", "review_ready->review_in_progress",
    "review_in_progress->review_approved", "review_approved->completed",
    # Blocking / rework
    "in_progress->blocked", "blocked->in_progress", "blocked->implemented",
    "implemented->blocked", "implemented->in_progress",
    "in_progress->ready",  # accept rollback
    "review_in_progress->review_retry", "review_retry->implemented",
    # Evidence gate
    "evidence_missing->implemented", "evidence_missing->in_progress",
    "completed_with_skip->completed",
    # Wildcards
    "any->cancelled", "any->rejected", "any->evidence_missing",
}

def load_ledger() -> tuple[dict, Path]:
    """Return (ledger_dict, path). Creates empty ledger if missing."""
    if not LEDGER_PATH.exists():
        return {"schema_version": 1, "modules": [], "repos": []}, LEDGER_PATH
    return json.loads(LEDGER_PATH.read_text(encoding="utf-8")), LEDGER_PATH

def save_ledger(ledger: dict):
    LEDGER_PATH.write_text(json.dumps(ledger, indent=2, ensure_ascii=False), encoding="utf-8")

def find_task(ledger: dict, task_id: str) -> Optional[tuple[dict, dict]]:
    """Return (task, module) or None."""
    for mod in ledger.get("modules", []):
        for t in mod.get("tasks", []):
            if t.get("task_id") == task_id:
                return t, mod
    return None

def check_transition(old_status: str, new_status: str) -> tuple[bool, str]:
    """Return (legal, reason)."""
    if f"{old_status}->{new_status}" in LEGAL_TRANSITIONS:
        return True, ""
    if f"any->{new_status}" in LEGAL_TRANSITIONS:
        return True, ""
    return False, f"illegal transition: {old_status} -> {new_status}"

def cmd_find(args):
    ledger, _ = load_ledger()
    result = find_task(ledger, args.task_id)
    if result:
        task, mod = result
        print(json.dumps({"found": True, "task": task, "module_id": mod.get("module_id", "")}, indent=2))
        return 0
    print(json.dumps({"found": False, "task_id": args.task_id}))
    return 1

def cmd_status(args):
    ledger, path = load_ledger()
    result = find_task(ledger, args.task_id)

    if not result:
        if args.new_status in ("ready", "dispatched"):
            print(json.dumps({"status": "ok", "message": f"creation {args.task_id} -> {args.new_status} allowed"}))
            return 0
        print(json.dumps({"status": "rejected", "reason": f"task {args.task_id} not found"}), file=sys.stderr)
        return 1

    task, mod = result
    old_status = task.get("status", "")
    legal, reason = check_transition(old_status, args.new_status)

    if not legal:
        print(json.dumps({"status": "rejected", "reason": reason, "task_id": args.task_id,
                          "old_status": old_status, "new_status": args.new_status}), file=sys.stderr)
        return 2

    task["status"] = args.new_status
    task["_last_status_change_by"] = args.caller or "ledger.py"
    task["_last_status_change_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if args.evidence:
        task["_last_evidence"] = args.evidence[:500]

    save_ledger(ledger)
    print(json.dumps({"status": "ok", "task_id": args.task_id, "old_status": old_status,
                      "new_status": args.new_status, "caller": args.caller or "ledger.py"}))
    return 0

def cmd_list(args):
    ledger, _ = load_ledger()
    results = []
    for mod in ledger.get("modules", []):
        for t in mod.get("tasks", []):
            if args.status and t.get("status") != args.status:
                continue
            if args.repo and t.get("repo") != args.repo:
                continue
            results.append({"task_id": t.get("task_id"), "status": t.get("status"),
                           "repo": t.get("repo"), "module_id": mod.get("module_id", ""),
                           "priority": t.get("priority", ""), "issue": t.get("issue", "")[:80]})
    print(json.dumps(results, indent=2))
    return 0

def cmd_add(args):
    ledger, path = load_ledger()
    try:
        task_data = json.loads(args.task_json)
    except json.JSONDecodeError as e:
        print(json.dumps({"status": "error", "reason": f"invalid JSON: {e}"}), file=sys.stderr)
        return 1

    tid = task_data.get("task_id")
    if not tid:
        print(json.dumps({"status": "error", "reason": "missing task_id"}), file=sys.stderr)
        return 1

    if find_task(ledger, tid):
        print(json.dumps({"status": "rejected", "reason": f"task {tid} already exists"}), file=sys.stderr)
        return 1

    # Ensure auto-tasks module exists
    module_id = task_data.pop("module_id", "auto-tasks")
    target_mod = None
    for mod in ledger.get("modules", []):
        if mod.get("module_id") == module_id:
            target_mod = mod
            break
    if not target_mod:
        target_mod = {"module_id": module_id, "overall_status": "partial",
                      "owner_repo": task_data.get("repo", "livemask-docs"), "tasks": [], "open_gaps": []}
        ledger.setdefault("modules", []).append(target_mod)

    target_mod.setdefault("tasks", []).append(task_data)
    target_mod["overall_status"] = "partial"
    save_ledger(ledger)
    print(json.dumps({"status": "ok", "task_id": tid, "module_id": module_id}))
    return 0


def main():
    parser = argparse.ArgumentParser(description="Ledger state machine (single writer)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_find = sub.add_parser("find", help="Find task by ID")
    p_find.add_argument("task_id")

    p_status = sub.add_parser("status", help="Update task status with state machine guard")
    p_status.add_argument("task_id")
    p_status.add_argument("new_status")
    p_status.add_argument("--evidence", "-e", default="")
    p_status.add_argument("--caller", "-c", default="ledger.py")

    p_list = sub.add_parser("list", help="List tasks")
    p_list.add_argument("--status", "-s", default="")
    p_list.add_argument("--repo", "-r", default="")

    p_add = sub.add_parser("add", help="Add new task to ledger")
    p_add.add_argument("task_json")

    args = parser.parse_args()
    cmds = {"find": cmd_find, "status": cmd_status, "list": cmd_list, "add": cmd_add}
    sys.exit(cmds[args.command](args))

if __name__ == "__main__":
    main()
