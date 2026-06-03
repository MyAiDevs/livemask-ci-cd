#!/usr/bin/env python3
"""
task_intake.py — Unified task intake gateway for LiveMask.

ANY source (AI editor, GitHub issue, /mvp, planner gap, human report)
MUST submit tasks through this gateway. No exceptions.

The gateway:
  1. Accepts from ANY source with a standardized format
  2. Auto-classifies type (bug/feature/requirement/chore)
  3. Auto-detects repo, domain, priority via keyword analysis + AI hints
  4. Checks for duplicates in the ledger (fuzzy match on title + repo)
  5. Creates full artifact set:
     - Task document (TASK-*.md)
     - Dispatch packet (dispatch-packets/*.json)
     - Ledger entry (task-state-ledger.json)
     - GitHub issue (if gh CLI available)
  6. Tags the new task via tags.py
  7. Returns TASK-ID + full evidence

Usage:
    task_intake.py submit --title "..." --body "..." [--type bug|feature|requirement|chore] [--repo REPO] [--source github|mvp|cursor|claude|human|gap] [--priority P0|P1|P2|P3] [--github-url URL] [--dry-run]
    task_intake.py scan-github                          # Scan all repos for NEW untracked issues
    task_intake.py scan-github --repo livemask-backend   # Single repo scan
    task_intake.py classify --title "..." --body "..."   # Dry-run: show what the intake would produce
    task_intake.py check-duplicate --title "..." [--repo REPO]  # Check if duplicate exists

Output: JSON with task_id, artifacts_created, evidence.
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
from collections import Counter

# ── Paths ──────────────────────────────────────────────────────────────────

LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT",
                                os.path.expanduser("~/Developer/LiveMask"))
DOCS_DIR = Path(LIVEMASK_ROOT) / "livemask-docs"
TASKS_DIR = DOCS_DIR / "docs/development/tasks"
DISPATCH_DIR = DOCS_DIR / "docs/development/dispatch-packets"
LEDGER_FILE = DOCS_DIR / "docs/development/task-state-ledger.json"
CACHE_DIR = Path.home() / ".claude" / "cache"
INTAKE_STATE_FILE = CACHE_DIR / "task-intake-state.json"

PY_DIR = Path(__file__).parent.absolute()

# ── Canonical repos ────────────────────────────────────────────────────────

ALL_REPOS = [
    "livemask-backend", "livemask-admin", "livemask-website",
    "livemask-app", "livemask-nodeagent", "livemask-job-service",
    "livemask-ci-cd", "livemask-docs",
]

REPO_KEYWORDS = {
    "livemask-backend": ["backend", "api", "go", "server", "database", "auth", "billing", "vpn"],
    "livemask-admin": ["admin", "dashboard", "ui", "settings", "navigation", "manager"],
    "livemask-website": ["website", "landing", "marketing", "blog", "seo", "public"],
    "livemask-app": ["app", "flutter", "mobile", "client", "android", "ios"],
    "livemask-nodeagent": ["nodeagent", "node", "agent", "sing-box", "hysteria", "protocol"],
    "livemask-job-service": ["job", "worker", "scheduler", "cron", "queue", "task"],
    "livemask-ci-cd": ["ci", "cd", "pipeline", "build", "deploy", "smoke", "docker", "compose"],
    "livemask-docs": ["docs", "contract", "documentation", "rule", "governance"],
}

# ── Task types ─────────────────────────────────────────────────────────────

TASK_TYPES = {
    "bug": {
        "priority_default": "P0",
        "label": "bug",
        "template_file": "BUG-REPORT",
        "description": "Bug fix — unexpected behavior or error",
    },
    "feature": {
        "priority_default": "P1",
        "label": "feature",
        "template_file": "FEATURE-REQUEST",
        "description": "New feature or capability",
    },
    "requirement": {
        "priority_default": "P1",
        "label": "requirement",
        "template_file": "REQ-SUBMIT",
        "description": "Business or technical requirement",
    },
    "chore": {
        "priority_default": "P2",
        "label": "chore",
        "template_file": "CHORE",
        "description": "Maintenance, refactoring, or technical debt",
    },
    "improvement": {
        "priority_default": "P2",
        "label": "enhancement",
        "template_file": "IMPROVEMENT",
        "description": "Enhancement to existing functionality",
    },
}

STOP_WORDS = {"the","a","an","is","are","was","were","be","been","being","have","has","had",
              "do","does","did","will","would","shall","should","may","might","must","can",
              "could","and","or","not","no","nor","but","if","then","else","when","up","at",
              "by","for","with","about","into","through","during","before","after","above",
              "below","from","to","of","in","out","on","off","over","under","again","further",
              "once","here","there","all","both","each","few","more","most","other","some",
              "such","only","own","same","so","than","too","very","just","now","task","auto"}


# ── Helpers ────────────────────────────────────────────────────────────────

def _load_ledger() -> dict:
    """Load the task state ledger."""
    try:
        return json.loads(LEDGER_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"modules": [], "version": 2}


def _save_ledger(ledger: dict):
    LEDGER_FILE.parent.mkdir(parents=True, exist_ok=True)
    LEDGER_FILE.write_text(json.dumps(ledger, indent=2, ensure_ascii=False))


def _load_intake_state() -> dict:
    """Load the last-scanned issue state for GitHub watching."""
    if INTAKE_STATE_FILE.exists():
        try:
            return json.loads(INTAKE_STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"version": 2, "last_scan": "", "tracked_issues": {}, "scanned_issues": []}


def _save_intake_state(state: dict):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    INTAKE_STATE_FILE.write_text(json.dumps(state, indent=2, ensure_ascii=False))


def _run_gh(*args: str) -> str:
    """Run GitHub CLI and return stdout, or empty string on failure."""
    try:
        r = subprocess.run(["gh"] + list(args), capture_output=True, text=True, timeout=30)
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def _python_tool(script: str, *args: str) -> str:
    """Run another python tool and return stdout."""
    script_path = PY_DIR / script
    try:
        r = subprocess.run(
            [sys.executable, str(script_path)] + list(args),
            capture_output=True, text=True, timeout=30,
        )
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return json.dumps({"error": str(e)})


def _detect_repo(title: str, body: str, hint: str = "") -> str:
    """Detect the target repository from text + hint."""
    if hint and hint in ALL_REPOS:
        return hint

    text = (title + " " + body).lower()

    # Score each repo by keyword matches
    scores = {}
    for repo, keywords in REPO_KEYWORDS.items():
        score = sum(1 for kw in keywords if kw in text)
        if score > 0:
            scores[repo] = score

    if scores:
        return max(scores, key=scores.get)

    return "livemask-backend"  # default


def _detect_type(title: str, body: str) -> str:
    """Detect the task type from text."""
    text = (title + " " + body).lower()

    # Bug indicators
    bug_indicators = [
        "bug", "crash", "error", "fail", "broken", "fix", "issue",
        "incorrect", "wrong", "unexpected", "not working", "bugfix",
        "regression", "panic", "null pointer", "exception",
    ]
    bug_score = sum(1 for w in bug_indicators if w in text)

    # Feature indicators
    feature_indicators = [
        "feature", "new", "add", "implement", "support", "capability",
        "enhance", "want", "request", "would be nice", "suggest",
    ]
    feature_score = sum(1 for w in feature_indicators if w in text)

    # Requirement indicators
    req_indicators = [
        "requirement", "must", "need", "required", "should", "shall",
        "spec", "contract", "acceptance", "criteria",
    ]
    req_score = sum(1 for w in req_indicators if w in text)

    # Chore indicators
    chore_indicators = [
        "chore", "refactor", "cleanup", "tech debt", "maintenance",
        "upgrade", "update dependency", "migration", "deprecat",
    ]
    chore_score = sum(1 for w in chore_indicators if w in text)

    # Determine type
    scores = {
        "bug": bug_score * 1.5,  # bug indicators are stronger signals
        "feature": feature_score,
        "requirement": req_score,
        "chore": chore_score,
    }

    max_type = max(scores, key=scores.get)
    if scores[max_type] == 0:
        return "requirement"  # default
    return max_type


def _detect_priority(ttype: str, title: str, body: str) -> str:
    """Detect priority from text, falling back to type default."""
    text = (title + " " + body).lower()

    # P0 (critical) indicators
    p0_indicators = ["p0", "critical", "blocker", "urgent", "security", "data loss",
                     "crash", "down", "outage", "production"]
    p0_score = sum(1 for w in p0_indicators if w in text)

    # P1 (high) indicators
    p1_indicators = ["p1", "high", "important", "major", "blocking"]
    p1_score = sum(1 for w in p1_indicators if w in text)

    if p0_score > 0:
        return "P0"
    elif p1_score > 0:
        return "P1"

    return TASK_TYPES.get(ttype, {}).get("priority_default", "P2")


def _generate_tid(ttype: str, repo: str, title: str) -> str:
    """Generate a unique TASK ID: TASK-INTK-{REPO}-{TYPE}-{KEYWORDS}-{TIMESTAMP}"""
    repo_short = repo.replace("livemask-", "").upper()[:12]
    ttype_short = ttype.upper()[:4]
    words = re.findall(r"[A-Za-z0-9]{3,}", title)
    keywords = [w.upper() for w in words if w.lower() not in STOP_WORDS][:3]
    keyword_str = "-".join(keywords)[:25] if keywords else "TASK"
    ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    tid = f"TASK-INTK-{repo_short}-{ttype_short}-{keyword_str}-{ts}"[:72].rstrip("-")
    return tid


def _check_duplicate(title: str, repo: str, ledger: dict) -> list[dict]:
    """Check for duplicate tasks in the ledger using fuzzy title matching."""
    title_low = title.lower()
    title_tokens = set(re.findall(r"[A-Za-z0-9]{3,}", title_low))

    duplicates = []
    for mod in ledger.get("modules", []):
        for t in mod.get("tasks", []):
            existing_title = (t.get("title", "") or "").lower()
            existing_repo = t.get("repo", "")

            # Only filter by repo if a repo was explicitly provided
            if repo and existing_repo and existing_repo != repo:
                continue

            # Title token overlap
            existing_tokens = set(re.findall(r"[A-Za-z0-9]{3,}", existing_title))
            if len(title_tokens) < 3 or len(existing_tokens) < 3:
                continue

            overlap = title_tokens & existing_tokens
            overlap_ratio = len(overlap) / max(len(title_tokens), len(existing_tokens))

            if overlap_ratio >= 0.5:
                duplicates.append({
                    "task_id": t.get("task_id", ""),
                    "existing_title": t.get("title", ""),
                    "status": t.get("status", ""),
                    "overlap_ratio": round(overlap_ratio, 2),
                    "matched_terms": sorted(overlap)[:8],
                })

    return duplicates


def _get_domain_tags(title: str, body: str, repo: str) -> list[str]:
    """Generate domain/capability tags from text."""
    text = (title + " " + body).lower()
    tags = []

    # Repo tag
    if repo in ALL_REPOS:
        tags.append(f"repo:{repo}")

    # Domain tags
    domain_map = [
        ("auth", "domain:auth"), ("login", "domain:auth"), ("token", "domain:auth"),
        ("vpn", "domain:vpn"), ("connect", "domain:vpn"), ("proxy", "domain:vpn"),
        ("node", "domain:node"), ("agent", "domain:node"), ("speedtest", "domain:node"),
        ("admin", "domain:admin"), ("dashboard", "domain:admin"),
        ("billing", "domain:billing"), ("payment", "domain:billing"), ("usdt", "domain:billing"),
        ("user", "domain:user"), ("profile", "domain:user"), ("account", "domain:user"),
        ("content", "domain:content"), ("notification", "domain:content"),
        ("i18n", "domain:i18n"), ("locale", "domain:i18n"), ("language", "domain:i18n"),
        ("marketplace", "domain:marketplace"), ("commerce", "domain:marketplace"),
        ("growth", "domain:growth"), ("referral", "domain:growth"), ("reward", "domain:growth"),
        ("geoip", "domain:geoip"), ("geo", "domain:geoip"),
        ("protocol", "domain:protocol"), ("endpoint", "domain:protocol"),
        ("security", "domain:security"), ("credential", "domain:security"),
        ("observability", "domain:observability"), ("log", "domain:observability"),
        ("metric", "domain:observability"), ("monitor", "domain:observability"),
        ("ci-cd", "domain:ci-cd"), ("ci/cd", "domain:ci-cd"), ("pipeline", "domain:ci-cd"),
        ("release", "domain:release"), ("deploy", "domain:release"),
        ("governance", "domain:governance"), ("compliance", "domain:governance"),
        ("revenue", "domain:revenue"), ("traffic", "domain:revenue"),
    ]
    for keyword, tag in domain_map:
        if keyword in text:
            tags.append(tag)

    # Capability tags
    cap_map = [
        ("api", "capability:api"), ("rest", "capability:api"),
        ("db", "capability:db"), ("database", "capability:db"),
        ("ui", "capability:ui"), ("ux", "capability:ui"),
        ("config", "capability:config"), ("configuration", "capability:config"),
        ("notification", "capability:notification"), ("email", "capability:notification"),
        ("sms", "capability:notification"), ("lark", "capability:notification"),
        ("payment", "capability:payment"), ("pricing", "capability:payment"),
        ("speedtest", "capability:speedtest"), ("bandwidth", "capability:speedtest"),
        ("reconnect", "capability:reconnect"), ("connect", "capability:connect"),
        ("dashboard", "capability:dashboard"), ("report", "capability:dashboard"),
        ("analytics", "capability:analytics"), ("scheduler", "capability:scheduler"),
        ("cron", "capability:scheduler"), ("template", "capability:template"),
        ("rollout", "capability:rollout"), ("realtime", "capability:realtime"),
        ("webhook", "capability:webhook"), ("websocket", "capability:realtime"),
    ]
    for keyword, tag in cap_map:
        if keyword in text:
            tags.append(tag)

    return list(set(tags))  # deduplicate


def _create_task_doc(tid: str, title: str, body: str, ttype: str,
                     repo: str, priority: str, source: str, tags: list[str]):
    """Create a TASK document in the tasks directory."""
    TASKS_DIR.mkdir(parents=True, exist_ok=True)

    doc_path = TASKS_DIR / f"{tid}.md"

    type_label = TASK_TYPES.get(ttype, {}).get("label", ttype)

    # Build acceptance criteria from body if it looks like a list
    body_lines = body.strip().split("\n")
    criteria_section = ""
    for line in body_lines:
        stripped = line.strip()
        if stripped.startswith("- [ ]") or stripped.startswith("* [ ]"):
            criteria_section += stripped + "\n"
        elif stripped.startswith("- ") or stripped.startswith("* "):
            criteria_section += f"- [ ] {stripped[2:].strip()}\n"

    # Extract validation commands from body code blocks
    val_cmds = re.findall(r"```(?:bash|sh|shell)\s*\n(.+?)```", body, re.DOTALL)
    val_section = ""
    if val_cmds:
        val_section = "### Validation\n\n" + "\n".join(f"```bash\n{c.strip()}\n```" for c in val_cmds)

    doc_content = f"""# {title}

