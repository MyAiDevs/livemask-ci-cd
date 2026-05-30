#!/usr/bin/env python3
"""
Poll CI runs for target repos on the dev branch and emit ci.run.* events.

Phase 1: gh CLI polling with cursor-based dedup by (repo, run_id, head_sha).

Design:
- Polls 4 repos: livemask-docs, livemask-ci-cd, livemask-backend, livemask-admin
- First run per repo establishes cursor baseline (NO events emitted)
- Subsequent runs emit events for new/re-run workflows
- Cursor corruption triggers state.snapshot mode

Usage:
  python3 poll-ci-runs.py [--dry-run] [--repos REPO1,REPO2,...]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import string
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
CI_CD_DIR = SCRIPT_DIR.parent.parent
LIVEMASK_ROOT = CI_CD_DIR.parent
EVENT_CACHE_DIR = Path.home() / ".claude" / "event-cache"
EVENT_CACHE_FILE = EVENT_CACHE_DIR / "event-cache.jsonl"
CURSOR_FILE = EVENT_CACHE_DIR / "adapter-cursors.json"
POLLER_NAME = "poll-ci-runs"

# Repos to poll CI runs for
DEFAULT_REPOS = [
    "MyAiDevs/livemask-docs",
    "MyAiDevs/livemask-ci-cd",
    "MyAiDevs/livemask-backend",
    "MyAiDevs/livemask-admin",
]


def shell(cmd: str) -> str:
    """Run a shell command and return stripped stdout. Raises on failure."""
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True,
        cwd=str(LIVEMASK_ROOT),
    )
    if result.returncode != 0:
        raise RuntimeError(f"Command failed (exit={result.returncode}): {cmd}\n{result.stderr[:500]}")
    return result.stdout.strip()


def load_cursors() -> dict:
    """Load cursor state from disk."""
    if not CURSOR_FILE.exists():
        return {"schema_version": 1, "updated_at": "", "pollers": {}}
    try:
        with open(CURSOR_FILE) as f:
            data = json.load(f)
        if not isinstance(data, dict) or "pollers" not in data:
            raise ValueError("Invalid cursor structure")
        return data
    except (json.JSONDecodeError, ValueError) as e:
        print(f"  [cursor] CORRUPT: {e}", file=sys.stderr)
        return {"schema_version": 1, "updated_at": "", "pollers": {},
                "_corrupt": True}


def save_cursors(data: dict) -> None:
    """Atomically write cursor state."""
    data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data.pop("_corrupt", None)
    tmp = CURSOR_FILE.with_suffix(".tmp." + str(os.getpid()))
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    tmp.rename(CURSOR_FILE)


def get_ci_cursor(data: dict, repo: str) -> dict:
    """Get cursor state for a repo's CI runs."""
    pollers = data.get("pollers", {})
    pc = pollers.get(POLLER_NAME, {})
    cursors = pc.get("cursors", {})
    return cursors.get(repo, {})


