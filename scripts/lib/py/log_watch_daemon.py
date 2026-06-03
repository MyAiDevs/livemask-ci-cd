#!/usr/bin/env python3
"""
log_watch_daemon.py — Background log watcher daemon for Claude dev loop.

Monitors log files for error patterns, checks experience system first,
falls back to repair.py --apply.  Thin Python daemon avoids bash 3.2
compatibility issues with array expansion, `local`, and `nohup`.

Used by log-watch.sh via:
    python3 log_watch_daemon.py poll

Usage:
    python3 log_watch_daemon.py poll           # Single poll cycle (for cron/scheduled)
    python3 log_watch_daemon.py daemon          # Continuous daemon loop

Output: JSON lines to stdout.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude")
WATCH_DIRS = ["/tmp/claude"]
LINE_COUNTS_FILE = os.path.join(CACHE_DIR, "log-watch-lines.json")
FIX_COUNTER_FILE = os.path.join(CACHE_DIR, "log-watch-fixes.json")
PY_DIR = os.path.join(os.environ.get("LIVEMASK_ROOT", os.path.expanduser("~/Developer/LiveMask")),
                      "livemask-ci-cd", "scripts", "lib", "py")
MAX_FIXES_PER_MINUTE = 10


def _load_json(path: str, default: dict = None) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default or {}


def _save_json(path: str, data: dict):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f)


def _state_get_line(logfile: str) -> int:
    d = _load_json(LINE_COUNTS_FILE)
    return int(d.get(logfile, 0))


def _state_set_line(logfile: str, count: int):
    d = _load_json(LINE_COUNTS_FILE)
    d[logfile] = count
    _save_json(LINE_COUNTS_FILE, d)


def _fix_counter_check() -> bool:
    now = int(time.time())
    d = _load_json(FIX_COUNTER_FILE, {"last_minute_window": 0, "fixes_this_window": 0, "total_fixes": 0})

    if now - d.get("last_minute_window", 0) > 60:
        d["last_minute_window"] = now
        d["fixes_this_window"] = 0

    if d["fixes_this_window"] >= MAX_FIXES_PER_MINUTE:
        return False

    d["fixes_this_window"] += 1
    d["total_fixes"] = d.get("total_fixes", 0) + 1
    _save_json(FIX_COUNTER_FILE, d)
    return True


SESSION_STATE = os.path.join(CACHE_DIR, "role-cache", "session-state.json")


def _session_phase() -> str:
    """Read current session phase."""
    try:
        with open(SESSION_STATE) as f:
            d = json.load(f)
        return d.get("phase", "")
    except (FileNotFoundError, json.JSONDecodeError):
        return ""


def _session_task_id() -> str:
    """Read current session task_id."""
    try:
        with open(SESSION_STATE) as f:
            d = json.load(f)
        return d.get("task_id", "")
    except (FileNotFoundError, json.JSONDecodeError):
        return ""


def _resolve_stuck_phase4():
    """Auto-resolve Phase 4 stuck state by detecting and acting on the task."""
    phase = _session_phase()
    task_id = _session_task_id()

    if not task_id:
        print(f"[log-watch][phase4] no task_id in session state", flush=True)
        return False

    if phase not in ("implementing", "context_loaded"):
        print(f"[log-watch][phase4] session phase={phase} not stuck", flush=True)
        return False

    print(f"[log-watch][phase4] detected stuck task: {task_id} (phase={phase})", flush=True)

    auto_impl_py = os.path.join(PY_DIR, "auto_implement.py")
    if not os.path.exists(auto_impl_py):
        print(f"[log-watch][phase4] auto_implement.py not found, checking if already completed in ledger...", flush=True)

        # Fallback: check ledger for completed status
        ledger_path = os.path.join(
            os.environ.get("LIVEMASK_ROOT", os.path.expanduser("~/Developer/LiveMask")),
            "livemask-docs", "docs/development", "task-state-ledger.json"
        )
        try:
            with open(ledger_path) as f:
                ledger = json.load(f)
            for mod in ledger.get("modules", []):
                for t in mod.get("tasks", []):
                    if t.get("task_id") == task_id:
                        s = t.get("status", "")
                        if s in ("completed", "completed_with_skip"):
                            print(f"[log-watch][phase4] task {task_id} already {s} in ledger — advancing session", flush=True)
                            subprocess.run(
                                [sys.executable, os.path.join(PY_DIR, "session.py"),
                                 "save", task_id, "verifying", "--branch", f"task/{task_id}"],
                                capture_output=True, timeout=30,
                            )
                            return True
        except Exception:
            pass
        return False

    # Step 1: Check if auto-implementable
    try:
        r = subprocess.run(
            [sys.executable, auto_impl_py, "detect", task_id],
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode == 0:
            print(f"[log-watch][phase4] task {task_id} IS auto-implementable — running impl...", flush=True)
            # Step 2: Auto-implement
            try:
                r2 = subprocess.run(
                    [sys.executable, auto_impl_py, "impl", task_id],
                    capture_output=True, text=True, timeout=60,
                )
                print(f"[log-watch][phase4] auto_implement.py impl result: {r2.stdout.strip()}", flush=True)
                if r2.returncode == 0:
                    print(f"[log-watch][phase4] ✅ auto-implemented {task_id}", flush=True)
                    return True
                print(f"[log-watch][phase4] impl failed: {r2.stderr.strip()}", flush=True)
                return False
            except subprocess.TimeoutExpired:
                print(f"[log-watch][phase4] impl timed out for {task_id}", flush=True)
                return False
            except Exception as e:
                print(f"[log-watch][phase4] impl error: {e}", flush=True)
                return False
        else:
            # Task is NOT auto-implementable — this is a real code task
            print(f"[log-watch][phase4] task {task_id} requires real implementation (not auto-implementable)", flush=True)
            print(f"[log-watch][phase4] Reason: {r.stdout.strip() or r.stderr.strip()}", flush=True)
            print(f"[log-watch][phase4] This task needs an AI agent or human to implement the code.", flush=True)
            print(f"[log-watch][phase4] The daemon will keep checking — once session advances, it continues.", flush=True)
            return False
    except subprocess.TimeoutExpired:
        print(f"[log-watch][phase4] detect timed out for {task_id}", flush=True)
        return False
    except Exception as e:
        print(f"[log-watch][phase4] detect error: {e}", flush=True)
        return False


def _auto_repair(logfile: str, new_lines: str):
    """Check new lines for errors, then try experience system + repair.py."""
    import re
    if not re.search(r'(error|fail|panic|exit status|not found)', new_lines, re.IGNORECASE):
        return

    if not _fix_counter_check():
        print(f"[log-watch] rate limited", flush=True)
        return

    # 1. Try experience.suggest + _apply
    suggest_file = f"/tmp/log-watch-suggest-{os.getpid()}.json"
    applied = False
    try:
        r = subprocess.run(
            [sys.executable, os.path.join(PY_DIR, "experience.py"), "suggest", logfile],
            capture_output=True, timeout=30,
        )
        # BUG FIX: write stdout to suggest_file so _apply can read it
        if r.returncode == 0 and r.stdout.strip():
            with open(suggest_file, "w") as sf:
                sf.write(r.stdout.decode() if isinstance(r.stdout, bytes) else r.stdout)
    except Exception as e:
        print(f"[log-watch] experience.suggest error: {e}", flush=True)

    if os.path.exists(suggest_file):
        try:
            with open(suggest_file) as f:
                suggest_data = json.load(f)
            if suggest_data.get("status") == "ok" and suggest_data.get("suggestions"):
                print(f"[log-watch] experience has {len(suggest_data['suggestions'])} suggestions for {logfile}", flush=True)
                apply_r = subprocess.run(
                    [sys.executable, os.path.join(PY_DIR, "experience.py"), "_apply", suggest_file],
                    capture_output=True, text=True, timeout=60,
                )
                # Record whether the apply healed or not
                healed = "HEALED=yes" in apply_r.stdout
                print(f"[log-watch] experience._apply {'healed' if healed else 'did not heal'} {logfile}", flush=True)
                if healed:
                    applied = True
        except (json.JSONDecodeError, subprocess.TimeoutExpired) as e:
            print(f"[log-watch] experience._apply error: {e}", flush=True)
        try:
            os.unlink(suggest_file)
        except OSError:
            pass

    # 2. If experience didn't heal, fall back to repair.py --apply
    if not applied:
        try:
            r = subprocess.run(
                [sys.executable, os.path.join(PY_DIR, "repair.py"), "build", logfile, "--apply"],
                capture_output=True, text=True, timeout=120,
            )
            status = "?"
            try:
                result = json.loads(r.stdout)
                status = result.get("status", "?")
            except json.JSONDecodeError:
                status = "parse_error"
            print(f"[log-watch] repair.py status={status} for {logfile}", flush=True)
        except subprocess.TimeoutExpired:
            print(f"[log-watch] repair.py timed out for {logfile}", flush=True)
        except Exception as e:
            print(f"[log-watch] repair.py error: {e}", flush=True)


def _check_stuck_phase4():
    """Independent check: is session stuck in Phase 4? If so, resolve."""
    phase = _session_phase()
    task_id = _session_task_id()
    if not task_id or phase not in ("implementing", "context_loaded"):
        return

    # Check log files for "waiting for implementation"
    found_waiting = False
    for watch_dir in WATCH_DIRS:
        if not os.path.isdir(watch_dir):
            continue
        for entry in sorted(os.listdir(watch_dir), reverse=True):
            fpath = os.path.join(watch_dir, entry)
            if "claude-dev-loop" not in entry or not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, "r") as f:
                    content = f.read()
                if "waiting for implementation" in content:
                    found_waiting = True
                    break
            except (OSError, IOError):
                continue
        if found_waiting:
            break

    if not found_waiting:
        return

    print(f"[log-watch][phase4] stuck detected: {task_id} (phase={phase})", flush=True)
    if _fix_counter_check():
        _resolve_stuck_phase4()


def poll_once():
    """Single poll cycle: scan log dirs, check for new lines, auto-repair."""
    now_ts = time.time()
    cutoff = now_ts - 300  # 5 minutes

    # ── Check for Phase 4 stuck state ──
    _check_stuck_phase4()

    # ── Normal: scan log dirs for new error lines ──
    for watch_dir in WATCH_DIRS:
        if not os.path.isdir(watch_dir):
            continue

        for entry in os.listdir(watch_dir):
            fpath = os.path.join(watch_dir, entry)
            if not fpath.endswith(".log") or not os.path.isfile(fpath):
                continue
            if os.path.getmtime(fpath) < cutoff:
                continue

            try:
                with open(fpath, "r") as f:
                    current_lines = sum(1 for _ in f)
            except (OSError, IOError):
                current_lines = 0

            prev_lines = _state_get_line(fpath)

            if current_lines > prev_lines > 0:
                try:
                    with open(fpath, "r") as f:
                        all_lines = f.readlines()
                    new_content = "".join(all_lines[prev_lines:])
                    if new_content.strip():
                        _auto_repair(fpath, new_content)
                except (OSError, IOError):
                    pass

            _state_set_line(fpath, current_lines)


def daemon_loop():
    """Continuous daemon loop (poll every 5s)."""
    pid_file = os.path.join(CACHE_DIR, "log-watch.pid")
    with open(pid_file, "w") as f:
        f.write(str(os.getpid()))
    import atexit
    def _cleanup():
        try:
            if os.path.exists(pid_file):
                os.unlink(pid_file)
        except OSError:
            pass
    atexit.register(_cleanup)
    print("[log-watch] daemon started (poll every 5s)", flush=True)
    while True:
        try:
            poll_once()
        except Exception as e:
            print(f"[log-watch] poll error: {e}", flush=True)
        time.sleep(5)


def main():
    if len(sys.argv) < 2:
        print("Usage: log_watch_daemon.py <poll|daemon>")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "poll":
        poll_once()
    elif cmd == "daemon":
        daemon_loop()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
