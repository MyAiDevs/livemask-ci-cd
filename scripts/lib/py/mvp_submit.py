#!/usr/bin/env python3
"""mvp_submit.py — Quick MVP task submission via /mvp skill.

Usage:
  /mvp bug <description>
  /mvp requirement <description>
  /mvp feature <description>

Auto-creates: task doc, dispatch packet, ledger entry, GitHub issue.
"""
import json, sys, os, re, subprocess
from pathlib import Path
from datetime import datetime, timezone

from debug_utils import setup as _debug_setup, traced, logger as _logger

DOCS_DIR = Path(os.environ.get("DOCS_DIR", os.path.expanduser("~/Developer/LiveMask/livemask-docs")))
CACHE_DIR = Path(os.environ.get("ROLE_CACHE_DIR", os.path.expanduser("~/.claude/role-cache")))

TYPE_CONFIG = {
    "bug": {
        "label": "bug",
        "priority": "P0",
        "template": "## Bug Report\n\n**Description:** {description}\n\n**Steps to Reproduce:**\n1. \n2. \n3. \n\n**Expected:** \n**Actual:** \n\n**Environment:** dev-local",
        "repo_hint": "livemask-backend",
        "check": "BUG-REPORT",
    },
    "requirement": {
        "label": "requirement",
        "priority": "P1",
        "template": "## Requirement\n\n**Description:** {description}\n\n**Acceptance Criteria:**\n- [ ] \n- [ ] \n\n**Related Contracts:** \n**Dependencies:** ",
        "repo_hint": "livemask-docs",
        "check": "REQ-SUBMIT",
    },
    "feature": {
        "label": "feature",
        "priority": "P1",
        "template": "## Feature Request\n\n**Description:** {description}\n\n**Scope:** \n**Implementation Notes:** \n**Verification:** ",
        "repo_hint": "livemask-backend",
        "check": "FEATURE-REQUEST",
    },
}

STOP_WORDS = {"the","a","an","is","are","was","were","be","been","being","have","has","had","do","does","did","will","would","shall","should","may","might","must","can","could","and","or","not","no","nor","but","if","then","else","when","up","at","by","for","with","about","into","through","during","before","after","above","below","from","to","of","in","out","on","off","over","under","again","further","once","here","there","all","both","each","few","more","most","other","some","such","only","own","same","so","than","too","very","just","now","it","its","this","that","these","those"}


def generate_tid(ttype: str, description: str, repo: str) -> str:
    """Generate a task ID: TASK-MVP-{REPO}-{TYPE}-{KEYWORDS}"""
    repo_short = repo.replace("livemask-", "").upper()[:12]
    words = re.findall(r"[A-Za-z0-9]{3,}", description)
    keywords = [w.upper() for w in words if w.lower() not in STOP_WORDS][:4]
    keyword_str = "-".join(keywords)[:30] if keywords else "TASK"
    ttype_short = {"bug": "BUG", "requirement": "REQ", "feature": "FEAT"}.get(ttype, "TASK")
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    tid = f"TASK-MVP-{repo_short}-{ttype_short}-{keyword_str}-{ts}"[:70].rstrip("-")
    return tid


def guess_repo(description: str, ttype: str) -> str:
    """Guess the target repo from keywords in the description."""
    desc_lower = description.lower()
    hints = [
        ("admin", "livemask-admin"),
        ("backend", "livemask-backend"),
        ("website", "livemask-website"),
        ("app", "livemask-app"),
        ("flutter", "livemask-app"),
        ("mobile", "livemask-app"),
        ("nodeagent", "livemask-nodeagent"),
        ("node agent", "livemask-nodeagent"),
        ("job", "livemask-job-service"),
        ("ci", "livemask-ci-cd"),
        ("cd", "livemask-ci-cd"),
        ("ci/cd", "livemask-ci-cd"),
        ("docs", "livemask-docs"),
        ("documentation", "livemask-docs"),
        ("contract", "livemask-docs"),
        ("vpn", "livemask-backend"),
        ("connect", "livemask-backend"),
        ("billing", "livemask-backend"),
        ("user", "livemask-backend"),
        ("dashboard", "livemask-backend"),
        ("api", "livemask-backend"),
        ("ui", "livemask-admin"),
    ]
    for keyword, repo in hints:
        if keyword in desc_lower:
            return repo
    return TYPE_CONFIG.get(ttype, {}).get("repo_hint", "livemask-backend")


