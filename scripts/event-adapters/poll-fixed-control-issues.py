#!/usr/bin/env python3
"""
Poll fixed control issues (#14 in livemask-ci-cd, #68 in livemask-docs) for new
comments. This is a polling adapter — it does NOT receive webhooks.

Phase 1: gh CLI polling with cursor-based dedup.

Design:
- First run per issue establishes cursor baseline (NO events emitted)
- Subsequent runs emit comment.created events only for new comments
- Cursor corruption triggers state.snapshot mode (NO incremental events)
- Uses adapter-lib.sh for cursor persistence and event writing

Usage:
  python3 poll-fixed-control-issues.py [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
ADAPTER_LIB = SCRIPT_DIR / "lib" / "adapter-lib.sh"
CI_CD_DIR = SCRIPT_DIR.parent.parent
LIVEMASK_ROOT = CI_CD_DIR.parent
EVENT_CACHE_DIR = Path.home() / ".claude" / "event-cache"
EVENT_CACHE_FILE = EVENT_CACHE_DIR / "event-cache.jsonl"
CURSOR_FILE = EVENT_CACHE_DIR / "adapter-cursors.json"
POLLER_NAME = "poll-fixed-control-issues"

# Fixed control issues (repo, issue_number)
FIXED_ISSUES = [
    ("MyAiDevs/livemask-ci-cd", 14),
    ("MyAiDevs/livemask-docs", 68),
]

# ── Helpers ──────────────────────────────────────────────────────────────────

def extract_comment_id(comment: dict) -> int | None:
    """Extract numeric comment ID from the comment URL.
    URL format: https://github.com/.../issues/N#issuecomment-4581501912
    """
    url = comment.get("url", "")
    if "issuecomment-" in url:
        try:
            return int(url.rsplit("issuecomment-", 1)[-1])
        except (ValueError, IndexError):
            pass
    return None


# Keywords from CLAUDE_LOOP_SUPERVISOR_RULES.md Section 1A
SUPERVISOR_KEYWORDS = [
    "PERMANENT_CHANNEL", "RULE_UPDATE", "ACTION_NEEDED", "ENFORCE",
    "PROCESS_DEFECT", "RUNTIME_STALE", "LEDGER_STALE",
    "WAIT_TASK", "WAIT_CI", "accepted-skip",
]


def shell(cmd: str, cwd: str | None = None) -> str:
    """Run a shell command and return stripped stdout. Raises on failure."""
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True,
        cwd=cwd or str(LIVEMASK_ROOT),
    )
    if result.returncode != 0:
        raise RuntimeError(f"Command failed (exit={result.returncode}): {cmd}\n{result.stderr[:500]}")
    return result.stdout.strip()


def load_cursors() -> dict:
    """Load cursor state from the cursor file."""
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


def get_comment_cursor(data: dict, repo: str, issue: int) -> int:
    """Get the last seen comment_id for an issue. Returns -1 if no cursor."""
    pollers = data.get("pollers", {})
    pc = pollers.get(POLLER_NAME, {})
    cursors = pc.get("cursors", {})
    entry = cursors.get(f"{repo}#{issue}", {})
    return entry.get("last_comment_id", -1)


def update_comment_cursor(data: dict, repo: str, issue: int, comment_id: int) -> dict:
    """Update cursor for an issue after processing."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data.setdefault("pollers", {}).setdefault(POLLER_NAME, {"last_run_ts": now, "cursors": {}})
    poller = data["pollers"][POLLER_NAME]
    poller["last_run_ts"] = now
    poller.setdefault("cursors", {})
    key = f"{repo}#{issue}"
    entry = poller["cursors"].setdefault(key, {"last_comment_id": 0, "total_comments_seen": 0})
    entry["last_comment_id"] = max(entry.get("last_comment_id", 0), comment_id)
    entry["total_comments_seen"] = entry.get("total_comments_seen", 0) + 1
    entry["last_checked_at"] = now
    poller.pop("error_state", None)
    return data


def generate_event_id() -> str:
    """Generate a unique event ID."""
    import random
    import string
    ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    rand = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
    return f"EVT-{rand}-{ts}"


