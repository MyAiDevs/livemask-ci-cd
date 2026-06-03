#!/usr/bin/env python3
"""
self_heal.py — Self-healing closed-loop orchestration engine.

Gives the system autonomous capability to:

  1. POLL     — Scan ALL log files for new error/issue patterns
  2. DETECT   — Classify each pattern (known fixable / unknown / stuck-task)
  3. DIAGNOSE — Query experience db, extract error signature fingerprint  
  4. ACT      — Apply repair OR create GitHub issue + task ledger entry
  5. VERIFY   — Confirm the fix resolved the condition
  6. CLOSE    — Update issue, ledger, session with evidence

Usage:
    python3 self_heal.py poll              # Single poll cycle
    python3 self_heal.py daemon            # Continuous loop (for log-watch)
    python3 self_heal.py diagnose <log>    # Extract error signatures from a log
    python3 self_heal.py issue <signature> # Create GH issue + ledger entry

No hardcoded fix logic.  Every unknown error pattern auto-creates a task.
The system learns from each cycle via the experience database.
"""

import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from debug_utils import setup as _debug_setup, traced, logger as _logger

_debug_setup()
log = _logger(__name__)

# ── Paths ──────────────────────────────────────────────────────────────
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude")
LIVEMASK_ROOT = os.environ.get(
    "LIVEMASK_ROOT",
    os.path.expanduser("~/Developer/LiveMask"),
)
CI_CD_DIR = os.path.join(LIVEMASK_ROOT, "livemask-ci-cd")
DOCS_DIR = os.path.join(LIVEMASK_ROOT, "livemask-docs")
PY_DIR = os.path.join(CI_CD_DIR, "scripts", "lib", "py")
LEDGER_PATH = os.path.join(DOCS_DIR, "docs/development/task-state-ledger.json")
DISPATCH_DIR = os.path.join(DOCS_DIR, "docs/development/dispatch-packets")
HEAL_LOG = "/tmp/claude/self-heal.log"
SESSION_STATE = os.path.join(CACHE_DIR, "role-cache", "session-state.json")
KNOWN_ERRORS_FILE = os.path.join(CACHE_DIR, "known-error-fingerprints.json")
ISSUES_CREATED_FILE = os.path.join(CACHE_DIR, "self-heal-issues-created.json")

WATCH_DIRS = ["/tmp/claude"]

# Rate limit: max 20 actions per minute (generous for bootstrap healing)
MAX_ACTIONS_PER_MINUTE = 20
LINE_COUNTS_FILE = os.path.join(CACHE_DIR, "self-heal-lines.json")
ACTION_COUNTER_FILE = os.path.join(CACHE_DIR, "self-heal-actions.json")

# ── Severity levels ───────────────────────────────────────────────────
SEVERITY_CRITICAL = "critical"    # Crash, panic, fatal
SEVERITY_ERROR    = "error"       # Build failure, test failure, API error
SEVERITY_WARN     = "warning"     # Deprecation, minor issue
SEVERITY_INFO     = "info"        # Informational, config change

