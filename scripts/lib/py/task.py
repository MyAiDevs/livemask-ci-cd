#!/usr/bin/env python3
"""task.py — Task artifact creation: task doc, dispatch packet, ledger entry.

Usage:
  python3 task.py create --role PM --check PM-3 --title "..." --repo livemask-backend --priority P1 --body "..."
  python3 task.py dispatch TASK-ID --role PM --check PM-3 --title "..." --repo livemask-backend
  python3 task.py intelligence TASK-ID --title "..." --repo "..." --body "..." --role PM --check PM-3
"""
import json, re, sys, argparse, os
from pathlib import Path
from datetime import datetime, timezone

DOCS_DIR = Path(os.environ.get("DOCS_DIR", os.path.expanduser("~/Developer/LiveMask/livemask-docs")))
CACHE_DIR = Path(os.environ.get("ROLE_CACHE_DIR", os.path.expanduser("~/.claude/role-cache")))
TASK_DIR = DOCS_DIR / "docs/development/tasks"
DISPATCH_DIR = DOCS_DIR / "docs/development/dispatch-packets"

CANONICAL_REPOS = {
    "livemask-backend", "livemask-admin", "livemask-app", "livemask-website",
    "livemask-ci-cd", "livemask-nodeagent", "livemask-job-service", "livemask-docs",
}

REPO_DOC_HINTS = {
    "livemask-backend": ["docs/backend", "docs/contracts", "docs/data", "docs/architecture"],
    "livemask-admin": ["docs/admin", "docs/contracts", "docs/design", "docs/architecture"],
    "livemask-app": ["docs/app", "docs/contracts", "docs/architecture"],
    "livemask-nodeagent": ["docs/nodeagent", "docs/contracts", "docs/architecture"],
    "livemask-job-service": ["docs/job-service", "docs/contracts", "docs/operations"],
    "livemask-ci-cd": ["docs/development", "docs/operations", "docs/contracts"],
    "livemask-docs": ["docs/development", "docs/contracts", "docs/architecture"],
}

QUALITY_GATES = [
    "git diff --check",
    "run the repo-native formatter/linter/test suite for touched files",
    "do not introduce a new abstraction when an existing project helper or contract already covers the behavior",
    "update docs/contracts or task evidence when behavior, API, schema, CI, or runtime expectations change",
]

REPO_QUALITY_OVERRIDES = {
    "livemask-docs": ["bash scripts/check-docs.sh"],
    "livemask-backend": ["go test ./...", "verify OpenAPI/Swagger docs when routes or DTOs change"],
    "livemask-admin": ["npm test", "npm run build", "browser/network evidence for UI acceptance"],
    "livemask-ci-cd": ["bash -n changed shell scripts", "run the matching smoke script in dry-run/local mode"],
}

STOP_WORDS = {
    "task", "auto", "implement", "add", "fix", "sync", "for", "and", "the",
    "with", "from", "ready", "contract", "documentation", "smoke", "tests",
    "test", "pipeline", "role", "engine", "finding", "create", "across",
}


def generate_task_id(repo: str, title: str) -> str:
    """Generate a short, ledger-compliant TASK-AUTO ID."""
    repo_short = repo.replace("livemask-", "").upper().replace("-", "-")[:16] or "MISC"
    uniq = "".join(c if c.isalnum() else "-" for c in title.upper()[:40])
    uniq_parts = [p for p in uniq.split("-") if p and p.lower() not in STOP_WORDS][:4]
    tid = f"TASK-AUTO-{repo_short}-{'-'.join(uniq_parts)}"[:60].rstrip("-")
    return tid


def extract_tokens(title: str, body: str, repo: str) -> list[str]:
    tokens = []
    for token in re.findall(r"[A-Za-z0-9]{3,}", f"{title} {body} {repo}"):
        low = token.lower()
        if low not in STOP_WORDS and low not in tokens:
            tokens.append(low)
    return tokens[:12]


