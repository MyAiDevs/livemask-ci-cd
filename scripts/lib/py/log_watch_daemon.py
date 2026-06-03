#!/usr/bin/env python3
"""
log_watch_daemon.py — Thin log monitor daemon.

Delegates ALL detection, classification, and action to self_heal.py.

This daemon's sole job is to:
  1. Watch log directories for new/modified log files
  2. Track line counts per file (so we only process NEW content)
  3. Call self_heal.py poll on each cycle
  4. Auto-reload when code changes (watchdog)

Usage:
    python3 log_watch_daemon.py poll           # Single poll cycle
    python3 log_watch_daemon.py daemon          # Continuous daemon loop

Effectively a thin wrapper — all intelligence lives in self_heal.py.
"""

import os
import subprocess
import sys
import time

from debug_utils import setup as _debug_setup, traced, logger as _logger

_debug_setup()

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude")
PY_DIR = os.path.join(
    os.environ.get("LIVEMASK_ROOT", os.path.expanduser("~/Developer/LiveMask")),
    "livemask-ci-cd", "scripts", "lib", "py"
)
SELF_HEAL = os.path.join(PY_DIR, "self_heal.py")
LINE_COUNTS_FILE = os.path.join(CACHE_DIR, "log-watch-lines.json")

WATCH_DIRS = ["/tmp/claude"]


def _load_json(path: str, default=None):
    import json
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default or {}


def _save_json(path: str, data):
    import json
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


@traced
def poll_once():
    """Single poll cycle: update line counts, then delegate to self_heal.py."""
    now_ts = time.time()
    cutoff = now_ts - 300  # 5 minutes

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
                continue
            prev_lines = _state_get_line(fpath)
            if current_lines > prev_lines and prev_lines > 0:
                # New content appeared — flag for self_heal
                pass
            _state_set_line(fpath, current_lines)

    # Delegate all detection/action to self_heal.py
    if os.path.exists(SELF_HEAL):
        try:
            r = subprocess.run(
                [sys.executable, SELF_HEAL, "poll"],
                capture_output=True, text=True, timeout=30,
            )
            if r.stdout.strip():
                print(f"[log-watch] self_heal: {r.stdout.strip()[:500]}", flush=True)
            if r.stderr.strip():
                print(f"[log-watch] self_heal(stderr): {r.stderr.strip()[:500]}", flush=True)
        except subprocess.TimeoutExpired:
            print(f"[log-watch] self_heal poll timed out", flush=True)
        except Exception as e:
            print(f"[log-watch] self_heal error: {e}", flush=True)
    else:
        print(f"[log-watch] self_heal.py not found — no action taken", flush=True)


@traced
def daemon_loop():
    """Continuous daemon loop (poll every 5s) with auto-reload."""
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

    # Auto-reload watchdog
    from watchdog import Watchdog
    w = Watchdog(poll_interval=60)
    w.watch(os.path.abspath(__file__))
    w.watch_dir(os.path.dirname(__file__))

    def _should_reload() -> bool:
        if w._reload_requested:
            return True
        for path, old_mtime in list(w._files.items()):
            try:
                if os.path.getmtime(path) != old_mtime:
                    print(f"[watchdog] {os.path.basename(path)} changed, reloading", flush=True)
                    return True
            except OSError:
                pass
        return False

    reload_counter = 0
    print("[log-watch] daemon started (poll 5s, delegate to self_heal.py)", flush=True)

    while True:
        reload_counter += 1
        if reload_counter >= 12:
            reload_counter = 0
            if _should_reload():
                w.restart()
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