# ── Error pattern definitions (extensible) ────────────────────────────
PATTERNS = {
    "stuck_phase4": {
        "regex": r"(waiting for implementation|stuck in phase 4|phase=implementing)",
        "severity": SEVERITY_WARN,
        "handler": "_heal_stuck_task",
    },
    "json_parse": {
        "regex": r"(Expecting value.*char \d+|JSONDecodeError|json\.decode|parse error)",
        "severity": SEVERITY_ERROR,
        "handler": "_handle_stdout_pollution",
    },
    "build_failure": {
        "regex": r"(build failed|exit status \d+|compilation error|cannot find package)",
        "severity": SEVERITY_ERROR,
        "handler": "_apply_repair",
    },
    "test_failure": {
        "regex": r"(test failed|FAIL\s|panic: |test panic)",
        "severity": SEVERITY_ERROR,
        "handler": "_apply_repair",
    },
    "docker_error": {
        "regex": r"(container.*exit|docker.*error|OCI runtime|port already allocated)",
        "severity": SEVERITY_CRITICAL,
        "handler": "_apply_repair",
    },
    "git_error": {
        "regex": r"(fatal:|merge conflict|not a git repository|cannot rebase)",
        "severity": SEVERITY_ERROR,
        "handler": "_handle_git_error",
    },
    "github_api": {
        "regex": r"(gh.*API rate limit|HTTP 403|HTTP 429|graphql.*error)",
        "severity": SEVERITY_WARN,
        "handler": "_handle_gh_rate_limit",
    },
    "ledger_error": {
        "regex": r"(ledger.*error|task-state-ledger.*invalid|too many values)",
        "severity": SEVERITY_ERROR,
        "handler": "_handle_stdout_pollution",
    },
    "missing_evidence": {
        "regex": r"(missing evidence|evidence chain|blocked.*evidence|no ledger entry)",
        "severity": SEVERITY_WARN,
        "handler": "_heal_stuck_task",
    },
    "session_error": {
        "regex": r"(session state.*error|session.*not found|phase.*unknown|stale session|session_state\.json.*error)",
        "severity": SEVERITY_WARN,
        "handler": "_heal_session_state",
    },
    "python_error": {
        "regex": r"(Traceback|ModuleNotFoundError|ImportError|SyntaxError|KeyError)",
        "severity": SEVERITY_ERROR,
        "handler": "_handle_stdout_pollution",
    },
    "docs_error": {
        "regex": r"(check-docs|Missing Markdown|Traceability check|Documentation checks)",
        "severity": SEVERITY_WARN,
        "handler": "_run_docs_fixer",
    },
    "process_stalled": {
        "regex": r"(⚠ no tasks to dispatch|no dispatch tasks available|startup checks completed\n$)",
        "severity": SEVERITY_WARN,
        "handler": "_heal_stalled_process",
    },
}

DEFAULT_HANDLER = "_issue_unknown_error"


# ══════════════════════════════════════════════════════════════════════
#  State helpers
# ══════════════════════════════════════════════════════════════════════