def extract_keywords(body: str) -> list[str]:
    """Find supervisor keywords in a comment body."""
    found = []
    for kw in SUPERVISOR_KEYWORDS:
        if kw in body:
            found.append(kw)
    return found


def write_event(event: dict, dry_run: bool = False) -> None:
    """Write a single event to the event cache JSONL file."""
    if dry_run:
        print(f"  [dry-run] would write: {event['event_id']} ({event['event_type']})")
        return
    with open(EVENT_CACHE_FILE, "a") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
    print(f"  [event] wrote {event['event_id']} ({event['event_type']})", file=sys.stderr)


def poll(args: argparse.Namespace) -> int:
    """Main polling logic."""
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
                "reason": "Cursor file was corrupted or malformed. No incremental events will be produced until cursor is rebuilt.",
                "affected_poller": POLLER_NAME,
            }
        }
        write_event(event, args.dry_run)
        return 2

    new_events = 0

    for repo, issue_num in FIXED_ISSUES:
        try:
            comments_json = shell(
                f"gh issue view {issue_num} --repo {repo} --json comments --jq '.comments'"
            )
            comments = json.loads(comments_json)
        except (RuntimeError, json.JSONDecodeError) as e:
            print(f"  [error] Failed to fetch {repo}#{issue_num}: {e}", file=sys.stderr)
            continue

        if not comments:
            print(f"  {repo}#{issue_num}: no comments found", file=sys.stderr)
            continue

        last_cursor = get_comment_cursor(cursors, repo, issue_num)
        max_seen = last_cursor

        # First run: establish baseline, emit no events
        if last_cursor == -1:
            ids = [extract_comment_id(c) for c in comments]
            ids = [i for i in ids if i is not None]
            if ids:
                max_id = max(ids)
                print(f"  {repo}#{issue_num}: first run — establishing baseline at comment {max_id}", file=sys.stderr)
                cursors = update_comment_cursor(cursors, repo, issue_num, max_id)
                max_seen = max_id
            else:
                print(f"  {repo}#{issue_num}: first run — no comment IDs found", file=sys.stderr)
            continue

        for comment in comments:
            cid = extract_comment_id(comment)
            if cid is None:
                continue
            if cid <= last_cursor:
                continue  # already seen

            # New comment
            body = comment.get("body", "")
            body_len = len(body)
            truncated_body = body[:500]
            author = comment.get("author", {}).get("login", "unknown")
            keywords = extract_keywords(body)

            event = {
                "event_id": generate_event_id(),
                "event_type": "comment.created",
                "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "source": POLLER_NAME,
                "repo": repo,
                "priority": "high" if keywords else "normal",
                "comment": {
                    "issue_number": issue_num,
                    "comment_id": cid,
                    "comment_body": truncated_body,
                    "body_length": body_len,
                    "author": author,
                    "cursor_key": f"{repo}/{issue_num}/{cid}",
                    "keywords_matched": keywords,
                }
            }

            if args.dry_run:
                kw_str = f" [keywords: {','.join(keywords)}]" if keywords else ""
                print(f"  [dry-run] NEW COMMENT {repo}#{issue_num} comment_id={cid} by {author}{kw_str}")
                print(f"    body preview: {truncated_body[:100]}...")
            write_event(event, args.dry_run)
            new_events += 1
            max_seen = max(max_seen, cid)

        cursors = update_comment_cursor(cursors, repo, issue_num, max_seen)

    if not args.dry_run:
        save_cursors(cursors)

    if new_events > 0:
        print(f"  [{POLLER_NAME}] {new_events} new comment event(s)", file=sys.stderr)
        return 1
    else:
        print(f"  [{POLLER_NAME}] no new comments", file=sys.stderr)
        return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Poll fixed control issues for new comments")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would be emitted, do not write to cache or cursors")
    args = parser.parse_args()

    # Ensure cache directory exists
    EVENT_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    EVENT_CACHE_FILE.touch(exist_ok=True)

    exit_code = poll(args)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