def update_ci_cursor(data: dict, repo: str, run_id: int, head_sha: str,
                     status: str, conclusion: str | None) -> dict:
    """Update cursor for a repo after processing its runs."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data.setdefault("pollers", {}).setdefault(POLLER_NAME, {"last_run_ts": now, "cursors": {}})
    poller = data["pollers"][POLLER_NAME]
    poller["last_run_ts"] = now
    poller.setdefault("cursors", {})
    entry = poller["cursors"].setdefault(repo, {
        "last_run_id": 0, "last_head_sha": "", "total_runs_seen": 0
    })
    current_id = entry.get("last_run_id", 0)
    if run_id >= current_id:
        entry["last_run_id"] = run_id
        entry["last_head_sha"] = head_sha
        entry["last_status"] = status
        entry["last_conclusion"] = conclusion
        entry["total_runs_seen"] = entry.get("total_runs_seen", 0) + 1
        entry["last_checked_at"] = now
    poller.pop("error_state", None)
    return data


def generate_event_id() -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    rand = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
    return f"EVT-{rand}-{ts}"


def event_type_for(status: str, conclusion: str | None) -> str:
    """Map CI status+conclusion to an event_type."""
    if conclusion in ("failure", "cancelled", "timed_out"):
        return "ci.run.failure"
    if conclusion == "success":
        return "ci.run.completed"
    if status in ("queued", "waiting", "pending"):
        return "ci.run.queued"
    if status == "in_progress":
        return "ci.run.in_progress"
    return "ci.run.in_progress"  # default


def write_event(event: dict, dry_run: bool = False) -> None:
    if dry_run:
        print(f"  [dry-run] would write: {event['event_id']} ({event['event_type']})")
        return
    with open(EVENT_CACHE_FILE, "a") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
    print(f"  [event] wrote {event['event_id']} ({event['event_type']})", file=sys.stderr)


def is_duplicate_run(cursor: dict, run_id: int, head_sha: str) -> bool:
    """Check if a run has already been seen by (run_id, head_sha) pair."""
    if not cursor:
        return True  # first run, establish baseline
    last_id = cursor.get("last_run_id", -1)
    last_sha = cursor.get("last_head_sha", "")
    if last_id == -1:
        return True
    return run_id == last_id and head_sha == last_sha


def poll(args: argparse.Namespace) -> int:
    cursors = load_cursors()
    is_corrupt = cursors.pop("_corrupt", False)

    if is_corrupt:
        print("  [snapshot] cursor file corrupt — entering snapshot mode", file=sys.stderr)
        event = {
            "event_id": generate_event_id(),
            "event_type": "state.snapshot",
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "source": POLLER_NAME,
            "priority": "low",
            "snapshot": {
                "reason": "Cursor file was corrupted or malformed.",
                "affected_poller": POLLER_NAME,
            }
        }
        write_event(event, args.dry_run)
        return 2

    new_events = 0
    repos = args.repos.split(",") if args.repos else DEFAULT_REPOS

    for repo in repos:
        try:
            runs_json = shell(
                f"gh run list --repo {repo} --branch dev --limit 10 "
                f"--json databaseId,status,conclusion,headSha,workflowName,url,createdAt"
            )
            runs = json.loads(runs_json)
        except (RuntimeError, json.JSONDecodeError) as e:
            print(f"  [error] Failed to fetch runs for {repo}: {e}", file=sys.stderr)
            continue

        if not runs:
            print(f"  {repo}: no dev runs found", file=sys.stderr)
            continue

        cursor = get_ci_cursor(cursors, repo)
        max_run_id = cursor.get("last_run_id", 0)
        first_run = not cursor

        # First run: establish baseline, emit no events
        if first_run:
            max_id = max(r["databaseId"] for r in runs if "databaseId" in r)
            last_run = runs[0]  # runs are sorted desc by default
            sha = (last_run.get("headSha", "") or "")[:40]
            status = last_run.get("status", "unknown")
            conclusion = last_run.get("conclusion")
            print(f"  {repo}: first run — establishing baseline at run {max_id}", file=sys.stderr)
            cursors = update_ci_cursor(cursors, repo, max_id, sha, status, conclusion)
            continue

        for run in runs:
            run_id = run.get("databaseId")
            head_sha = (run.get("headSha", "") or "")[:40]
            status = run.get("status", "unknown")
            conclusion = run.get("conclusion")
            workflow_name = run.get("workflowName", "unknown")
            url = run.get("url", "")
            created_at = run.get("createdAt", "")

            if run_id is None:
                continue

            # Dedup: skip if same run_id AND same head_sha as cursor
            if run_id == cursor.get("last_run_id") and head_sha == cursor.get("last_head_sha"):
                continue

            # Only emit events for runs newer than our cursor baseline
            if run_id <= cursor.get("last_run_id", 0):
                continue

            etype = event_type_for(status, conclusion)
            priority = "high" if etype == "ci.run.failure" else "normal"

            event = {
                "event_id": generate_event_id(),
                "event_type": etype,
                "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "source": POLLER_NAME,
                "repo": repo,
                "priority": priority,
                "ci": {
                    "run_id": run_id,
                    "head_sha": head_sha,
                    "workflow_name": workflow_name,
                    "status": status,
                    "conclusion": conclusion,
                    "url": url,
                    "created_at": created_at,
                }
            }

            if args.dry_run:
                print(f"  [dry-run] {etype.upper()} {repo} run={run_id} sha={head_sha[:7]} {workflow_name} ({status}/{conclusion})")
            write_event(event, args.dry_run)
            new_events += 1
            max_run_id = max(max_run_id, run_id)

        # Update cursor to the latest run
        if runs:
            last = runs[0]
            sha = (last.get("headSha", "") or "")[:40]
            status = last.get("status", "unknown")
            conclusion = last.get("conclusion")
            cursors = update_ci_cursor(cursors, repo, max_run_id, sha, status, conclusion)

    if not args.dry_run:
        save_cursors(cursors)

    if new_events > 0:
        print(f"  [{POLLER_NAME}] {new_events} new CI event(s)", file=sys.stderr)
        return 1
    else:
        print(f"  [{POLLER_NAME}] no new CI runs", file=sys.stderr)
        return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Poll CI runs for target repos on dev branch")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would be emitted, do not write to cache or cursors")
    parser.add_argument("--repos", type=str,
                        help="Comma-separated list of repos to poll (default: docs,ci-cd,backend,admin)")
    args = parser.parse_args()

    EVENT_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    EVENT_CACHE_FILE.touch(exist_ok=True)

    exit_code = poll(args)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
