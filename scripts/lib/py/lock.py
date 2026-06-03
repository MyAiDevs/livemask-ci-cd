#!/usr/bin/env python3
"""
lock.py — Distributed advisory lock system for LiveMask dev loop.

Prevents multi-window / multi-session concurrent access to:
  - Repositories (repo:livemask-backend) — no two windows edit the same repo
  - Tasks (task:TASK-xxx) — no two windows dispatch the same task
  - Specific artifacts (file:path)

Lock model:
  - File-based: each lock is a JSON file under ~/.claude/locks/
  - Lease-based: each lock has a TTL (default 30 min) after which it's stale
  - Session-bound: each lock records holder (session_id, pid, host)
  - Staleness: locks older than their TTL can be force-broken

Usage:
    lock.py acquire <scope> [--ttl SECONDS] [--holder HOLDER] [--session SESSION]
    lock.py release <scope> [--holder HOLDER]
    lock.py check <scope>                      # Returns lock info or "free"
    lock.py list [--prefix PREFIX]             # List all / filtered locks
    lock.py break-stale [--prefix PREFIX]      # Force-release expired locks
    lock.py heartbeat <scope> [--ttl SECONDS]  # Extend a lock's TTL

Scope format:
    repo:livemask-backend
    task:TASK-P0-03
    file:/path/to/file

Output: JSON to stdout, errors to stderr.
Exit code: 0=success, 1=error, 2=locked_by_other
"""

import json
import os
import socket
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from debug_utils import setup as _debug_setup, traced, logger as _logger

LOCK_DIR = Path.home() / ".claude" / "locks"
DEFAULT_TTL = 1800  # 30 minutes
MAX_TTL = 7200      # 2 hours max lease


def _ensure_dir():
    LOCK_DIR.mkdir(parents=True, exist_ok=True)


def _lock_path(scope: str) -> Path:
    """Convert a scope string to a lock file path."""
    # Sanitize: replace ':' and '/' with safe chars
    safe = scope.replace(":", "_").replace("/", "_").replace("\\", "_")
    # Keep the path short but recognizable
    return LOCK_DIR / f"{safe}.lock.json"


def _now() -> float:
    return time.time()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_lock(lock_file: Path) -> dict:
    """Read a lock file, return dict or None."""
    if not lock_file.exists():
        return None
    try:
        data = json.loads(lock_file.read_text())
        return data
    except (json.JSONDecodeError, OSError):
        return None


def _is_stale(lock_data: dict) -> bool:
    """Check if a lock has exceeded its TTL."""
    acquired = lock_data.get("acquired_at", 0)
    ttl = lock_data.get("ttl_seconds", DEFAULT_TTL)
    return (_now() - acquired) > ttl