def find_related_tasks(ledger: dict, tokens: list[str], repo: str) -> tuple[list, list]:
    related = []
    duplicates = []
    for mod in ledger.get("modules", []):
        for t in mod.get("tasks", []):
            text = " ".join(str(t.get(k, "")) for k in ("task_id", "repo", "status", "notes", "validation", "task_doc"))
            text_low = text.lower()
            overlap = [tok for tok in tokens if tok in text_low]
            same_repo = t.get("repo") == repo
            if same_repo or len(overlap) >= 2:
                related.append({
                    "task_id": t.get("task_id", ""), "repo": t.get("repo", ""),
                    "status": t.get("status", ""), "priority": t.get("priority", ""),
                    "task_doc": t.get("task_doc", ""), "issue": t.get("issue", ""),
                    "relation": "same_repo" if same_repo else "keyword_overlap",
                    "matched_terms": overlap[:6],
                })
            if t.get("status") in ("ready", "dispatched", "in_progress", "blocked", "partial") and len(overlap) >= 4:
                duplicates.append({
                    "task_id": t.get("task_id", ""), "status": t.get("status", ""),
                    "reason": f"high keyword overlap: {', '.join(overlap[:6])}",
                })
    return related, duplicates


def find_context_docs(docs_tree: Path, tokens: list[str], repo: str) -> list[dict]:
    context = []
    for path in docs_tree.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".md", ".json", ".yaml", ".yml"}:
            continue
        rel = path.relative_to(docs_tree).as_posix()
        if "/node_modules/" in rel or "/.git/" in rel:
            continue
        score = 0
        rel_low = rel.lower()
        if repo.replace("livemask-", "") in rel_low:
            score += 3
        try:
            sample = path.read_text(encoding="utf-8", errors="ignore")[:8000].lower()
        except Exception:
            sample = ""
        matched = [tok for tok in tokens if tok in rel_low or tok in sample]
        score += len(matched)
        if score:
            context.append({"path": rel, "score": score, "matched_terms": matched[:8]})
    context.sort(key=lambda d: (-d["score"], d["path"]))
    return context[:20]


def create_intelligence_pack(tid: str, title: str, body: str, repo: str,
                              role: str, check: str) -> dict:
    """Build the intelligence/context pack for a task."""
    ledger_path = DOCS_DIR / "docs/development/task-state-ledger.json"
    ledger = json.loads(ledger_path.read_text(encoding="utf-8")) if ledger_path.exists() else {"modules": []}

    tokens = extract_tokens(title, body, repo)
    related, duplicates = find_related_tasks(ledger, tokens, repo)
    docs_tree = DOCS_DIR / "docs"
    context_docs = find_context_docs(docs_tree, tokens, repo)
    quality_gates = REPO_QUALITY_OVERRIDES.get(repo, []) + QUALITY_GATES

    package = {
        "schema_version": 1, "task_id": tid, "title": title, "repo": repo,
        "source": {"role": role, "check": check, "body_excerpt": body[:600]},
        "query_terms": tokens,
        "duplicate_blocker": bool(duplicates),
        "duplicate_signals": duplicates[:8],
        "related_tasks": related[:12],
        "context_docs": context_docs[:20],
        "repo_doc_hints": REPO_DOC_HINTS.get(repo, ["docs/development", "docs/contracts", "docs/architecture"]),
        "code_quality_gates": quality_gates,
        "github_issue_candidates": [],
        "ledger_issue_refs": [],
        "no_duplicate_rule": "If duplicate_signals is non-empty, do not create a new task; update or unblock the existing task instead.",
    }

    # Write to cache
    intel_path = CACHE_DIR / f"task-intelligence-{tid}.json"
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    intel_path.write_text(json.dumps(package, indent=2, ensure_ascii=False), encoding="utf-8")

    return package


