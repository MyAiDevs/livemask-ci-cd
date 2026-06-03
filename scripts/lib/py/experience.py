#!/usr/bin/env python3
"""
experience.py — Error → repair experience learning system.

Records every error encountered, the repair action taken, and whether it
succeeded. Over time, the system learns which fixes work for which error
patterns and auto-suggests proven fixes first.

Storage: ~/.claude/cache/experience.json

Usage:
    experience.py record    <error_pattern_or_log> <action_json> <success> [--repo R]
    experience.py suggest   <error_log_file>
    experience.py _apply    <suggest_json_file> [--repo R]
    experience.py stats

Output: JSON to stdout.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import time
from collections import defaultdict, Counter
from typing import Optional

from debug_utils import setup as _debug_setup, traced, logger as _logger

EXPERIENCE_FILE = os.path.join(os.path.expanduser("~"), ".claude", "cache", "experience.json")
MAX_RECORDS = 1000


# ── Error pattern fingerprinting ──────────────────────────────────────────
def fingerprint(log_text: str) -> str:
    """Fingerprint a log snippet to a canonical error pattern string."""
    text = log_text.strip()
    text = re.sub(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', '', text)
    text = re.sub(r'\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}', '', text)
    text = re.sub(r'\S+?\.go:\d+:\d+', '<file>.go', text)
    text = re.sub(r'\S+?\.tsx?:\d+:\d+', '<file>.ts', text)
    text = re.sub(r'\S+?\.dart:\d+:\d+', '<file>.dart', text)
    text = re.sub(r'\S+?/\S+?\.go', '<file>.go', text)
    text = re.sub(r'\S+?/\S+?\.tsx?', '<file>.ts', text)
    text = re.sub(r':\d+:', ':<line>:', text)
    text = re.sub(r'\(line \d+\)', '(line N)', text)
    text = re.sub(r'[0-9a-f]{7,40}', '<hash>', text)
    text = re.sub(r'v\d+\.\d+\.\d+', 'v<semver>', text)
    text = re.sub(r'\s+', ' ', text)
    return text[:200]


def _load() -> dict:
    if not os.path.exists(EXPERIENCE_FILE):
        return {"version": 2, "patterns": {}}
    try:
        with open(EXPERIENCE_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"version": 2, "patterns": {}}


def _save(data: dict):
    os.makedirs(os.path.dirname(EXPERIENCE_FILE), exist_ok=True)
    with open(EXPERIENCE_FILE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


PATTERN_NAMES = {
    "go_build": r'(\S+?\.go:\d+:\d+.*?error)',
    "go_mod": r'go:.*module.*not found',
    "npm_module": r"Module not found.*Can't resolve",
    "ts_error": r'TS\d+:',
    "flutter_error": r'Error:.*\.dart:',
}


def _detect_pattern_name(log_text: str) -> str:
    for name, regex in PATTERN_NAMES.items():
        if re.search(regex, log_text, re.IGNORECASE):
            return name
    return "unknown"


# ── Commands ───────────────────────────────────────────────────────────────

def cmd_record(args: list[str]) -> int:
    """experience.py record <error_pattern_or_log> <action_json> <success> [--repo R] [--tags T1,T2,...]"""
    if len(args) < 3:
        print(json.dumps({"error": "usage: record <error_or_log> <action_json> <0|1> [--repo R] [--tags T1,T2,...]"}))
        return 1

    error_input = args[0]
    action_raw = args[1]
    success = args[2] in ("1", "true", "yes")

    repo = ""
    tags = []
    if "--repo" in args:
        ri = args.index("--repo")
        if ri + 1 < len(args):
            repo = args[ri + 1]
    if "--tags" in args:
        ti = args.index("--tags")
        if ti + 1 < len(args):
            tags = [t.strip() for t in args[ti + 1].split(",") if t.strip()]

    if os.path.isfile(error_input):
        with open(error_input, "r") as f:
            log_content = f.read(5000)
    else:
        log_content = error_input

    fp = fingerprint(log_content)
    pattern_name = _detect_pattern_name(log_content)

    try:
        action = json.loads(action_raw)
    except json.JSONDecodeError:
        action = {"type": "unknown", "message": action_raw}

    # Auto-tag via tags.py if available
    if not tags and repo:
        try:
            tags_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tags.py")
            r = subprocess.run(
                [sys.executable, tags_script, "search", error_input if not os.path.isfile(error_input) else error_input[:200],
                 "--limit", "1"],
                capture_output=True, text=True, timeout=5,
            )
        except Exception:
            pass

    data = _load()
    patterns = data.setdefault("patterns", {})

    if fp not in patterns:
        patterns[fp] = {
            "fingerprint": fp,
            "pattern_name": pattern_name,
            "first_seen": time.time(),
            "last_seen": time.time(),
            "count": 0,
            "actions": [],
            "repo_hints": {},
        }

    entry = patterns[fp]
    entry["last_seen"] = time.time()
    entry["count"] += 1

    if repo:
        entry.setdefault("repo_hints", {})[repo] = entry["repo_hints"].get(repo, 0) + 1

    action_record = {
        "action": action,
        "success": success,
        "timestamp": time.time(),
        "repo": repo,
        "tags": tags,
    }
    entry["actions"].append(action_record)
    entry.setdefault("tags", {})
    for t in tags:
        entry["tags"][t] = entry["tags"].get(t, 0) + 1

    # Also write to tags.py system for cross-repo discovery
    if tags:
        try:
            tags_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tags.py")
            tid = fp[:40]  # Use fingerprint as item id
            tag_str = ",".join(tags)
            subprocess.run(
                [sys.executable, tags_script, "tag", tid, tag_str,
                 "--source", "experience", "--meta", f"pattern:{pattern_name}", "--meta", f"repo:{repo}"],
                capture_output=True, timeout=5,
            )
        except Exception:
            pass

    if len(entry["actions"]) > MAX_RECORDS:
        entry["actions"] = entry["actions"][-MAX_RECORDS:]

    _save(data)

    total = len(entry["actions"])
    successes = sum(1 for a in entry["actions"] if a["success"])

    print(json.dumps({
        "status": "ok",
        "fingerprint": fp[:60],
        "pattern_name": pattern_name,
        "total_attempts": total,
        "success_rate": round(successes / total, 2) if total > 0 else 0,
    }))
    return 0


def cmd_suggest(args: list[str]) -> int:
    """experience.py suggest <error_log_file>"""
    if not args:
        print(json.dumps({"error": "usage: suggest <error_log_file>"}))
        return 1

    log_path = args[0]
    if not os.path.isfile(log_path):
        print(json.dumps({"error": f"file not found: {log_path}"}))
        return 1

    with open(log_path, "r") as f:
        log_content = f.read(5000)

    fp = fingerprint(log_content)

    # Sub-fingerprints from each error line
    lines = log_content.split("\n")
    sub_fps = set()
    for line in lines:
        line = line.strip()
        if len(line) > 20 and ("error" in line.lower() or "fail" in line.lower()):
            sub_fps.add(fingerprint(line))

    data = _load()
    patterns = data.get("patterns", {})

    suggestions = []

    # Primary fingerprint match
    if fp in patterns:
        entry = patterns[fp]
        suggestions.extend(_score_actions(entry))

    # Sub-fingerprint matches
    for sfp in sub_fps:
        if sfp in patterns and sfp != fp:
            entry = patterns[sfp]
            suggestions.extend(_score_actions(entry))

    # Deduplicate
    seen_cmds = set()
    unique = []
    for s in suggestions:
        cmd = s.get("suggested_command", "")
        msg = s.get("message", "")
        dedup_key = f"{cmd}|{msg}"
        if dedup_key not in seen_cmds:
            seen_cmds.add(dedup_key)
            unique.append(s)

    unique.sort(key=lambda x: -x.get("confidence", 0))

    result = {
        "status": "ok" if unique else "no_experience",
        "fingerprint": fp[:60],
        "suggestions": unique[:5],
        "log_path": log_path,
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def _score_actions(entry: dict) -> list[dict]:
    """Compute confidence scores from action history."""
    actions = entry.get("actions", [])
    repo_group = defaultdict(list)
    for a in actions:
        key = json.dumps(a.get("action", {}), sort_keys=True)
        repo_group[key].append(a)

    scored = []
    for action_json, attempts in repo_group.items():
        total = len(attempts)
        successes = sum(1 for a in attempts if a["success"])
        success_rate = successes / total if total > 0 else 0
        action_obj = json.loads(action_json)

        recency_bonus = 0
        if attempts:
            last_ts = max(a["timestamp"] for a in attempts)
            hours_ago = (time.time() - last_ts) / 3600
            if hours_ago < 1:
                recency_bonus = 15
            elif hours_ago < 24:
                recency_bonus = 10
            elif hours_ago < 168:
                recency_bonus = 5

        confidence = min(int(success_rate * 70 + recency_bonus + min(total, 15)), 95)

        scored.append({
            "action_type": action_obj.get("type", "unknown"),
            "suggested_command": action_obj.get("cmd", ""),
            "message": action_obj.get("message", ""),
            "file": action_obj.get("file", ""),
            "confidence": confidence,
            "success_rate": round(success_rate, 2),
            "total_attempts": total,
            "successes": successes,
            "recency_hours": round((time.time() - entry.get("last_seen", 0)) / 3600, 1),
        })

    return scored


def cmd_apply(args: list[str]) -> int:
    """experience.py _apply <suggest_json_file> [--repo R]

    Reads a suggest.json file, auto-applies high-confidence fixes (>=70%),
    prints one line per action, and ends with HEALED=yes/no.
    Used to close the learning loop.
    """
    if not args:
        print("HEALED=no")
        return 1

    suggest_file = args[0]
    repo = ""
    for i in range(1, len(args)):
        if args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]

    if not os.path.isfile(suggest_file):
        print(f"File not found: {suggest_file}", file=sys.stderr)
        print("HEALED=no")
        return 1

    with open(suggest_file, "r") as f:
        data = json.load(f)

    suggestions = data.get("suggestions", [])
    if not suggestions:
        print("HEALED=no")
        return 0

    log_path = data.get("log_path", "")
    exp_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "experience.py")
    healed = False

    for s in suggestions:
        conf = s.get("confidence", 0)
        cmd = s.get("suggested_command", "")
        msg = s.get("message", "")[:60]
        print(f"  [{conf}%] {cmd or msg}")

        if conf >= 70 and cmd:
            try:
                r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
                if r.returncode == 0:
                    print(f"  ✓ auto-applied: {cmd}")
                    healed = True
                    subprocess.run(
                        [sys.executable, exp_script, "record",
                         log_path or suggest_file,
                         json.dumps({"type": "run", "cmd": cmd}), "1",
                         "--repo", repo],
                        capture_output=True, timeout=10,
                    )
                else:
                    print(f"  ✗ fix failed: {cmd} (rc={r.returncode})")
                    subprocess.run(
                        [sys.executable, exp_script, "record",
                         log_path or suggest_file,
                         json.dumps({"type": "run", "cmd": cmd}), "0",
                         "--repo", repo],
                        capture_output=True, timeout=10,
                    )
            except subprocess.TimeoutExpired:
                print(f"  ⚠ fix timeout: {cmd}")
            except Exception as e:
                print(f"  ⚠ fix error: {e}")

        # Handle edit-type actions: repair.py edit <file> --find <old> --replace <new>
        elif conf >= 70 and s.get("action_type") == "edit":
            file_path = s.get("file", "")
            find_str = s.get("message", "")
            if file_path and find_str:
                fix_cmd = (
                    f"{sys.executable} {os.path.join(os.path.dirname(exp_script), 'repair.py')} edit {file_path} "
                    f"--find {shlex.quote(find_str)} --replace {shlex.quote(cmd)}"
                )
                try:
                    r = subprocess.run(fix_cmd, shell=True, capture_output=True, text=True, timeout=30)
                    result_data = json.loads(r.stdout) if r.stdout.strip() else {}
                    if result_data.get("applied") or r.returncode == 0:
                        print(f"  ✓ auto-applied edit: {file_path}")
                        healed = True
                        subprocess.run(
                            [sys.executable, exp_script, "record",
                             log_path or suggest_file,
                             json.dumps({"type": "edit", "file": file_path}), "1",
                             "--repo", repo],
                            capture_output=True, timeout=10,
                        )
                    else:
                        print(f"  ✗ edit failed: {file_path} ({r.stderr[:100]})")
                        subprocess.run(
                            [sys.executable, exp_script, "record",
                             log_path or suggest_file,
                             json.dumps({"type": "edit", "file": file_path}), "0",
                             "--repo", repo],
                            capture_output=True, timeout=10,
                        )
                except Exception as e:
                    print(f"  ⚠ edit error: {e}")

    print(f"HEALED={'yes' if healed else 'no'}")
    return 0


def cmd_stats(args: list[str]) -> int:
    """experience.py stats — show learning stats"""
    data = _load()
    patterns = data.get("patterns", {})

    total_actions = 0
    total_successes = 0
    pattern_breakdown = Counter()

    for fp, entry in patterns.items():
        for a in entry.get("actions", []):
            total_actions += 1
            if a.get("success"):
                total_successes += 1
        pattern_name = entry.get("pattern_name", "unknown")
        pattern_breakdown[pattern_name] += len(entry.get("actions", []))

    print(json.dumps({
        "known_patterns": len(patterns),
        "total_experiences": total_actions,
        "total_successes": total_successes,
        "overall_success_rate": round(total_successes / total_actions, 2) if total_actions > 0 else 0,
        "pattern_breakdown": dict(pattern_breakdown.most_common()),
    }, indent=2))
    return 0


@traced
def main():
    _debug_setup()
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: experience.py <record|suggest|_apply|stats> [...]"}))
        sys.exit(1)
    if sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        sys.exit(0)

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "record": cmd_record,
        "suggest": cmd_suggest,
        "_apply": cmd_apply,
        "stats": cmd_stats,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        sys.exit(1)

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
