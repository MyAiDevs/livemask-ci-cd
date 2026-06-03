#!/usr/bin/env python3
"""webhook_consumer.py — Consume webhook inbox events for task intake.

Reads ~/.claude/role-cache/webhook-events/inbox.jsonl and processes
GitHub Issue events (issues, issue_comment, push) into task intake packets.
Eliminates the need for poll-based GitHub API calls.

Usage:
  python3 webhook_consumer.py process    # Process all new events
  python3 webhook_consumer.py daemon     # Run continuously (poll inbox every 5s)
  python3 webhook_consumer.py status     # Show box stats
  python3 webhook_consumer.py reset      # Reset cursor
"""
import json, os, sys, time, subprocess, pathlib

EVENT_DIR = pathlib.Path(os.path.expanduser("~/.claude/role-cache/webhook-events"))
CURSOR_FILE = EVENT_DIR / "consumer-cursor.txt"
INBOX_FILE = EVENT_DIR / "inbox.jsonl"
PY_DIR = pathlib.Path(__file__).resolve().parent
LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT",
    str(pathlib.Path(__file__).resolve().parent.parent.parent.parent.parent))


def _get_cursor():
    if CURSOR_FILE.exists():
        try: return int(CURSOR_FILE.read_text().strip())
        except: pass
    return 0

def _set_cursor(pos):
    CURSOR_FILE.write_text(str(pos))

def _run_py(script, *args):
    try:
        r = subprocess.run(
            [sys.executable, str(PY_DIR / script)] + list(args),
            capture_output=True, text=True, timeout=30,
        )
        return r.returncode == 0, r.stdout
    except Exception as e:
        return False, str(e)


def process_issue_event(evt):
    action = evt.get("action", "")
    repo = evt.get("repo", "")
    num = evt.get("issue_number")
    title = evt.get("issue_title", "")
    body = evt.get("issue_body", "")
    labels = [l.lower() for l in evt.get("labels", [])]

    if action not in ("opened", "labeled"):
        return False
    if "TASK-" in title:
        return False

    if "bug" in labels:
        args = ["bug", repo, title, body or ""]
    elif "requirement" in labels or "enhancement" in labels:
        args = ["requirement", repo, title, body or ""]
    elif "feature" in labels:
        args = ["feature", repo, title, body or ""]
    else:
        args = ["requirement", repo, title, body or ""]

    print(f"[consumer] intake: {repo}#{num} ({args[0]})", flush=True)
    ok, out = _run_py("task_intake.py", *args)
    if ok:
        print(f"[consumer] ok: {out.strip()[:200]}", flush=True)
    else:
        print(f"[consumer] err: {out.strip()[:200]}", flush=True)
    return True


def process_event(evt):
    source = evt.get("source", "")
    etype = evt.get("event", "")
    if source == "github_webhook":
        if etype == "issues":
            return process_issue_event(evt)
        elif etype == "push" and evt.get("branch") == "dev":
            print(f"[consumer] dev push to {evt['repo']} — triggering planner", flush=True)
            _run_py("planner.py", "plan",
                "--contracts", f"{LIVEMASK_ROOT}/livemask-docs/docs/contracts/contract-index.md",
                "--ledger", f"{LIVEMASK_ROOT}/livemask-docs/docs/development/task-state-ledger.json",
                "--tasks-dir", f"{LIVEMASK_ROOT}/livemask-docs/docs/development/tasks",
                "--create-dispatch", "5")
            return True
    return False


def cmd_process():
    cursor = _get_cursor()
    if not INBOX_FILE.exists():
        return 0
    try:
        with open(INBOX_FILE) as f:
            f.seek(cursor)
            n = 0
            for line in f:
                line = line.strip()
                if not line: continue
                try:
                    evt = json.loads(line)
                    if process_event(evt): n += 1
                except json.JSONDecodeError:
                    continue
            _set_cursor(f.tell())
        print(f"[consumer] processed {n} new events", flush=True)
        return n
    except Exception as e:
        print(f"[consumer] error: {e}", flush=True)
        return -1


def cmd_daemon():
    print(f"[consumer] daemon start — poll {INBOX_FILE}", flush=True)
    while True:
        try: cmd_process()
        except Exception as e: print(f"[consumer] daemon error: {e}", flush=True)
        time.sleep(5)


def cmd_status():
    cursor = _get_cursor()
    sz = INBOX_FILE.stat().st_size if INBOX_FILE.exists() else 0
    print(json.dumps({
        "status": "ok", "cursor": cursor,
        "inbox_bytes": sz, "pending": max(0, sz - cursor),
    }, indent=2))


def cmd_reset():
    _set_cursor(0)
    print("[consumer] cursor reset")


def main():
    if len(sys.argv) < 2:
        print("Usage: webhook_consumer.py {process|daemon|status|reset}"); return
    c = sys.argv[1]
    {"process": cmd_process, "daemon": cmd_daemon,
     "status": cmd_status, "reset": cmd_reset}.get(c, lambda: print(f"Unknown: {c}"))()


if __name__ == "__main__":
    sys.exit(main() or 0)