def create_task_doc(tid: str, title: str, body: str, repo: str, priority: str,
                    role: str, check: str, intelligence: dict, issue_url: str = "") -> Path:
    """Create the task markdown document. Returns path."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    TASK_DIR.mkdir(parents=True, exist_ok=True)

    # Build context pack section
    context_lines = [f"- Intelligence pack: `{CACHE_DIR / f'task-intelligence-{tid}.json'}`",
                     f"- Source: role-engine {role}/{check}",
                     f"- Query terms: {', '.join(intelligence.get('query_terms', [])[:10]) or 'none'}"]
    for item in intelligence.get("repo_doc_hints", [])[:8]:
        context_lines.append(f"  - `{item}`")
    if intelligence.get("context_docs"):
        context_lines.append("- Highest-signal project docs:")
        for item in intelligence["context_docs"][:8]:
            terms = ", ".join(item.get("matched_terms", [])[:5])
            context_lines.append(f"  - `{item['path']}` (score={item['score']}; terms={terms})")
    if intelligence.get("related_tasks"):
        context_lines.append("- Related ledger tasks:")
        for item in intelligence["related_tasks"][:8]:
            iss = f"; issue={item.get('issue')}" if item.get("issue") else ""
            context_lines.append(f"  - `{item.get('task_id', '?')}` status={item.get('status', '?')} repo={item.get('repo', '?')} relation={item.get('relation', '?')}{iss}")

    cross_repo = {"livemask-backend": "- Admin UI, App client, NodeAgent, Job Service, Website, CI/CD smoke",
                  "livemask-admin": "- CI/CD admin smoke tests",
                  "livemask-app": "- CI/CD app build/release smoke",
                  "livemask-nodeagent": "- Backend internal API, CI/CD node smoke",
                  "livemask-job-service": "- Backend executor endpoints, CI/CD job smoke",
                  "livemask-ci-cd": "- All repos (CI/CD script changes affect all)",
                  "livemask-docs": "- All repos (contract/rule changes need implementation)",
                 }.get(repo, "- Related repos as identified during implementation")

    quality_lines = [f"- {g}" for g in intelligence.get("code_quality_gates", QUALITY_GATES)]

    doc = f"""# {tid} — {title}

Edit provenance:
- Edited by: Claude Role Engine
- Window/role: livemask-ci-cd role-engine
- Date: {now}
- TASK ID: {tid}
- Reason: auto-created from role-engine finding {role}/{check}

> Status: ready
> Repository: {repo}
> Priority: {priority}
> Source: role-engine {role}/{check}
> Created: {now}
> Issue: {issue_url or 'TBD — create manually'}

## 1. Background

Role-engine {role}/{check} detected an actionable gap: {title}

{body}

### 1.1 Project Context Pack

{chr(10).join(context_lines)}

## 2. Scope

### In Scope
- Address the root cause identified by role-engine finding
- Implement the fix or improvement described above
- Reuse existing project helpers, contracts, schemas, runbooks, and task patterns found in the context pack
- Preserve or update related task/GitHub issue/comment evidence

### Out of Scope
- Unrelated refactoring or feature additions
- Rebuilding an existing capability under a new name

## 3. Acceptance Criteria
- [ ] Root cause verified and addressed
- [ ] Implementation validated with appropriate evidence
- [ ] No regression in existing functionality
- [ ] Related task IDs, blockers, and unlocks explicitly handled
- [ ] Linked GitHub issue(s) cited in completion report
- [ ] No duplicate TASK, dispatch packet, issue, helper, or CI lane introduced
- [ ] Code follows existing repo architecture

## 4. Cross-Repo Impact

This task affects **{repo}**. Downstream repos to verify:
{cross_repo}

## 5. Validation
- check-docs.sh PASS
- git diff --check PASS
- CI/CD pipeline green for affected repos