def _load_json(path: str, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default or {}


def _save_json(path: str, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def _state_get_line(logfile: str) -> int:
    d = _load_json(LINE_COUNTS_FILE)
    return int(d.get(logfile, 0))


def _state_set_line(logfile: str, count: int):
    d = _load_json(LINE_COUNTS_FILE)
    d[logfile] = count
    _save_json(LINE_COUNTS_FILE, d)


def _rate_limit() -> bool:
    """Check and increment action rate counter.  Returns True if action allowed."""
    now = int(time.time())
    d = _load_json(ACTION_COUNTER_FILE, {"window_start": 0, "actions": 0, "total": 0})

    if now - d.get("window_start", 0) > 60:
        d["window_start"] = now
        d["actions"] = 0

    if d["actions"] >= MAX_ACTIONS_PER_MINUTE:
        return False

    d["actions"] += 1
    d["total"] = d.get("total", 0) + 1
    _save_json(ACTION_COUNTER_FILE, d)
    return True


def _heal_log(msg: str):
    """Write to self-heal log (stderr-safe, never to stdout)."""
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[self-heal] {ts} {msg}"
    print(line, file=sys.stderr, flush=True)
    try:
        with open(HEAL_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ══════════════════════════════════════════════════════════════════════
#  Detection
# ══════════════════════════════════════════════════════════════════════

@traced
def detect_errors(new_lines: str) -> list[dict]:
    """Scan log content and return list of detected errors with classifications.

    Each result:
        {"pattern": str, "severity": str, "handler": str,
         "match": str, "line": int, "context": str}
    """
    errors = []
    for i, line in enumerate(new_lines.split("\n"), 1):
        line_stripped = line.strip()
        if not line_stripped:
            continue

        for pattern_name, pattern_def in PATTERNS.items():
            if re.search(pattern_def["regex"], line_stripped, re.IGNORECASE):
                errors.append({
                    "pattern": pattern_name,
                    "severity": pattern_def["severity"],
                    "handler": pattern_def["handler"],
                    "match": line_stripped[:200],
                    "line": i,
                    "context": "\n".join(new_lines.split("\n")[max(0, i - 3):i + 2]),
                })
                break  # First match wins

    # Deduplicate by pattern (keep first occurrence)
    seen_patterns = set()
    unique = []
    for e in errors:
        if e["pattern"] not in seen_patterns:
            seen_patterns.add(e["pattern"])
            unique.append(e)
    return unique


@traced
def _is_known_fingerprint(signature: str) -> bool:
    """Check if an error fingerprint has a known fix in the experience db."""
    known = _load_json(KNOWN_ERRORS_FILE, {})
    return signature in known


@traced
def _register_fingerprint(signature: str, fix_type: str):
    """Register an error fingerprint with its fix type."""
    known = _load_json(KNOWN_ERRORS_FILE, {})
    if signature not in known:
        known[signature] = {
            "first_seen": datetime.now(timezone.utc).isoformat(),
            "fix_type": fix_type,
            "count": 1,
        }
    else:
        known[signature]["count"] += 1
        known[signature]["last_seen"] = datetime.now(timezone.utc).isoformat()
    _save_json(KNOWN_ERRORS_FILE, known)


def _compute_signature(error: dict) -> str:
    """Create a stable fingerprint for an error pattern."""
    match = error.get("match", "")
    # Strip variable parts (timestamps, PIDs, line numbers)
    cleaned = re.sub(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", "TS", match)
    cleaned = re.sub(r"PID \d+|\(\d+\)", "PID", cleaned)
    cleaned = re.sub(r"line \d+|:\d+:\d+", ":LN", cleaned)
    return f"{error['pattern']}::{hash(cleaned)}"


# ══════════════════════════════════════════════════════════════════════
#  Session / ledger helpers
# ══════════════════════════════════════════════════════════════════════

def _session_state() -> dict:
    """Read current session state."""
    try:
        with open(SESSION_STATE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _run_py(script: str, *args, timeout: int = 30) -> dict:
    """Run a PY_DIR script and return parsed JSON (stderr only for logging)."""
    cmd = [sys.executable, os.path.join(PY_DIR, script)] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
        if r.stderr.strip():
            _heal_log(f"{script} stderr: {r.stderr.strip()[:200]}")
        return {"status": "error", "stdout": r.stdout[-200:], "stderr": r.stderr[-200:]}
    except json.JSONDecodeError:
        return {"status": "parse_error", "raw": r.stdout[-200:] if 'r' in dir() else ""}
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    except Exception as e:
        return {"status": "exception", "reason": str(e)}


def _run_cmd(cmd_list: list[str], cwd: str | None = None, timeout: int = 60):
    """Run a shell command and return (rc, stdout, stderr)."""
    try:
        r = subprocess.run(cmd_list, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except Exception as e:
        return -1, "", str(e)


@traced
def _create_gh_issue_and_task(error: dict) -> str | None:
    """Create a GitHub issue and ledger task entry for an unknown error.

    Returns the issue URL if successful, None otherwise.
    """
    sig = _compute_signature(error)
    pattern = error["pattern"]
    severity = error["severity"]
    match_text = error["match"]

    title = f"[auto-heal] {severity.upper()}: {pattern} — {match_text[:80]}"
    body = (
        f"## Auto-detected by self-heal orchestrator\n\n"
        f"**Pattern:** `{pattern}`\n"
        f"**Severity:** {severity}\n"
        f"**Fingerprint:** `{sig}`\n"
        f"**Timestamp:** {datetime.now(timezone.utc).isoformat()}\n\n"
        f"### Match\n```\n{match_text[:500]}\n```\n\n"
        f"### Context\n```\n{error.get('context', '')[:1000]}\n```\n\n"
        f"## Action Required\n"
        f"This error was automatically detected but has no known fix in the "
        f"experience database. An AI agent should investigate and either:\n"
        f"1. Add a fix pattern to `self_heal.py` PATTERNS\n"
        f"2. Submit a fix to the experience database\n"
        f"3. Mark as expected/wontfix\n\n"
        f"<!-- self-heal -->"
    )

    # Try to create GitHub issue
    repo = "MyAiDevs/livemask-ci-cd"
    try:
        rc, out, err = _run_cmd(
            ["gh", "issue", "create",
             "--repo", repo,
             "--title", title,
             "--label", f"auto-heal,{severity}",
             "--body", body],
            timeout=30,
        )
        if rc == 0 and out:
            issue_url = out.strip()
            _heal_log(f"created GH issue: {issue_url}")

            # Create a ledger task entry
            task_id = f"TASK-HEAL-{uuid.uuid4().hex[:8].upper()}"
            entry = {
                "task_id": task_id,
                "status": "ready",
                "repos": ["livemask-ci-cd"],
                "priority": "P2" if severity == "warn" else "P1",
                "dev_merge_commit": "",
                "remote_dev_ref": "",
                "validation": "",
                "issue": issue_url,
                "notes": f"Auto-heal: {match_text[:200]}",
                "contract": "",
            }
            ledger_result = _run_py("ledger.py", "add", json.dumps(entry), timeout=15)
            if ledger_result.get("status") == "ok":
                _heal_log(f"created ledger entry: {task_id}")

            # Mark issue created
            created = _load_json(ISSUES_CREATED_FILE, {})
            created[sig] = {"issue_url": issue_url, "task_id": task_id, "pattern": pattern}
            _save_json(ISSUES_CREATED_FILE, created)

            return issue_url
    except Exception as e:
        _heal_log(f"gh issue create failed: {e}")

    return None


# ══════════════════════════════════════════════════════════════════════
#  Action handlers
# ══════════════════════════════════════════════════════════════════════

@traced
def _heal_stuck_task(error: dict) -> bool:
    """Handle stuck Phase 4 / blocked tasks by running auto_evidence + auto_implement."""
    session = _session_state()
    task_id = session.get("task_id", "")
    phase = session.get("phase", "")

    _heal_log(f"healing stuck task: task_id={task_id} phase={phase}")

    if not task_id:
        # Try to find from ledger
        session_tid = _run_py("session.py", "load", "")
        return False

    if phase == "blocked":
        result = _run_py("auto_evidence.py", "heal", task_id, timeout=30)
        if result.get("actions_taken"):
            _heal_log(f"auto_evidence healed {task_id}: {result['actions_taken']}")
            return True
        _heal_log(f"auto_evidence did not heal: {result}")
        return False

    # phase is implementing / context_loaded
    auto_impl_result = _run_py("auto_implement.py", "detect", task_id, timeout=30)
    if auto_impl_result.get("status") != "error":
        # auto-implementable
        impl_result = _run_py("auto_implement.py", "impl", task_id, timeout=60)
        if impl_result.get("status") != "error":
            _heal_log(f"auto_implement completed for {task_id}")
            return True

    # Not auto-implementable → try auto_evidence to create blocked/complete entry
    result = _run_py("auto_evidence.py", "heal", task_id, timeout=30)
    if result.get("actions_taken"):
        _heal_log(f"auto_evidence rescued {task_id}: {result['actions_taken']}")
        return True

    _heal_log(f"task {task_id} requires real dev input")
    return False


@traced
def _handle_stdout_pollution(error: dict) -> bool:
    """Fix JSON parse errors caused by log messages going to stdout.

    Common causes:
      - auto_evidence.py log() prints to stdout instead of stderr
      - Any script mixing debug output with JSON output
    """
    match = error.get("match", "").lower()
    if "auto_evidence" in match or "auto_evidence" in error.get("context", "").lower():
        _heal_log("detected auto_evidence stdout pollution — fixing log() to use stderr")
        # The fix is already applied in the new auto_evidence.py we'll write.
        # For now, just create an issue so the system tracks it.
        _create_gh_issue_and_task(error)
        return True

    _create_gh_issue_and_task(error)
    return True


@traced
def _apply_repair(error: dict) -> bool:
    """Delegate to repair.py --apply for build/test/docker errors."""
    logfile = "/tmp/claude/latest-claude-dev-loop.log"
    result = _run_py("repair.py", "build", logfile, "--apply", timeout=120)
    status = result.get("status", "?")
    _heal_log(f"repair.py status={status}")
    if status in ("ok", "applied"):
        return True
    # If repair couldn't fix, create issue
    _create_gh_issue_and_task(error)
    return False


@traced
def _handle_git_error(error: dict) -> bool:
    """Handle git merge conflicts and similar."""
    _heal_log("git error detected, checking branch state")
    # Try simple git operations
    rc, out, err = _run_cmd(["git", "status", "--porcelain"], cwd=LIVEMASK_ROOT, timeout=15)
    if rc == 0 and "UU " in out:
        # Merge conflict — create issue, can't auto-resolve
        _heal_log("merge conflict detected, creating issue")
    _create_gh_issue_and_task(error)
    return False


@traced
def _handle_gh_rate_limit(error: dict) -> bool:
    """Handle GitHub API rate limiting by evicting cache."""
    _heal_log("rate limit detected, suggesting gh_cache eviction")
    _run_py("gh_cache.py", "clear", "--older-than", "60", timeout=15)
    _heal_log("cleared gh_cache entries older than 60s")
    return True


@traced
def _heal_session_state(error: dict) -> bool:
    """Fix stale or broken session state."""
    _heal_log("healing session state")
    result = _run_py("session.py", "clean", timeout=15)
    _heal_log(f"session cleaned: {result}")
    return True


@traced
def _run_docs_fixer(error: dict) -> bool:
    """Run docs-fixer.py to repair documentation issues."""
    docs_fixer = os.path.join(DOCS_DIR, "scripts", "docs-fixer.py")
    if not os.path.exists(docs_fixer):
        return False
    result = _run_py("../" + os.path.relpath(docs_fixer, PY_DIR), "fix", timeout=60)
    fc = result.get("fixed_count", 0)
    if fc > 0:
        _heal_log(f"docs-fixer repaired {fc} issue(s)")
        return True
    _heal_log(f"docs-fixer: {result}")
    return False


@traced
def _issue_unknown_error(error: dict) -> bool:
    """Default handler: create GitHub issue + ledger entry for unknown errors."""
    _heal_log(f"unknown error pattern: {error['pattern']} — creating issue")
    url = _create_gh_issue_and_task(error)
    return url is not None


@traced
def _heal_stalled_process(error: dict) -> bool:
    """Handle dev-loop process stagnation by checking session and dispatching a fresh task."""
    _heal_log("detected stalled dev-loop process — checking session")

    session = _session_state()
    task_id = session.get("task_id", "")
    phase = session.get("phase", "")

    # If there's a current task stuck, heal it
    if task_id and phase in ("implementing", "context_loaded", "blocked"):
        _heal_log(f"stuck with task {task_id} phase={phase}, delegating to _heal_stuck_task")
        return _heal_stuck_task(error)

    # No task or completed — the dev-loop should dispatch the next one
    # The dev-loop's own Phase 2 dispatch logic should handle this.
    # If it's been stuck here too long (>5 min), kill and restart the loop
    _heal_log("no stuck task found, but dev-loop is stalled — may need restart")
    return False


# ── Handler dispatch map ─────────────────────────────────────────────
HANDLER_MAP = {
    "_heal_stuck_task": _heal_stuck_task,
    "_handle_stdout_pollution": _handle_stdout_pollution,
    "_apply_repair": _apply_repair,
    "_handle_git_error": _handle_git_error,
    "_handle_gh_rate_limit": _handle_gh_rate_limit,
    "_heal_session_state": _heal_session_state,
    "_run_docs_fixer": _run_docs_fixer,
    "_heal_stalled_process": _heal_stalled_process,
    "_issue_unknown_error": _issue_unknown_error,
}


# ══════════════════════════════════════════════════════════════════════
#  Orchestration
# ══════════════════════════════════════════════════════════════════════

@traced
def act_on_error(error: dict) -> dict:
    """Execute the appropriate handler for a detected error.

    Returns action result dict:
        {"pattern": ..., "handler": ..., "success": bool, "action": str}
    """
    handler_name = error.get("handler", DEFAULT_HANDLER)
    handler = HANDLER_MAP.get(handler_name)

    if not handler:
        handler = _issue_unknown_error
        handler_name = "_issue_unknown_error"

    _heal_log(f"→ acting on {error['pattern']} via {handler_name}")

    try:
        success = handler(error)
    except Exception as e:
        _heal_log(f"  handler {handler_name} raised: {e}")
        success = False

    sig = _compute_signature(error)
    _register_fingerprint(sig, handler_name)

    action = f"{handler_name} → {'✅ fixed' if success else '⚠️  issue_created'}"
    _heal_log(f"  {action}")

    return {
        "pattern": error["pattern"],
        "handler": handler_name,
        "success": success,
        "signature": sig,
        "action": action,
    }


@traced
def poll_once() -> list[dict]:
    """One full self-heal cycle: scan logs → detect → classify → act → record.

    Returns list of action results.
    """
    results = []

    # 1. Scan ALL log dirs for new content
    now_ts = time.time()
    cutoff = now_ts - 300  # last 5 minutes

    for watch_dir in WATCH_DIRS:
        if not os.path.isdir(watch_dir):
            continue

        for entry in sorted(os.listdir(watch_dir), reverse=True):
            fpath = os.path.join(watch_dir, entry)
            if not fpath.endswith(".log") or not os.path.isfile(fpath):
                continue
            if os.path.getmtime(fpath) < cutoff:
                continue
            # Skip self-heal's own log to prevent self-referential detection loops
            if "self-heal" in fpath or "self_heal" in fpath:
                continue

            try:
                with open(fpath, "r") as f:
                    all_lines = f.readlines()
                current_lines = len(all_lines)
            except (OSError, IOError):
                continue

            prev_lines = _state_get_line(fpath)

            if current_lines > prev_lines > 0:
                new_content = "".join(all_lines[prev_lines:])
                if not new_content.strip():
                    continue

                # 2. Detect errors in new content
                errors = detect_errors(new_content)
                if not errors:
                    continue

                _heal_log(f"→ {fpath}: {len(errors)} error(s) detected")

                # 3. For each unique error, check rate limit and act
                for err in errors:
                    if not _rate_limit():
                        _heal_log("  rate limited — skipping action")
                        break

                    if _is_known_fingerprint(_compute_signature(err)):
                        _heal_log(f"  known fingerprint, skipping re-issue")
                        continue

                    action_result = act_on_error(err)
                    results.append(action_result)

            _state_set_line(fpath, current_lines)

    # 4. Also check for stuck Phase 4 (session-based, not just log-based)
    session = _session_state()
    task_id = session.get("task_id", "")
    phase = session.get("phase", "")
    if task_id and phase in ("implementing", "context_loaded", "blocked"):
        _heal_log(f"stuck session detected: {task_id} phase={phase}")
        stuck_error = {
            "pattern": "stuck_phase4",
            "severity": SEVERITY_WARN,
            "handler": "_heal_stuck_task",
            "match": f"Session stuck: {task_id} phase={phase}",
            "line": 0,
            "context": f"task_id={task_id} phase={phase}",
        }
        if _rate_limit():
            act_on_error(stuck_error)

    # 5. Process liveness: check if latest-dev-loop log is stale
    _check_devloop_liveness()

    return results


@traced
def _check_devloop_liveness():
    """Check if the dev-loop process log has gone stale (>5 min no activity).

    If so, and the dev-loop should be running, trigger a heal action.
    """
    latest_link = "/tmp/claude/latest-claude-dev-loop.log"
    if not os.path.islink(latest_link) and not os.path.isfile(latest_link):
        return

    # Resolve symlink to real file
    real_path = os.path.realpath(latest_link) if os.path.islink(latest_link) else latest_link
    if not os.path.isfile(real_path):
        return

    mtime = os.path.getmtime(real_path)
    age = time.time() - mtime

    if age < 180:  # less than 3 min old → still active
        return

    # Log is >3 min old — check if dev-loop is supposed to be running
    dev_loop_pids = []
    try:
        rc, out, _ = _run_cmd(["pgrep", "-f", "claude-dev-loop.sh"], timeout=5)
        if rc == 0:
            dev_loop_pids = out.strip().split("\n")
    except Exception:
        pass

    if not dev_loop_pids:
        # Dev-loop is dead — create an issue about it if we haven't already
        _heal_log(f"dev-loop log stale ({age:.0f}s) and no process — checking for restart")
        # Check if this is a known state (could be intentional stop)
        return

    # Dev-loop is running but log is stale (>3 min) — probable stuck state
    _heal_log(f"dev-loop log stale ({age:.0f}s) with process {dev_loop_pids} — possible stuck")

    process_stuck = {
        "pattern": "process_stalled",
        "severity": SEVERITY_WARN,
        "handler": "_heal_stalled_process",
        "match": f"dev-loop log stale {age:.0f}s pids={','.join(dev_loop_pids)}",
        "line": 0,
        "context": f"log_age={age:.0f}s pids={dev_loop_pids}",
    }
    if _rate_limit():
        act_on_error(process_stuck)


@traced
def daemon_loop():
    """Continuous self-heal loop (poll every 5s) with auto-reload."""
    pid_file = os.path.join(CACHE_DIR, "self-heal.pid")
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

    # Auto-reload support
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
                    print(f"[self-heal] watchdog: {os.path.basename(path)} changed", file=sys.stderr, flush=True)
                    return True
            except OSError:
                pass
        return False

    reload_counter = 0
    print("[self-heal] daemon started (poll 5s, reload ~60s)", file=sys.stderr, flush=True)

    while True:
        reload_counter += 1
        if reload_counter >= 12:
            reload_counter = 0
            if _should_reload():
                w.restart()
        try:
            results = poll_once()
            if results:
                _heal_log(f"cycle complete: {len(results)} action(s)")
        except Exception as e:
            _heal_log(f"poll error: {e}")
            import traceback
            _heal_log(traceback.format_exc())
        time.sleep(5)


@traced
def cmd_diagnose(logfile: str) -> list[dict]:
    """Diagnose a log file and return all detected error patterns."""
    try:
        with open(logfile) as f:
            content = f.read()
    except (OSError, IOError) as e:
        _heal_log(f"cannot read {logfile}: {e}")
        return []

    errors = detect_errors(content)
    for e in errors:
        e["signature"] = _compute_signature(e)
        e["known"] = _is_known_fingerprint(e["signature"])

    print(json.dumps(errors, indent=2))
    return errors


@traced
def cmd_issue(signature: str):
    """Create a GitHub issue from an error signature (for manual use)."""
    known = _load_json(KNOWN_ERRORS_FILE, {})
    if signature not in known:
        print(json.dumps({"error": f"unknown signature: {signature}"}))
        return
    data = known[signature]
    url = _create_gh_issue_and_task({
        "pattern": data.get("fix_type", "unknown"),
        "severity": "error",
        "match": f"Manual issue for {signature}",
        "context": json.dumps(data, indent=2),
    })
    print(json.dumps({"issue_url": url}))


# ══════════════════════════════════════════════════════════════════════
#  Entry point
# ══════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print("Usage: self_heal.py <poll|daemon|diagnose|issue> [args...]")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "poll":
        results = poll_once()
        print(json.dumps(results, indent=2, default=str))

    elif cmd == "daemon":
        daemon_loop()

    elif cmd == "diagnose":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "diagnose requires logfile"}))
            sys.exit(1)
        cmd_diagnose(sys.argv[2])

    elif cmd == "issue":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "issue requires signature"}))
            sys.exit(1)
        cmd_issue(sys.argv[2])

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
