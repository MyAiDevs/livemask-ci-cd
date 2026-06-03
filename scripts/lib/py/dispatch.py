#!/usr/bin/env python3
"""
dispatch.py — Next-task finder for the Claude dev loop.

Scans the dispatch-packets directory for `.json` packets, then falls back
to scanning the task-state-ledger for ready/in_progress tasks.

Usage:
    dispatch.py next --ledger <path> --packets <dir>

Output (JSON on stdout):
    {"status":"found", "task_id":"TASK-...", "repo":"livemask-...",
     "source":"packet|ledger", "message":"..."}
    {"status":"empty|empty_ledger|blocked_chain", "message":"..."}
"""

import json
import os
import subprocess
import sys
from pathlib import Path

from debug_utils import setup as _debug_setup, traced, logger as _logger


# ── Ledger → task lookup helpers ──────────────────────────────────────

REPO_FIELD_MAP = {
    "livemask-backend": ("Backend", "go"),
    "livemask-admin": ("Admin", "node"),
    "livemask-website": ("Website", "node"),
    "livemask-app": ("App", "flutter"),
    "livemask-nodeagent": ("NodeAgent", "go"),
    "livemask-job-service": ("Job Service", "go"),
    "livemask-ci-cd": ("CI-CD", "shell"),
    "livemask-docs": ("Docs", "markdown"),
}


def _load_ledger(path: str) -> list[dict]:
    """Load and flatten all tasks from the ledger JSON."""
    try:
        with open(path) as f:
            doc = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        return [], False, str(e)

    modules = doc.get("modules", [])
    tasks = []
    for mod in modules:
        for t in mod.get("tasks", []):
            t["module"] = mod.get("module", "")
            tasks.append(t)
    return tasks, True, ""


def _resolve_repo(task: dict) -> str:
    """Map a ledger task to a repo name. Checks impacted_repos, repos, module, and repo fields."""
    impacted = task.get("impacted_repos", task.get("module", ""))
    if isinstance(impacted, str):
        impacted = [impacted]
    for ir in impacted:
        for repo, (keyword, _) in REPO_FIELD_MAP.items():
            if keyword.lower() in ir.lower():
                return repo
        if ir in REPO_FIELD_MAP:
            return ir
    # Fallback: check `repos` list (set by auto_evidence.py)
    repos_list = task.get("repos", [])
    if isinstance(repos_list, list) and len(repos_list) > 0:
        r = repos_list[0]
        if r in REPO_FIELD_MAP:
            return r
        for dirname, (keyword, _) in REPO_FIELD_MAP.items():
            if r.lower() == dirname or r.lower() == keyword.lower().replace(" ", "-"):
                return dirname
        return r  # Use as-is
    # Fallback: check `repo` field (single string)
    repo_field = task.get("repo", "")
    if repo_field in REPO_FIELD_MAP:
        return repo_field
    return "livemask-docs"


def _is_implementable(task: dict) -> bool:
    """Return True if the task is in a state that can be dispatched."""
    status = task.get("status", "").lower()
    return status in ("ready", "dispatched", "in_progress", "blocked", "")


# ── Packet scanner ────────────────────────────────────────────────────

def _scan_packets(packets_dir: str) -> list[dict]:
    """Read all `.json` dispatch packets and return sorted by priority."""
    p = Path(packets_dir)
    if not p.is_dir():
        return []

    packets = []
    for f in sorted(p.glob("*.json")):
        try:
            data = json.loads(f.read_text())
            packets.append(data)
        except (json.JSONDecodeError, OSError):
            continue

    # Sort by priority (descending), handle mixed int/str
    def _priority(pkt):
        p = pkt.get("priority", 0)
        if isinstance(p, str):
            try: return int(p)
            except ValueError: return 0
        return p if isinstance(p, (int, float)) else 0
    packets.sort(key=_priority, reverse=True)
    return packets


def _normalize_repo(repo: str) -> str:
    """Convert repo keyword to directory name."""
    if not repo:
        return "livemask-docs"
    repo_clean = repo.lower().strip()
    repo_with_spaces = repo_clean.replace("-", " ")
    for dirname, (keyword, _) in REPO_FIELD_MAP.items():
        key_lower = keyword.lower()
        if repo_clean == dirname or repo_with_spaces == key_lower or repo_clean == key_lower.replace(" ", "-"):
            return dirname
    return repo