@traced
def main():
    _debug_setup()
    if len(sys.argv) < 3:
        print("Usage: /mvp <bug|requirement|feature> <description>")
        print(json.dumps({"status": "error", "reason": "missing arguments"}))
        sys.exit(1)

    ttype = sys.argv[1].lower()
    description = " ".join(sys.argv[2:])

    if ttype not in TYPE_CONFIG:
        print(json.dumps({"status": "error", "reason": f"unknown type: {ttype}. Use bug, requirement, or feature"}))
        sys.exit(1)

    config = TYPE_CONFIG[ttype]
    repo = guess_repo(description, ttype)
    tid = generate_tid(ttype, description, repo)
    now = datetime.now(timezone.utc)

    # Build task body from template
    body = config["template"].format(description=description)

    # Create task doc
    task_dir = DOCS_DIR / "docs/development/tasks"
    task_dir.mkdir(parents=True, exist_ok=True)
    doc = f"""# {tid} — {description[:80]}

> Status: ready
> Repository: {repo}
> Priority: {config['priority']}
> Type: {ttype}
> Created: {now.strftime('%Y-%m-%d %H:%M:%S UTC')}
> Source: /mvp {ttype}

## Background

Submitted via /mvp skill: {description}

{body}

## Acceptance Criteria
- [ ] Task verified against existing contracts
- [ ] Implementation follows repo patterns
- [ ] Evidence: build + test + vet pass
- [ ] GitHub issue linked with evidence

## Pipeline
MVP docs → Dev docs → Tech docs → AI rules → Branch → Code → Smoke → Env → Accept → Push → GitHub → Update MVP
"""
    doc_path = task_dir / f"{tid}.md"
    doc_path.write_text(doc, encoding="utf-8")

    # Create dispatch packet
    dp_dir = DOCS_DIR / "docs/development/dispatch-packets"
    dp_dir.mkdir(parents=True, exist_ok=True)
    dp = {
        "schema_version": 1, "task_id": tid, "repo": repo,
        "priority": config["priority"], "readiness": "ready",
        "assigned_to": "claude",
        "assigned_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "assigned_by": "/mvp skill",
        "reason": f"{ttype}: {description[:80]}",
        "why_now": [f"{ttype}: {description}"],
        "context": {
            "generated_by": "/mvp skill",
            "task_doc": f"docs/development/tasks/{tid}.md",
        },
        "acceptance": {
            "task_doc_exists": f"docs/development/tasks/{tid}.md",
            "ledger_status": "dispatched",
            "evidence_required": True,
        },
    }
    dp_path = dp_dir / f"{tid}.json"
    dp_path.write_text(json.dumps(dp, indent=2), encoding="utf-8")

    # Add to ledger
    ledger_path = DOCS_DIR / "docs/development/task-state-ledger.json"
    if ledger_path.exists():
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        mvp_mod = None
        for m in ledger.get("modules", []):
            if m.get("module_id") == "mvp-tasks":
                mvp_mod = m
                break
        if not mvp_mod:
            mvp_mod = {"module_id": "mvp-tasks", "overall_status": "partial",
                       "owner_repo": "livemask-docs", "tasks": [], "open_gaps": []}
            ledger["modules"].append(mvp_mod)
        mvp_mod["tasks"].append({
            "task_id": tid, "repo": repo, "module_id": "mvp-tasks",
            "status": "ready", "priority": config["priority"],
            "task_doc": f"docs/development/tasks/{tid}.md",
            "issue": "", "validation": "", "dev_merge_commit": "", "remote_dev_ref": "",
            "blocked_by": [], "unlocks": [],
            "notes": f"/mvp {ttype}: {description[:200]}",
        })
        mvp_mod["overall_status"] = "partial"
        ledger_path.write_text(json.dumps(ledger, indent=2, ensure_ascii=False), encoding="utf-8")

    # Create GitHub issue
    issue_url = ""
    try:
        gh_body = f"""## /mvp {ttype}

{description}

### Task Info
- **Task ID:** {tid}
- **Repository:** {repo}
- **Priority:** {config['priority']}
- **Type:** {ttype}

### Template
{body}

### Pipeline
1. MVP docs → 2. Dev docs → 3. Tech docs → 4. AI rules → 5. Branch
→ 6. Code → 7. Smoke → 8. Env → 9. Accept → 10. Update
→ 11. Push → 12. GitHub → 13. Update MVP

---
🤖 Submitted via /mvp skill
"""
        result = subprocess.run(
            ["gh", "issue", "create", "--repo", f"MyAiDevs/{repo}",
             "--title", f"[{ttype.upper()}] {description[:80]}",
             "--body", gh_body,
             "--label", config["label"]],
            capture_output=True, text=True, timeout=15
        )
        issue_url = result.stdout.strip()
        if issue_url and "github.com" in issue_url:
            # Update ledger with issue URL
            if ledger_path.exists():
                ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
                for m in ledger.get("modules", []):
                    for t in m.get("tasks", []):
                        if t.get("task_id") == tid:
                            t["issue"] = issue_url
                ledger_path.write_text(json.dumps(ledger, indent=2, ensure_ascii=False), encoding="utf-8")
    except Exception as e:
        issue_url = f"gh create failed: {e}"

    # Output summary
    result = {
        "status": "created",
        "task_id": tid,
        "type": ttype,
        "repo": repo,
        "priority": config["priority"],
        "description": description[:120],
        "doc_path": str(doc_path),
        "dp_path": str(dp_path),
        "github_issue": issue_url or "create manually",
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