## Overview

- **Task ID:** {tid}
- **Type:** {type_label}
- **Priority:** {priority}
- **Repository:** {repo}
- **Source:** {source}
- **Status:** ready
{"- **Tags:** " + ", ".join(tags) if tags else ""}
- **Created:** {datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")}

---

## Description

{body}

---

## Acceptance Criteria

{criteria_section if criteria_section else "- [ ] Verify implementation meets requirements\n- [ ] All tests pass\n- [ ] No regressions introduced"}

{val_section}

---

## Related

- Source: {source}
- Intake type: {ttype}
"""

    doc_path.write_text(doc_content)
    return doc_path


def _create_dispatch_packet(tid: str, title: str, repo: str, priority: str,
                            source: str, github_url: str = ""):
    """Create a dispatch packet JSON."""
    DISPATCH_DIR.mkdir(parents=True, exist_ok=True)

    packet = {
        "task_id": tid,
        "title": title,
        "repo": repo,
        "priority": priority,
        "source": source,
        "status": "ready",
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "created_by": "task_intake.py",
        "github_url": github_url or "",
        "intake_version": 2,
    }

    packet_path = DISPATCH_DIR / f"{tid}-intake.json"
    packet_path.write_text(json.dumps(packet, indent=2) + "\n")
    return packet_path


def _add_ledger_entry(tid: str, title: str, repo: str, priority: str,
                      source: str, tags: list[str], github_url: str = ""):
    """Add a new task entry to the task state ledger."""
    ledger = _load_ledger()

    # Find or create the module for this repo
    module_name = repo.replace("livemask-", "").upper()
    module_found = False
    for mod in ledger.get("modules", []):
        if mod.get("module", "").lower() == module_name.lower():
            mod.setdefault("tasks", []).append({
                "task_id": tid,
                "title": title,
                "status": "ready",
                "repo": repo,
                "priority": priority,
                "source": source,
                "tags": tags,
                "github_url": github_url or "",
                "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "intake_type": "auto",
            })
            module_found = True
            break

    if not module_found:
        # Create new module
        ledger.setdefault("modules", []).append({
            "module": module_name,
            "tasks": [{
                "task_id": tid,
                "title": title,
                "status": "ready",
                "repo": repo,
                "priority": priority,
                "source": source,
                "tags": tags,
                "github_url": github_url or "",
                "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "intake_type": "auto",
            }],
        })

    _save_ledger(ledger)
    return True


def _create_github_issue(tid: str, title: str, body: str, repo: str,
                         ttype: str, priority: str) -> str:
    """Create a GitHub issue for the task. Returns URL or empty string."""
    if not repo or repo not in ALL_REPOS:
        return ""

    gh_repo = f"MyAiDevs/{repo}"
    type_label = TASK_TYPES.get(ttype, {}).get("label", ttype)

    issue_body = f"""## [{tid}] {title}

**Type:** {type_label}
**Priority:** {priority}
**Source:** Auto-intake (task_intake.py)

---

{body}

---

*This issue was automatically created from task intake. Do not edit manually.*
*Task document: `docs/development/tasks/{tid}.md`*
"""

    result = _run_gh("issue", "create",
                     "--repo", gh_repo,
                     "--title", f"[{tid}] {title}",
                     "--label", type_label,
                     "--label", "auto-intake",
                     "--body", issue_body)
    result = result.strip()

    # Extract URL from result
    if result.startswith("https://"):
        return result

    return ""


def _post_github_comment(issue_url: str, tid: str):
    """Post a tracking comment on an existing GitHub issue."""
    if not issue_url:
        return
    comment = f"""This issue is now tracked as **{tid}**.

Task document: `docs/development/tasks/{tid}.md`
Added to dispatch queue for automatic processing.

_🤖 Auto-tracked by LiveMask task intake system_
"""
    _run_gh("issue", "comment", issue_url, "--body", comment)


def _add_github_label(issue_url: str, label: str):
    """Add a label to a GitHub issue."""
    if not issue_url:
        return
    _run_gh("issue", "edit", issue_url, "--add-label", label)


def _run_tags_enrich(tid: str, tags: list[str]):
    """Tag the new task via tags.py."""
    if not tags:
        return
    _python_tool("tags.py", "tag", tid, ",".join(tags),
                 "--source", "intake",
                 "--meta", f"source:task_intake")


# ── Core intake function ──────────────────────────────────────────────────

def process_intake(title: str, body: str, ttype: str = "",
                   repo: str = "", source: str = "manual",
                   priority: str = "", github_url: str = "",
                   dry_run: bool = False) -> dict:
    """Process a unified task intake. Returns result dict."""
    result = {
        "status": "ok",
        "task_id": "",
        "duplicates": [],
        "artifacts": {},
        "warnings": [],
    }

    # Step 1: Detect type if not provided
    if not ttype:
        ttype = _detect_type(title, body)

    if ttype not in TASK_TYPES:
        result["status"] = "error"
        result["error"] = f"Unknown task type: {ttype}. Valid: {list(TASK_TYPES.keys())}"
        return result

    # Step 2: Detect repo if not provided
    resolved_repo = _detect_repo(title, body, repo)

    # Step 3: Detect priority if not provided
    resolved_priority = _detect_priority(ttype, title, body) if not priority else priority

    # Step 4: Load ledger for duplicate check (cross-repo)
    ledger = _load_ledger()
    duplicates = _check_duplicate(title, "", ledger)  # empty repo = search all repos
    if duplicates:
        result["duplicates"] = duplicates
        # If high overlap (>=70%), warn but still create (the user may want it)
        high_overlap = [d for d in duplicates if d.get("overlap_ratio", 0) >= 0.7]
        if high_overlap:
            result["warnings"].append(
                f"High-similarity tasks exist: {', '.join(d['task_id'] for d in high_overlap)}"
            )

    # Step 5: Generate TASK ID
    tid = _generate_tid(ttype, resolved_repo, title)

    # Step 6: Generate tags
    tags = _get_domain_tags(title, body, resolved_repo)
    tags.append(f"intake:{source}")
    tags.append(f"type:{ttype}")

    # Step 7: Create artifacts (or dry-run)
    if not dry_run:
        # 7a. Task doc
        doc_path = _create_task_doc(tid, title, body, ttype, resolved_repo,
                                     resolved_priority, source, tags)
        result["artifacts"]["task_doc"] = str(doc_path)

        # 7b. Dispatch packet
        packet_path = _create_dispatch_packet(tid, title, resolved_repo,
                                               resolved_priority, source, github_url)
        result["artifacts"]["dispatch_packet"] = str(packet_path)

        # 7c. Ledger entry
        _add_ledger_entry(tid, title, resolved_repo, resolved_priority,
                          source, tags, github_url)
        result["artifacts"]["ledger"] = str(LEDGER_FILE)

        # 7d. GitHub issue (if source isn't already GitHub)
        if source != "github" and not github_url:
            issue_url = _create_github_issue(tid, title, body, resolved_repo,
                                              ttype, resolved_priority)
            if issue_url:
                result["artifacts"]["github_issue"] = issue_url
                github_url = issue_url

        # 7e. If from GitHub, add tracking label + comment
        if github_url:
            _add_github_label(github_url, "task-tracked")
            _post_github_comment(github_url, tid)
            result["artifacts"]["tracked_issue"] = github_url

        # 7f. Tag via tags.py
        _run_tags_enrich(tid, tags)

        result["task_id"] = tid
    else:
        result["task_id"] = tid  # projected ID
        result["dry_run"] = True

    result["type"] = ttype
    result["repo"] = resolved_repo
    result["priority"] = resolved_priority
    result["source"] = source
    result["tags"] = tags

    return result


# ── Commands ──────────────────────────────────────────────────────────────

def cmd_submit(args: list[str]) -> int:
    """task_intake.py submit --title ... --body ... [options]"""
    title = ""
    body = ""
    ttype = ""
    repo = ""
    source = "manual"
    priority = ""
    github_url = ""
    dry_run = False

    i = 0
    while i < len(args):
        if args[i] == "--title" and i + 1 < len(args):
            title = args[i + 1]; i += 2
        elif args[i] == "--body" and i + 1 < len(args):
            body = args[i + 1]; i += 2
        elif args[i] == "--type" and i + 1 < len(args):
            ttype = args[i + 1]; i += 2
        elif args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]; i += 2
        elif args[i] == "--priority" and i + 1 < len(args):
            priority = args[i + 1]; i += 2
        elif args[i] == "--source" and i + 1 < len(args):
            source = args[i + 1]; i += 2
        elif args[i] == "--github-url" and i + 1 < len(args):
            github_url = args[i + 1]; i += 2
        elif args[i] == "--dry-run":
            dry_run = True; i += 1
        else:
            i += 1

    if not title:
        print(json.dumps({"status": "error", "error": "title is required",
                          "usage": "submit --title '...' --body '...' [--type T] [--repo R] [--source S]"}))
        return 1

    result = process_intake(title, body, ttype, repo, source, priority, github_url, dry_run)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result.get("status") == "ok" else 1


def cmd_scan_github(args: list[str]) -> int:
    """task_intake.py scan-github [--repo REPO]"""
    target_repo = ""
    i = 0
    while i < len(args):
        if args[i] == "--repo" and i + 1 < len(args):
            target_repo = args[i + 1]; i += 2
        else:
            i += 1

    state = _load_intake_state()
    scanned = []
    errors = []

    repos_to_scan = [target_repo] if target_repo else ALL_REPOS

    for repo in repos_to_scan:
        gh_repo = f"MyAiDevs/{repo}"

        # Get ALL open issues (no label filter — we check each one)
        issues_json = _run_gh("issue", "list",
                              "--repo", gh_repo,
                              "--state", "open",
                              "--limit", "50",
                              "--json", "number,title,body,url,labels,createdAt,updatedAt")

        if not issues_json:
            errors.append(f"no issues found for {gh_repo} (or gh CLI unavailable)")
            continue

        try:
            issues = json.loads(issues_json)
        except json.JSONDecodeError:
            errors.append(f"failed to parse issues for {gh_repo}")
            continue

        for issue in issues:
            inum = issue.get("number", 0)
            title = issue.get("title", "")
            body = issue.get("body", "") or ""
            url = issue.get("url", "")
            labels = [l.get("name", "") for l in issue.get("labels", []) if isinstance(l, dict)]

            # Skip if already tracked or auto-created
            if "task-tracked" in labels or "auto-intake" in labels:
                continue

            # Check if already scanned
            issue_key = f"{repo}#{inum}"
            if issue_key in state.get("scanned_issues", []):
                continue

            # Process intake from this GitHub issue
            print(json.dumps({
                "status": "processing",
                "source": "github",
                "issue_key": issue_key,
                "repo": repo,
                "title": title[:80],
            }))

            result = process_intake(
                title=title,
                body=body,
                source="github",
                repo=repo,
                github_url=url,
            )

            scanned.append({
                "issue_key": issue_key,
                "repo": repo,
                "number": inum,
                "url": url,
                "task_id": result.get("task_id", ""),
                "status": result.get("status", "error"),
                "duplicates": result.get("duplicates", []),
            })

            # Mark as scanned regardless of outcome
            if issue_key not in state.get("scanned_issues", []):
                state.setdefault("scanned_issues", []).append(issue_key)

            # Track the issue
            state.setdefault("tracked_issues", {})[issue_key] = {
                "number": inum,
                "title": title,
                "url": url,
                "task_id": result.get("task_id", ""),
                "scanned_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }

    state["last_scan"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _save_intake_state(state)

    output = {
        "status": "ok",
        "repos_scanned": repos_to_scan,
        "new_issues_processed": len(scanned),
        "total_tracked": len(state.get("tracked_issues", {})),
        "scanned": scanned,
        "errors": errors or None,
    }
    print(json.dumps(output, indent=2, ensure_ascii=False))
    return 0


def cmd_classify(args: list[str]) -> int:
    """task_intake.py classify --title ... --body ... — Dry-run classification."""
    title = ""
    body = ""
    repo = ""

    i = 0
    while i < len(args):
        if args[i] == "--title" and i + 1 < len(args):
            title = args[i + 1]; i += 2
        elif args[i] == "--body" and i + 1 < len(args):
            body = args[i + 1]; i += 2
        elif args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]; i += 2
        else:
            i += 1

    if not title:
        print(json.dumps({"status": "error", "error": "title required"}))
        return 1

    ttype = _detect_type(title, body)
    resolved_repo = _detect_repo(title, body, repo)
    priority = _detect_priority(ttype, title, body)

    # Check duplicates (cross-repo)
    ledger = _load_ledger()
    duplicates = _check_duplicate(title, "", ledger)  # search all repos

    # Generate tags
    tags = _get_domain_tags(title, body, resolved_repo)

    # Generate projected TASK ID
    tid = _generate_tid(ttype, resolved_repo, title)

    result = {
        "status": "ok",
        "title": title,
        "detected_type": ttype,
        "detected_repo": resolved_repo,
        "detected_priority": priority,
        "projected_task_id": tid,
        "domain_tags": tags,
        "duplicates_found": duplicates,
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def cmd_check_duplicate(args: list[str]) -> int:
    """task_intake.py check-duplicate --title ... [--repo R]"""
    title = ""
    repo = ""

    i = 0
    while i < len(args):
        if args[i] == "--title" and i + 1 < len(args):
            title = args[i + 1]; i += 2
        elif args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]; i += 2
        else:
            i += 1

    if not title:
        print(json.dumps({"status": "error", "error": "title required"}))
        return 1

    ledger = _load_ledger()
    duplicates = _check_duplicate(title, repo or "", ledger)

    print(json.dumps({
        "status": "ok",
        "title": title,
        "repo": repo or "all",
        "duplicates_found": len(duplicates),
        "duplicates": duplicates,
    }, indent=2, ensure_ascii=False))
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "submit": cmd_submit,
        "scan-github": cmd_scan_github,
        "classify": cmd_classify,
        "check-duplicate": cmd_check_duplicate,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        return 1

    try:
        return cmds[command](args)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