### 5.1 Code Quality Gates
{chr(10).join(quality_lines)}
"""
    doc_path = TASK_DIR / f"{tid}.md"
    doc_path.write_text(doc, encoding="utf-8")
    return doc_path


def create_dispatch_packet(tid: str, title: str, repo: str, priority: str,
                           role: str, check: str, intelligence_path: str) -> Path:
    """Create dispatch packet JSON. Returns path."""
    DISPATCH_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc)
    dp = {
        "schema_version": 1, "task_id": tid, "repo": repo, "priority": priority,
        "readiness": "ready", "assigned_to": "claude",
        "assigned_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expires_at": (now.replace(hour=(now.hour + 2) % 24)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "assigned_by": "Claude-Role-Engine",
        "reason": f"{role}/{check}: {title}",
        "why_now": [f"{role}/{check}: {title}"],
        "context": {
            "generated_by": "Claude-Role-Engine",
            "source": f"role-engine {role}/{check}",
            "task_doc": f"docs/development/tasks/{tid}.md",
            "intelligence_pack": intelligence_path,
        },
        "acceptance": {
            "task_doc_exists": f"docs/development/tasks/{tid}.md",
            "ledger_status": "dispatched",
            "evidence_required": True,
            "must_cite_context_pack": True,
            "must_cite_github_issue_or_explain_absence": True,
            "must_pass_code_quality_gates": True,
            "must_not_duplicate_existing_task_or_helper": True,
        },
    }
    dp_path = DISPATCH_DIR / f"{tid}.json"
    dp_path.write_text(json.dumps(dp, indent=2), encoding="utf-8")
    return dp_path


# ══════════════════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════════════════

def cmd_create(args):
    """Create all artifacts for a new auto-task."""
    repo = args.repo
    if repo not in CANONICAL_REPOS:
        print(json.dumps({"status": "rejected", "reason": f"repo '{repo}' is not canonical"}), file=sys.stderr)
        sys.exit(1)

    tid = generate_task_id(repo, args.title)

    # Check if task already exists in ledger (only block on non-terminal tasks with dispatch packet)
    TERMINAL = {"completed", "completed_with_skip", "cancelled", "closed", "rejected"}
    ledger_path = DOCS_DIR / "docs/development/task-state-ledger.json"
    if ledger_path.exists():
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        for mod in ledger.get("modules", []):
            for t in mod.get("tasks", []):
                if t.get("task_id") == tid:
                    if t.get("status") not in TERMINAL:
                        # Check if dispatch packet exists — if not, task is orphaned, allow recreation
                        dp_file = DISPATCH_DIR / f"{tid}.json"
                        if dp_file.exists():
                            print(json.dumps({"status": "skipped", "reason": f"task {tid} already exists (status={t.get('status')}) with dispatch packet", "task_id": tid}))
                            sys.exit(0)
                        # No dispatch packet: orphaned task — allow recreation
                        print(json.dumps({"status": "note", "reason": f"task {tid} orphaned (no dispatch packet), allowing recreation", "task_id": tid}), file=sys.stderr)
                    # Terminal task or orphaned task: allow recreation

    # Generate intelligence pack
    intel = create_intelligence_pack(tid, args.title, args.body, repo, args.role, args.check)
    intel_path = str(CACHE_DIR / f"task-intelligence-{tid}.json")

    # Check for duplicates
    if intel.get("duplicate_blocker"):
        print(json.dumps({"status": "skipped", "reason": "duplicate signals found",
                          "task_id": tid, "signals": intel["duplicate_signals"][:3]}))
        sys.exit(0)

    # Get or create issue URL
    issue_url = args.issue or ""
    if not issue_url:
        issue_url = f"https://github.com/MyAiDevs/{repo}/issues (auto-create — create manually)"

    # Create task doc
    doc_path = create_task_doc(tid, args.title, args.body, repo, args.priority,
                               args.role, args.check, intel, issue_url)
    # Create dispatch packet
    dp_path = create_dispatch_packet(tid, args.title, repo, args.priority,
                                     args.role, args.check, intel_path)

    # Add to ledger
    import subprocess
    ledger_entry = {
        "task_id": tid, "repo": repo, "module_id": "auto-tasks", "status": "ready",
        "priority": args.priority,
        "task_doc": f"docs/development/tasks/{tid}.md",
        "issue": issue_url, "validation": "", "dev_merge_commit": "",
        "remote_dev_ref": "",
        "blocked_by": [t["task_id"] for t in intel.get("related_tasks", [])[:5]
                       if t.get("status") in ("blocked", "in_progress")],
        "unlocks": [],
        "notes": f"Auto-created by role-engine {args.role}/{args.check}; "
                 f"context_pack={intel_path}; "
                 f"related_tasks={','.join(t.get('task_id','') for t in intel.get('related_tasks',[])[:8] if t.get('task_id'))}; "
                 f"quality_gates={' | '.join(intel.get('code_quality_gates',[])[:6])}",
    }
    ledger_json = json.dumps(ledger_entry)
    result = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "ledger.py"), "add", ledger_json],
        capture_output=True, text=True, timeout=10
    )
    # Final summary (ONLY output on stdout)
    print(json.dumps({
        "status": "created", "task_id": tid, "repo": repo, "priority": args.priority,
        "doc_path": str(doc_path), "dp_path": str(dp_path),
        "intelligence_pack": intel_path, "issue_url": issue_url,
    }, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Task artifact creation")
    sub = parser.add_subparsers(dest="command", required=True)

    p_create = sub.add_parser("create", help="Create all task artifacts")
    p_create.add_argument("--role", required=True)
    p_create.add_argument("--check", required=True)
    p_create.add_argument("--title", required=True)
    p_create.add_argument("--repo", required=True)
    p_create.add_argument("--priority", default="P1")
    p_create.add_argument("--body", default="")
    p_create.add_argument("--issue", default="")

    args = parser.parse_args()

    if args.command == "create":
        cmd_create(args)


if __name__ == "__main__":
    main()
