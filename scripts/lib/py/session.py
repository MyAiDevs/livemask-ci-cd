#!/usr/bin/env python3
"""
session.py — Session state manager for the Claude dev loop.

Persists task session state as JSON files under ~/.claude/role-cache/.
Each session file is named by task-id.

Usage:
    session.py save <task_id> <status> [--branch <branch>] [--retry <n>] [--error <msg>]
    session.py load <task_id>
    session.py clean

Output (JSON on stdout):
    For save:  {"status":"saved", "file":"...", "state":{dict}}
    For load:  {"status":"found", "task_id":"...", "phase":"...", ...}
               {"status":"not_found", "task_id":"..."}
    For clean: {"status":"cleaned", "file":"..."}
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


SESSION_DIR = Path.home() / ".claude" / "role-cache"
SESSION_FILE = SESSION_DIR / "session-state.json"


def _ensure_dir():
    SESSION_DIR.mkdir(parents=True, exist_ok=True)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── Commands ──────────────────────────────────────────────────────────

def cmd_save(args: list[str]) -> int:
    """session.py save <task_id> <status> [--branch <b>] [--retry <n>] [--error <msg>]"""
    if len(args) < 2:
        print(json.dumps({"status": "error", "message": "usage: save <task_id> <status> [--branch ...] [--retry ...] [--error ...]"}))
        return 1

    task_id = args[0]
    status = args[1]
    branch = ""
    retry = 0
    error = ""
    modified_files = []

    i = 2
    while i < len(args):
        if args[i] == "--branch" and i + 1 < len(args):
            branch = args[i + 1]
            i += 2
        elif args[i] == "--retry" and i + 1 < len(args):
            try:
                retry = int(args[i + 1])
            except ValueError:
                retry = 0
            i += 2
        elif args[i] == "--error" and i + 1 < len(args):
            error = args[i + 1]
            i += 2
        elif args[i] == "--modified" and i + 1 < len(args):
            modified_files = args[i + 1].split(",")
            i += 2
        else:
            i += 1

    _ensure_dir()

    # Load existing state if present
    existing = {}
    if SESSION_FILE.exists():
        try:
            existing = json.loads(SESSION_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            existing = {}

    # Update state
    state = {
        "task_id": task_id,
        "phase": status,
        "branch": branch or existing.get("branch", ""),
        "retry_count": retry,
        "last_error": error,
        "modified_files": modified_files or existing.get("modified_files", []),
        "timestamp": _now_iso(),
    }
    existing.update(state)

    SESSION_FILE.write_text(json.dumps(existing, indent=2, default=str))

    out = {"status": "saved", "file": str(SESSION_FILE), "state": existing}
    print(json.dumps(out))
    return 0


def cmd_load(args: list[str]) -> int:
    """session.py load <task_id>"""
    if not args:
        print(json.dumps({"status": "error", "message": "usage: load <task_id>"}))
        return 1

    task_id = args[0]

    if not SESSION_FILE.exists():
        print(json.dumps({"status": "not_found", "task_id": task_id}))
        return 0

    try:
        state = json.loads(SESSION_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        print(json.dumps({"status": "not_found", "task_id": task_id}))
        return 0

    if state.get("task_id") != task_id:
        print(json.dumps({"status": "not_found", "task_id": task_id}))
        return 0

    out = {"status": "found", **state}
    print(json.dumps(out))
    return 0


def cmd_clean(args: list[str]) -> int:
    """session.py clean — Remove all session state files."""
    _ensure_dir()
    file_path = SESSION_FILE
    removed = False
    if file_path.exists():
        file_path.unlink()
        removed = True
    # Also remove any backup files
    for f in SESSION_DIR.glob("session-state*.bak"):
        f.unlink()
        removed = True

    print(json.dumps({"status": "cleaned", "file": str(file_path) if removed else "none"}))
    return 0


# ── Entry point ───────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    cmd = sys.argv[1]
    rest = sys.argv[2:]

    if cmd == "save":
        return cmd_save(rest)
    elif cmd == "load":
        return cmd_load(rest)
    elif cmd == "clean":
        return cmd_clean(rest)

    print(f"unknown command: {cmd}", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