def _format_packet_output(pkt: dict) -> dict:
    """Turn a dispatch packet into the standard JSON output."""
    task_id = pkt.get("task_id", pkt.get("id", ""))
    repo = pkt.get("repo", pkt.get("target_repo", pkt.get("target", "")))
    if not repo:
        repo = _resolve_repo(pkt)
    repo = _normalize_repo(repo)
    return {
        "status": "found",
        "task_id": task_id,
        "repo": repo,
        "source": "packet",
        "message": pkt.get("title", pkt.get("description", "dispatch packet")),
    }


def _format_ledger_output(task: dict) -> dict:
    """Turn a ledger task into the standard JSON output."""
    task_id = task.get("id", task.get("task_id", ""))
    repo = _normalize_repo(_resolve_repo(task))
    return {
        "status": "found",
        "task_id": task_id,
        "repo": repo,
        "source": "ledger",
        "message": task.get("title", task.get("description", "")),
    }


# ── Commands ──────────────────────────────────────────────────────────

@traced
def cmd_next(args: list[str]) -> int:
    """dispatch.py next --ledger <path> --packets <dir>"""
    ledger_path = ""
    packets_dir = ""

    i = 0
    while i < len(args):
        if args[i] == "--ledger" and i + 1 < len(args):
            ledger_path = args[i + 1]
            i += 2
        elif args[i] == "--packets" and i + 1 < len(args):
            packets_dir = args[i + 1]
            i += 2
        else:
            i += 1

    if not ledger_path:
        print(json.dumps({"status": "error", "message": "--ledger path required"}))
        return 1

    # 1. Try dispatch packets first
    if packets_dir:
        packets = _scan_packets(packets_dir)
        if packets:
            # Build a set of completed task IDs from the ledger
            ledger_tasks, _, _ = _load_ledger(ledger_path)
            completed_tasks = set()
            for t in ledger_tasks:
                status = t.get("status", "").lower()
                if status in ("completed", "completed_with_skip", "cancelled", "rejected"):
                    tid = t.get("id", t.get("task_id", ""))
                    if tid:
                        completed_tasks.add(tid)

            for pkt in packets:
                tid = pkt.get("task_id", pkt.get("id", ""))
                # Skip if already completed in ledger
                if tid and tid in completed_tasks:
                    continue
                # Check lock before dispatching — skip if already locked
                if tid:
                    lock_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lock.py")
                    r = subprocess.run(
                        [sys.executable, lock_script, "check", f"task:{tid}"],
                        capture_output=True, text=True, timeout=5,
                    )
                    try:
                        lock_status = json.loads(r.stdout)
                        if lock_status.get("status") in ("locked", "stale") and not lock_status.get("is_stale"):
                            continue  # Task is locked by another session — skip
                    except (json.JSONDecodeError, Exception):
                        pass
                out = _format_packet_output(pkt)
                print(json.dumps(out))
                return 0
            # All packets locked or completed — fall through to ledger

    # 2. Fall back to ledger
    tasks, ok, err = _load_ledger(ledger_path)
    if not ok:
        print(json.dumps({"status": "error", "message": f"ledger error: {err}"}))
        return 1

    if not tasks:
        print(json.dumps({"status": "empty_ledger", "message": "no tasks in ledger"}))
        return 0

    # Find first implementable task (not locked by another session)
    for task in tasks:
        if _is_implementable(task):
            tid = task.get("id", task.get("task_id", ""))
            if tid:
                lock_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lock.py")
                r = subprocess.run(
                    [sys.executable, lock_script, "check", f"task:{tid}"],
                    capture_output=True, text=True, timeout=5,
                )
                try:
                    lock_status = json.loads(r.stdout)
                    if lock_status.get("status") in ("locked", "stale") and not lock_status.get("is_stale"):
                        continue  # Task is locked by another session — skip
                except (json.JSONDecodeError, Exception):
                    pass
            out = _format_ledger_output(task)
            print(json.dumps(out))
            return 0

    # All tasks blocked or completed
    blocked = sum(1 for t in tasks if t.get("status", "").lower() in ("blocked",))
    print(json.dumps({
        "status": "blocked_chain",
        "message": f"all {len(tasks)} tasks are completed/in_progress/blocked ({blocked} blocked)",
    }))
    return 0


# ── Entry point ───────────────────────────────────────────────────────

def main():
    _debug_setup()
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    cmd = sys.argv[1]
    rest = sys.argv[2:]

    if cmd == "next":
        return cmd_next(rest)

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