def _write_lock(lock_file: Path, data: dict):
    """Atomic write of lock data."""
    _ensure_dir()
    tmp = lock_file.with_suffix(".lock.tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.rename(lock_file)


def _delete_lock(lock_file: Path):
    """Remove lock file if it exists."""
    if lock_file.exists():
        lock_file.unlink()


def _get_default_holder() -> str:
    """Get a default holder string: hostname-pid-{uuid:8}."""
    host = socket.gethostname()
    pid = os.getpid()
    return f"{host}-{pid}"


# ── Commands ──────────────────────────────────────────────────────

def cmd_acquire(args: list[str]) -> int:
    """lock.py acquire <scope> [--ttl SECONDS] [--holder HOLDER] [--session SESSION]"""
    if not args:
        print(json.dumps({"error": "usage: acquire <scope> [--ttl SECONDS] [--holder HOLDER] [--session SESSION]"}))
        return 1

    scope = args[0]
    ttl = DEFAULT_TTL
    holder = _get_default_holder()
    session_id = ""

    i = 1
    while i < len(args):
        if args[i] == "--ttl" and i + 1 < len(args):
            try:
                ttl = min(int(args[i + 1]), MAX_TTL)
            except ValueError:
                pass
            i += 2
        elif args[i] == "--holder" and i + 1 < len(args):
            holder = args[i + 1]
            i += 2
        elif args[i] == "--session" and i + 1 < len(args):
            session_id = args[i + 1]
            i += 2
        else:
            i += 1

    lock_file = _lock_path(scope)
    existing = _load_lock(lock_file)

    if existing:
        if _is_stale(existing):
            # Stale lock — we can break it
            pass  # proceed to acquire
        else:
            # Active lock — check if same holder
            if existing.get("holder") == holder and existing.get("session_id") == session_id:
                # Same process re-acquiring — refresh the lock
                pass  # proceed to update
            else:
                # Held by someone else
                expires_at = existing.get("acquired_at", 0) + existing.get("ttl_seconds", DEFAULT_TTL)
                remaining = max(0, int(expires_at - _now()))
                print(json.dumps({
                    "status": "locked",
                    "scope": scope,
                    "holder": existing.get("holder", "?"),
                    "session": existing.get("session_id", ""),
                    "pid": existing.get("pid", 0),
                    "acquired_at": existing.get("acquired_at_iso", ""),
                    "ttl_seconds": existing.get("ttl_seconds", DEFAULT_TTL),
                    "remaining_seconds": remaining,
                    "task_id": existing.get("task_id", ""),
                }))
                return 2  # locked by other

    lock_data = {
        "scope": scope,
        "holder": holder,
        "session_id": session_id,
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "acquired_at": _now(),
        "acquired_at_iso": _now_iso(),
        "ttl_seconds": ttl,
        "expires_at_iso": datetime.fromtimestamp(_now() + ttl, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lock_id": str(uuid.uuid4())[:8],
    }

    _write_lock(lock_file, lock_data)

    # Also write a session-anchored symlink to detect multi-window on same session
    if session_id:
        session_link = LOCK_DIR / f"session_{session_id}.lock"
        try:
            if session_link.exists():
                session_link.unlink()
            session_link.symlink_to(lock_file.name)
        except (OSError, NotImplementedError):
            pass  # symlinks not supported on all OS (Windows)

    print(json.dumps({"status": "acquired", **lock_data}))
    return 0


def cmd_release(args: list[str]) -> int:
    """lock.py release <scope> [--holder HOLDER]"""
    if not args:
        print(json.dumps({"error": "usage: release <scope> [--holder HOLDER]"}))
        return 1

    scope = args[0]
    holder = ""

    i = 1
    while i < len(args):
        if args[i] == "--holder" and i + 1 < len(args):
            holder = args[i + 1]
            i += 2
        else:
            i += 1

    lock_file = _lock_path(scope)
    existing = _load_lock(lock_file)

    if not existing:
        print(json.dumps({"status": "not_locked", "scope": scope}))
        return 0

    if holder and existing.get("holder") != holder:
        # Different holder — refuse to release unless stale
        if not _is_stale(existing):
            print(json.dumps({
                "status": "held_by_other",
                "scope": scope,
                "holder": existing.get("holder", "?"),
            }))
            return 2

    # Clean up session link
    session_id = existing.get("session_id", "")
    if session_id:
        session_link = LOCK_DIR / f"session_{session_id}.lock"
        try:
            if session_link.exists():
                session_link.unlink()
        except OSError:
            pass

    _delete_lock(lock_file)
    held_duration = _now() - existing.get("acquired_at", _now())

    print(json.dumps({
        "status": "released",
        "scope": scope,
        "held_by": existing.get("holder", "?"),
        "held_seconds": round(held_duration, 1),
        "task_id": existing.get("task_id", ""),
    }))
    return 0


def cmd_check(args: list[str]) -> int:
    """lock.py check <scope>"""
    if not args:
        print(json.dumps({"error": "usage: check <scope>"}))
        return 1

    scope = args[0]
    lock_file = _lock_path(scope)
    existing = _load_lock(lock_file)

    if not existing:
        print(json.dumps({"status": "free", "scope": scope}))
        return 0

    stale = _is_stale(existing)
    expires_at = existing.get("acquired_at", 0) + existing.get("ttl_seconds", DEFAULT_TTL)
    remaining = max(0, int(expires_at - _now()))

    print(json.dumps({
        "status": "stale" if stale else "locked",
        "scope": scope,
        "holder": existing.get("holder", "?"),
        "session": existing.get("session_id", ""),
        "pid": existing.get("pid", 0),
        "acquired_at": existing.get("acquired_at_iso", ""),
        "ttl_seconds": existing.get("ttl_seconds", DEFAULT_TTL),
        "remaining_seconds": remaining,
        "is_stale": stale,
        "task_id": existing.get("task_id", ""),
    }))
    return 0


def cmd_list(args: list[str]) -> int:
    """lock.py list [--prefix PREFIX]"""
    prefix = ""

    i = 0
    while i < len(args):
        if args[i] == "--prefix" and i + 1 < len(args):
            prefix = args[i + 1]
            i += 2
        else:
            i += 1

    _ensure_dir()
    locks = []
    for f in sorted(LOCK_DIR.glob("*.lock.json")):
        data = _load_lock(f)
        if data:
            scope = data.get("scope", f.stem.replace(".lock", ""))
            if prefix and not scope.startswith(prefix):
                continue
            stale = _is_stale(data)
            expires_at = data.get("acquired_at", 0) + data.get("ttl_seconds", DEFAULT_TTL)
            remaining = max(0, int(expires_at - _now()))
            locks.append({
                "file": f.name,
                "scope": scope,
                "holder": data.get("holder", "?"),
                "session": data.get("session_id", ""),
                "pid": data.get("pid", 0),
                "acquired_at": data.get("acquired_at_iso", ""),
                "remaining_seconds": remaining,
                "stale": stale,
            })

    print(json.dumps({
        "count": len(locks),
        "locks": locks,
    }))
    return 0


def cmd_break_stale(args: list[str]) -> int:
    """lock.py break-stale [--prefix PREFIX]"""
    prefix = ""

    i = 0
    while i < len(args):
        if args[i] == "--prefix" and i + 1 < len(args):
            prefix = args[i + 1]
            i += 2
        else:
            i += 1

    _ensure_dir()
    broken = []
    for f in list(LOCK_DIR.glob("*.lock.json")):
        data = _load_lock(f)
        if data and _is_stale(data):
            scope = data.get("scope", "")
            if prefix and not scope.startswith(prefix):
                continue
            _delete_lock(f)
            broken.append({
                "file": f.name,
                "scope": scope,
                "was_held_by": data.get("holder", "?"),
                "was_acquired": data.get("acquired_at_iso", ""),
                "ttl_seconds": data.get("ttl_seconds", DEFAULT_TTL),
            })
            # Cleanup session link
            session_id = data.get("session_id", "")
            if session_id:
                sl = LOCK_DIR / f"session_{session_id}.lock"
                try:
                    if sl.exists():
                        sl.unlink()
                except OSError:
                    pass

    print(json.dumps({
        "status": "ok",
        "broken_count": len(broken),
        "broken": broken,
    }))
    return 0


def cmd_heartbeat(args: list[str]) -> int:
    """lock.py heartbeat <scope> [--ttl SECONDS]"""
    if not args:
        print(json.dumps({"error": "usage: heartbeat <scope> [--ttl SECONDS]"}))
        return 1

    scope = args[0]
    ttl = DEFAULT_TTL

    i = 1
    while i < len(args):
        if args[i] == "--ttl" and i + 1 < len(args):
            try:
                ttl = min(int(args[i + 1]), MAX_TTL)
            except ValueError:
                pass
            i += 2
        else:
            i += 1

    lock_file = _lock_path(scope)
    existing = _load_lock(lock_file)

    if not existing:
        print(json.dumps({"status": "not_locked", "scope": scope}))
        return 0

    if _is_stale(existing):
        print(json.dumps({"status": "stale", "scope": scope,
                          "message": "lock has expired — re-acquire"}))
        return 2

    # Extend the lease
    existing["acquired_at"] = _now()
    existing["acquired_at_iso"] = _now_iso()
    existing["ttl_seconds"] = ttl
    existing["expires_at_iso"] = datetime.fromtimestamp(_now() + ttl, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    existing["heartbeat_at"] = _now_iso()

    _write_lock(lock_file, existing)

    print(json.dumps({
        "status": "heartbeat",
        "scope": scope,
        "extended_ttl": ttl,
        "expires_at": existing["expires_at_iso"],
    }))
    return 0


# ── Main ──────────────────────────────────────────────────────────

def main():
    _debug_setup()
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "acquire": cmd_acquire,
        "release": cmd_release,
        "check": cmd_check,
        "list": cmd_list,
        "break-stale": cmd_break_stale,
        "heartbeat": cmd_heartbeat,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        return 1

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
