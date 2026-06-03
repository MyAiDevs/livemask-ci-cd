#!/usr/bin/env python3
"""
planner.py — Document-aware task planner with GitHub sync for Claude dev loop.

Analyzes the Contract Index, MVP Implementation Plan, Task State Ledger, AND
GitHub open issues to discover undeveloped tasks, rank by priority, create
dispatch packets, sync GitHub issues, and produce evidence chain stubs.

Three data sources (local):
  - docs/contracts/contract-index.md      (contract statuses → task IDs)
  - docs/development/MVP_IMPLEMENTATION_PLAN.md  (known tasks + priority)
  - docs/development/task-state-ledger.json  (completed / blocked states)

Two data sources (remote, via gh CLI):
  - GitHub issues per repo (to avoid duplicate issue creation)
  - GitHub issue creation for new dispatch packets

Commands:
  plan                              Analyze + rank undeveloped tasks (JSON)
  plan --output md                  Output readable Markdown table
  plan --create-dispatch N          Create N dispatch packets + GitHub issues
  plan --sync-gh                    Scan GitHub issues first, cross-reference
  evidence <task_id> --merge-sha H  Record merge commit for evidence chain
  evidence <task_id> --validation S Record validation evidence
  evidence <task_id> --issue URL    Record GitHub issue URL
  evidence-show <task_id>           Show recorded evidence
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone


# ── Constants ──────────────────────────────────────────────────────────────
REPO_PREFIX = "MyAiDevs"
DEFAULT_ROOT = os.path.expanduser("~/Developer/LiveMask")

# ── Evidence Chain keys ───────────────────────────────────────────────────
EVIDENCE_FIELDS = ["dev_merge_commit", "remote_dev_ref", "validation", "issue"]


# ── Path helpers ────────────────────────────────────────────────────────────
def _resolve(path: str) -> str:
    if os.path.isabs(path):
        return path
    for base in [os.environ.get("LIVEMASK_ROOT", ""), DEFAULT_ROOT]:
        full = os.path.join(base, path)
        if os.path.exists(full):
            return full
    return path


def _gh_available() -> bool:
    """Check if GitHub CLI is installed and authenticated."""
    try:
        r = subprocess.run(
            ["gh", "auth", "status"],
            capture_output=True, text=True, timeout=10,
        )
        return r.returncode == 0 and "Logged in" in r.stdout
    except Exception:
        return False


def _run_gh(args: list[str]) -> subprocess.CompletedProcess:
    """Run gh CLI with the given args. Returns CompletedProcess."""
    try:
        return subprocess.run(
            ["gh"] + args, capture_output=True, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess([], 1, "", "gh command timed out")
    except FileNotFoundError:
        return subprocess.CompletedProcess([], 1, "", "gh CLI not found")


# ── Source 1: Contract Index ────────────────────────────────────────────────
def parse_contract_index(path: str) -> list[dict]:
    """Parse contract-index.md → list of {domain, contract, status, task_id, repos}."""
    contracts = []
    if not os.path.exists(path):
        return contracts

    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    in_table = False
    headers = []

    for line in lines:
        if line.strip().startswith("| ") and "---" not in line:
            cells = [c.strip() for c in line.split("|")[1:-1]]
            if not in_table:
                headers = cells
                in_table = True
                continue
            if len(cells) < 3:
                continue
            if "Domain" in headers:
                domain_idx = headers.index("Domain")
                if len(cells) <= domain_idx:
                    continue
                entry = {"domain": cells[domain_idx]}
                for label, idx_key in [("Contract", "name"), ("Status", "status"),
                                        ("Primary Task", "task_id"), ("Impacted Repos", "repos")]:
                    if label in headers:
                        idx = headers.index(label)
                        entry[idx_key] = cells[idx] if idx < len(cells) else ""
                raw = entry.get("task_id", "")
                m = re.search(r'`([^`]+)`', raw)
                if m:
                    entry["task_id"] = m.group(1)
                elif raw:
                    entry["task_id"] = raw.strip()
                else:
                    entry["task_id"] = ""
                raw_repos = entry.get("repos", "")
                repos = [r.strip() for r in raw_repos.split("/") if r.strip()]
                entry["repos"] = repos
                contracts.append(entry)
        elif line.strip().startswith("| ---"):
            continue
        else:
            in_table = False
    return contracts


# ── Source 2: MVP Implementation Plan ───────────────────────────────────────
class MVPTask:
    __slots__ = ("task_id", "target", "owner_repos", "deps", "status_raw",
                 "section", "priority_hint", "line_number", "source_table")
    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k, ""))


def parse_mvp_plan(path: str) -> list[MVPTask]:
    tasks = []
    if not os.path.exists(path):
        return tasks
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    current_section = "unknown"
    current_headers = []
    in_table = False
    for lineno, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("## "):
            current_section = stripped.lstrip("# ").strip()
            in_table = False
        if not stripped.startswith("|"):
            in_table = False
            continue
        if "---" in stripped:
            in_table = True
            continue
        cells = [c.strip() for c in stripped.split("|")[1:-1]]
        if len(cells) < 2:
            continue
        is_header = any(
            c.lower() in ("task", "目标", "owner", "依赖", "状态",
                          "taks", "subtask", "domain", "contract",
                          "subtask", "项目", "子域", "taks id")
            for c in cells[:4]
        )
        if is_header:
            current_headers = cells
            in_table = True
            continue
        if not in_table or not current_headers:
            continue
        stripped_full = " ".join(cells)
        if "✅" in stripped_full:
            continue
        has_task_link = bool(re.search(r'TASK-', stripped_full, re.IGNORECASE))
        has_emoji = bool(re.search(r'[⛔🟡🔴🟢⚪⚠️]', stripped_full))
        if not has_task_link and not has_emoji:
            continue
        task = MVPTask(section=current_section, line_number=lineno,
                       source_table=str(current_headers))
        for label, idx_key in [("Task", "task_id"), ("目标", "target"),
                                ("Owner", "owner_repos"), ("依赖", "deps"),
                                ("状态", "status_raw")]:
            if label in current_headers:
                idx = current_headers.index(label)
                if idx < len(cells):
                    setattr(task, idx_key, cells[idx])
        if not task.task_id:
            task.task_id = cells[0]
        link_match = re.search(r'\]\(tasks/(TASK-[^)]+)\)', stripped_full)
        if link_match:
            task.task_id = link_match.group(1).replace(".md", "")
        priority_match = re.search(r'(P[0-9])(?:-|/)', stripped_full)
        if priority_match:
            task.priority_hint = priority_match.group(1)
        if task.task_id:
            task.task_id = task.task_id.replace(".md", "")
        tasks.append(task)
    return tasks


# ── Source 3: Task State Ledger ─────────────────────────────────────────────
def load_ledger(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def get_ledger_task_ids(ledger: dict) -> set[str]:
    ids = set()
    for module in ledger.get("modules", []):
        for task in module.get("tasks", []):
            ids.add(task["task_id"].replace(".md", ""))
    return ids


def get_ledger_task_map(ledger: dict) -> dict[str, dict]:
    mapping = {}
    for module in ledger.get("modules", []):
        for task in module.get("tasks", []):
            mapping[task["task_id"]] = {**task, "module_id": module.get("module_id", "")}
    return mapping


def get_completed_module_ids(ledger: dict) -> set[str]:
    return {m["module_id"] for m in ledger.get("modules", [])
            if m.get("overall_status") == "completed"}


def _normalize_tid(tid: str) -> str:
    return tid.strip().replace(".md", "").strip()


# ── Source 4: GitHub Issues ─────────────────────────────────────────────────
def scan_github_issues(repos: list[str]) -> dict[str, list[dict]]:
    """
    Scan GitHub open issues across the given repos.
    Returns {repo: [{number, title, url, labels}]}.
    """
    result = {}
    if not _gh_available():
        return result

    for repo in repos:
        r = _run_gh(["issue", "list",
                      "--repo", f"{REPO_PREFIX}/{repo}",
                      "--state", "open",
                      "--limit", "100",
                      "--json", "number,title,url,labels"])
        if r.returncode != 0:
            continue
        try:
            issues = json.loads(r.stdout)
            result[repo] = [
                {
                    "number": i["number"],
                    "title": i["title"],
                    "url": i["url"],
                    "labels": [l["name"] for l in i.get("labels", [])],
                }
                for i in issues
            ]
        except json.JSONDecodeError:
            continue
    return result


def match_github_issues(gaps: list[dict],
                        gh_issues: dict[str, list[dict]]) -> list[dict]:
    """
    Cross-reference gaps against GitHub issues.
    Enriches each gap with 'existing_gh_issues' if any issues reference the TASK ID.
    """
    enriched = []
    for gap in gaps:
        tid = gap["task_id"]
        repos = gap.get("repos", [])
        matches = []
        for repo in repos:
            for issue in gh_issues.get(repo, []):
                if tid in issue["title"] or tid in issue["body"]:
                    matches.append(issue)
        gap["existing_gh_issues"] = matches
        gap["gh_synced"] = len(matches) > 0
        enriched.append(gap)
    return enriched


# ── Analysis Engine ─────────────────────────────────────────────────────────

def analyze_gaps(contract_path: str, mvp_path: str, ledger_path: str,
                 tasks_dir: str = "", sync_gh: bool = False) -> dict:
    """Core analysis: cross-reference all sources and identify gaps."""

    contracts = parse_contract_index(contract_path)
    mvp_tasks = parse_mvp_plan(mvp_path)

    ledger = load_ledger(ledger_path)
    ledger_ids = get_ledger_task_ids(ledger)
    ledger_map = get_ledger_task_map(ledger)
    completed_modules = get_completed_module_ids(ledger)

    # Collect existing task doc files
    existing_task_docs = set()
    if tasks_dir and os.path.isdir(tasks_dir):
        for fname in os.listdir(tasks_dir):
            m = re.match(r'(TASK-[^.]+)', fname, re.IGNORECASE)
            if m:
                existing_task_docs.add(m.group(1).replace(".md", ""))

    gaps = []
    seen = set()

    # Gap 1: Contracts with status=Ready but no ledger entry
    for c in contracts:
        tid = _normalize_tid(c.get("task_id", ""))
        status = c.get("status", "").lower()
        if status in ("ready", "draft") and tid and tid not in ledger_ids:
            if tid not in seen:
                gaps.append({
                    "task_id": tid,
                    "source": "contract_index",
                    "domain": c.get("domain", ""),
                    "contract_name": c.get("name", c.get("contract", "")),
                    "contract_status": status,
                    "repos": c.get("repos", []),
                    "reason": f"Contract index lists '{c.get('name', tid)}' as {status}, "
                              f"but no ledger entry found",
                    "has_task_doc": tid in existing_task_docs,
                    "priority_score": _priority_score(status, "contract", c.get("domain", "")),
                })
                seen.add(tid)

    # Gap 2: MVP plan tasks not in ledger
    for mt in mvp_tasks:
        tid = _normalize_tid(mt.task_id or "")
        if not tid or tid in ledger_ids or tid in seen:
            continue
        status_raw = (mt.status_raw or "").strip()
        if "✅" in status_raw or "PASS" in status_raw.upper():
            continue
        has_doc = tid in existing_task_docs
        is_ready = "🟡" in status_raw or "Ready" in status_raw
        is_blocked = "⛔" in status_raw
        repos_raw = getattr(mt, 'owner_repos', '') or ''
        repos = [r.strip() for r in re.sub(r'[`\[\]]', '', repos_raw).split("/") if r.strip()]
        reason_parts = []
        if is_blocked:
            reason_parts.append("Blocked in MVP plan")
        elif is_ready:
            reason_parts.append("Ready in MVP plan")
        else:
            section = mt.section or ""
            if "下一阶段" in section or "next" in section.lower():
                reason_parts.append("Next-phase task in MVP plan")
            else:
                reason_parts.append("Unplanned task gap in MVP plan")
        if has_doc:
            reason_parts.append("(task doc exists)")
        if not has_doc and not is_ready and not is_blocked:
            continue
        gaps.append({
            "task_id": tid,
            "source": "mvp_plan",
            "section": mt.section,
            "target": getattr(mt, 'target', ''),
            "deps": getattr(mt, 'deps', ''),
            "status_raw": mt.status_raw,
            "repos": repos,
            "reason": " | ".join(reason_parts),
            "has_task_doc": has_doc,
            "is_blocked": is_blocked,
            "priority_score": _priority_score(
                "ready" if is_ready else "blocked" if is_blocked else "unplanned",
                "mvp", mt.section, mt.priority_hint,
            ),
        })
        seen.add(tid)

    # Gap 3: Dependency gaps from ledger unlock chains
    for module in ledger.get("modules", []):
        for task in module.get("tasks", []):
            for unlocked_tid in task.get("unlocks", []):
                unlocked_tid = _normalize_tid(unlocked_tid)
                if unlocked_tid not in ledger_ids and unlocked_tid not in seen:
                    gaps.append({
                        "task_id": unlocked_tid,
                        "source": "dependency_gap",
                        "unlocked_by": task["task_id"],
                        "module": module.get("module_id", ""),
                        "repos": [],
                        "reason": f"Unlocked by completed task {task['task_id']}, "
                                  f"but not in ledger",
                        "has_task_doc": unlocked_tid in existing_task_docs,
                        "priority_score": 85,
                    })
                    seen.add(unlocked_tid)

    # Sort by priority
    gaps.sort(key=lambda x: (-x.get("priority_score", 0), x.get("task_id", "")))

    # Cross-reference against GitHub issues
    gh_stats = {}
    if sync_gh and _gh_available():
        # Collect all repos referenced by gaps
        all_repos = set()
        for g in gaps:
            for r in g.get("repos", []):
                all_repos.add(r if r.startswith("livemask-") else f"livemask-{r}")
        # Filter to known repos
        known_repos = [r for r in all_repos if r in (
            "livemask-backend", "livemask-admin", "livemask-app",
            "livemask-nodeagent", "livemask-website", "livemask-job-service",
            "livemask-ci-cd", "livemask-docs",
        )]
        if known_repos:
            gh_issues = scan_github_issues(known_repos)
            gaps = match_github_issues(gaps, gh_issues)
            total_repo_issues = sum(len(v) for v in gh_issues.values())
            synced = sum(1 for g in gaps if g.get("gh_synced"))
            gh_stats = {
                "github_synced": True,
                "repos_scanned": known_repos,
                "total_gh_issues_found": total_repo_issues,
                "gaps_with_existing_issues": synced,
            }

    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total_ledger_tasks": len(ledger_ids),
        "completed_modules": len(completed_modules),
        "total_contracts": len(contracts),
        "total_mvp_rows": len(mvp_tasks),
        "gaps_found": len(gaps),
        "gaps": gaps,
        "github": gh_stats,
    }


def _priority_score(status: str, source: str, *contexts) -> int:
    base = 50
    if status == "ready":
        base = 90
    elif status == "draft":
        base = 40
    elif status == "stable":
        base = 20
    if source == "contract":
        base += 10
    elif source == "dependency_gap":
        base += 5
    for ctx in contexts:
        if "P0" in ctx or "P0-" in ctx:
            base += 30
        elif "P1" in ctx:
            base += 20
        elif "P2" in ctx:
            base += 10
        elif "P3" in ctx:
            base += 5
    return min(base, 100)


# ── Output Formatting ──────────────────────────────────────────────────────

def format_markdown(plan: dict) -> str:
    lines = [
        "# Task Planning Report",
        "",
        f"**Generated**: {plan['generated_at']}",
        "",
        "## Data Sources",
        f"| Source | Count |",
        f"|--------|-------|",
        f"| Ledger tasks | {plan['total_ledger_tasks']} |",
        f"| Completed modules | {plan['completed_modules']} |",
        f"| Contracts | {plan['total_contracts']} |",
        f"| MVP rows | {plan['total_mvp_rows']} |",
    ]
    gh = plan.get("github", {})
    if gh.get("github_synced"):
        lines.append(f"| GitHub repos scanned | {len(gh.get('repos_scanned', []))} |")
        lines.append(f"| Open GitHub issues | {gh.get('total_gh_issues_found', 0)} |")
        lines.append(f"| Gaps with existing issues | {gh.get('gaps_with_existing_issues', 0)} |")

    lines += [
        "",
        f"## Gaps Found: {plan['gaps_found']}",
        "",
        "| # | Task ID | Source | Priority | Repos | Doc? | GH Issue? | Reason |",
        "|---|---------|--------|----------|-------|------|-----------|--------|",
    ]

    for i, g in enumerate(plan["gaps"], 1):
        tid = g.get("task_id", "?")
        src = g.get("source", "?")
        score = g.get("priority_score", 0)
        repos = ", ".join(g.get("repos", []))[:35] or "—"
        has_doc = "✅" if g.get("has_task_doc") else "—"
        gh_issue = "✅" if g.get("gh_synced") else "—" if g.get("existing_gh_issues") is not None else "N/A"
        reason = g.get("reason", "")[:70]
        lines.append(f"| {i} | `{tid}` | {src} | {score} | {repos} | {has_doc} | {gh_issue} | {reason} |")

    lines.append("")
    return "\n".join(lines)


# ── Task Doc Creation ─────────────────────────────────────────────────────

def create_task_doc(gap: dict, tasks_dir: str) -> str:
    """Create a minimal TASK-XXX.md file from a gap entry."""
    tid = gap["task_id"]
    repo = ", ".join(gap.get("repos", [])) or "TBD"
    reason = gap.get("reason", "Auto-discovered by planner.py")
    source = gap.get("source", "planner")

    content = f"""# {tid} — Auto-discovered Task

- **Status**: ready
- **Owner**: Claude Agent
- **创建日期**: {datetime.now(timezone.utc).strftime("%Y-%m-%d")}
- **主影响仓库**: {repo}
- **来源**: planner.py ({source})

## 1. Background

{reason}

## 2. Scope

### In Scope
- [ ] TBD

### Out of Scope
- [ ] TBD

## 3. Acceptance Criteria

- [ ] TBD

## 4. Technical Notes

_To be filled during implementation._

## 5. Validation

- [ ] Build pass
- [ ] Test pass
"""

    os.makedirs(tasks_dir, exist_ok=True)
    doc_path = os.path.join(tasks_dir, f"{tid}.md")
    with open(doc_path, "w", encoding="utf-8") as f:
        f.write(content)
    return doc_path


# ── Dispatch Packet + GitHub Issue Creation ───────────────────────────────

def create_dispatch_packets(plan: dict, packet_dir: str,
                            count: int = 5,
                            create_gh_issues: bool = False,
                            tasks_dir: str = "") -> list[dict]:
    """Create dispatch packet JSON files + optionally GitHub issues + task docs."""
    created = []
    if not os.path.isdir(packet_dir):
        os.makedirs(packet_dir, exist_ok=True)

    for gap in plan["gaps"][:count]:
        tid = gap["task_id"]
        repo = gap.get("repos", [""])[0] if gap.get("repos") else ""

        # Don't create packet if gap already has a GitHub issue
        if gap.get("gh_synced"):
            continue

        # ── Create TASK-XXX.md doc if tasks_dir provided and doc doesn't exist ──
        if tasks_dir and tid:
            existing_doc = os.path.join(tasks_dir, f"{tid}.md")
            alt_tid = tid.replace(".md", "")
            alt_doc = os.path.join(tasks_dir, f"{alt_tid}.md")
            if not os.path.exists(existing_doc) and not os.path.exists(alt_doc):
                doc_path = create_task_doc(gap, tasks_dir)
                gap["task_doc_created"] = doc_path

        packet = {
            "task_id": tid,
            "source": "planner.py",
            "repo": repo,
            "reason": gap.get("reason", ""),
            "priority": gap.get("priority_score", 50),
            "status": "dispatch_packet",
        }

        fname = f"{tid}-planner-generated.json"
        fpath = os.path.join(packet_dir, fname)
        with open(fpath, "w", encoding="utf-8") as f:
            json.dump(packet, f, indent=2, ensure_ascii=False)

        entry = {"file": fpath, "task_id": tid, "repo": repo}

        # Optionally create GitHub issue
        if create_gh_issues and repo and _gh_available():
            gh_repo = f"{REPO_PREFIX}/{repo}"
            title = f"[{tid}] Auto-discovered: {gap.get('reason', 'Implementation')}"
            body = (
                f"## {tid}\n\n"
                f"**Source**: {gap.get('source', 'planner')}\n"
                f"**Priority**: {gap.get('priority_score', 50)}\n"
                f"**Reason**: {gap.get('reason', '')}\n\n"
                f"---\n\n"
                f"### Acceptance Criteria\n"
                f"- [ ] TBD\n\n"
                f"### Evidence Chain\n"
                f"| Field | Value |\n"
                f"|-------|-------|\n"
                f"| dev_merge_commit | `pending` |\n"
                f"| remote_dev_ref | `pending` |\n"
                f"| validation | `pending` |\n"
                f"| issue | `pending` |\n\n"
                f"_Auto-created by planner.py_"
            )
            r = _run_gh(["issue", "create",
                          "--repo", gh_repo,
                          "--title", title,
                          "--body", body,
                          "--label", "auto"])
            if r.returncode == 0:
                issue_url = r.stdout.strip()
                entry["issue_url"] = issue_url
                # Update the gap with the issue URL
                gap["created_gh_issue_url"] = issue_url

        created.append(entry)

    return created


# ── Evidence Recording ─────────────────────────────────────────────────────

def cmd_evidence(args: list[str]) -> int:
    """Record evidence for a task in the evidence chain log."""
    if not args:
        print(json.dumps({"error": "usage: evidence <task_id> --merge-sha H | --validation S"}),
              file=sys.stderr)
        return 1

    task_id = args[0]
    ev_dir = os.path.join(os.environ.get("HOME", "/tmp"), ".claude", "role-cache", "evidence")
    os.makedirs(ev_dir, exist_ok=True)
    ev_file = os.path.join(ev_dir, f"{task_id}.json")

    # Load existing evidence
    evidence = {}
    if os.path.exists(ev_file):
        try:
            with open(ev_file) as f:
                evidence = json.load(f)
        except (json.JSONDecodeError, OSError):
            evidence = {}

    evidence.setdefault("task_id", task_id)
    evidence.setdefault("dev_merge_commit", "")
    evidence.setdefault("remote_dev_ref", "")
    evidence.setdefault("validation", "")
    evidence.setdefault("issue", "")
    evidence.setdefault("_history", [])

    i = 1
    while i < len(args):
        if args[i] == "--merge-sha" and i + 1 < len(args):
            sha = args[i + 1]
            evidence["dev_merge_commit"] = sha
            evidence["remote_dev_ref"] = sha  # same for local dev
            evidence["_history"].append({
                "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "field": "dev_merge_commit",
                "value": sha,
            })
            i += 2
        elif args[i] == "--validation" and i + 1 < len(args):
            val = args[i + 1]
            evidence["validation"] = val
            evidence["_history"].append({
                "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "field": "validation",
                "value": val,
            })
            i += 2
        elif args[i] == "--issue" and i + 1 < len(args):
            url = args[i + 1]
            evidence["issue"] = url
            evidence["_history"].append({
                "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "field": "issue",
                "value": url,
            })
            i += 2
        else:
            i += 1

    with open(ev_file, "w") as f:
        json.dump(evidence, f, indent=2, ensure_ascii=False)

    print(json.dumps({"status": "ok", "task_id": task_id, "evidence": evidence}, indent=2))
    return 0


def cmd_evidence_show(args: list[str]) -> int:
    """Show recorded evidence for a task."""
    if not args:
        print(json.dumps({"error": "usage: evidence-show <task_id>"}), file=sys.stderr)
        return 1

    task_id = args[0]
    ev_dir = os.path.join(os.environ.get("HOME", "/tmp"), ".claude", "role-cache", "evidence")
    ev_file = os.path.join(ev_dir, f"{task_id}.json")

    if not os.path.exists(ev_file):
        print(json.dumps({"status": "not_found", "task_id": task_id, "message": "no evidence recorded"}))
        return 1

    with open(ev_file) as f:
        evidence = json.load(f)

    print(json.dumps(evidence, indent=2))
    return 0


# ── CLI ────────────────────────────────────────────────────────────────────

def cmd_plan(args: list[str]) -> int:
    contract_path = ""
    mvp_path = ""
    ledger_path = ""
    tasks_dir = ""
    output_format = "json"
    create_dispatch = 0
    sync_gh = False

    i = 0
    while i < len(args):
        if args[i] == "--contracts" and i + 1 < len(args):
            contract_path = _resolve(args[i + 1]); i += 2
        elif args[i] == "--mvp" and i + 1 < len(args):
            mvp_path = _resolve(args[i + 1]); i += 2
        elif args[i] == "--ledger" and i + 1 < len(args):
            ledger_path = _resolve(args[i + 1]); i += 2
        elif args[i] == "--tasks-dir" and i + 1 < len(args):
            tasks_dir = _resolve(args[i + 1]); i += 2
        elif args[i] == "--output" and i + 1 < len(args):
            output_format = args[i + 1].lower(); i += 2
        elif args[i] == "--create-dispatch" and i + 1 < len(args):
            try: create_dispatch = int(args[i + 1])
            except ValueError: create_dispatch = 5
            i += 2
        elif args[i] == "--sync-gh":
            sync_gh = True; i += 1
        elif args[i] == "--create-gh-issues":
            # Implies --sync-gh and creates GH issues for dispatch packets
            sync_gh = True
            if i + 1 < len(args) and args[i + 1].isdigit():
                try: create_dispatch = int(args[i + 1])
                except ValueError: create_dispatch = 5
                i += 2
            else:
                create_dispatch = 5
                i += 1
        else:
            i += 1

    root = os.environ.get("LIVEMASK_ROOT", DEFAULT_ROOT)
    docs_dir = os.path.join(root, "livemask-docs", "docs")

    if not contract_path:
        contract_path = os.path.join(docs_dir, "contracts", "contract-index.md")
    if not mvp_path:
        mvp_path = os.path.join(docs_dir, "development", "MVP_IMPLEMENTATION_PLAN.md")
    if not ledger_path:
        ledger_path = os.path.join(docs_dir, "development", "task-state-ledger.json")
    if not tasks_dir:
        tasks_dir = os.path.join(docs_dir, "development", "tasks")

    missing = []
    for label, p in [("contract index", contract_path), ("MVP plan", mvp_path),
                      ("ledger", ledger_path)]:
        if not os.path.exists(p):
            missing.append(f"{label}: {p}")
    if missing:
        print(json.dumps({"error": "missing files", "details": missing}), file=sys.stderr)
        return 1

    plan = analyze_gaps(contract_path, mvp_path, ledger_path, tasks_dir, sync_gh)

    if create_dispatch > 0:
        packet_dir = os.path.join(os.path.dirname(ledger_path), "dispatch-packets")
        create_gh_issues = "--create-gh-issues" in sys.argv
        created = create_dispatch_packets(plan, packet_dir, create_dispatch, create_gh_issues, tasks_dir)
        plan["dispatch_packets_created"] = len(created)
        plan["dispatch_packet_files"] = [e["file"] for e in created]
        plan["gh_issues_created"] = [e.get("issue_url", "") for e in created if e.get("issue_url")]

    if output_format == "md":
        print(format_markdown(plan))
    else:
        print(json.dumps(plan, indent=2, ensure_ascii=False))

    return 0


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: planner.py <plan|evidence|evidence-show> [flags]"}),
              file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    try:
        if command == "plan":
            rc = cmd_plan(args)
        elif command == "evidence":
            rc = cmd_evidence(args)
        elif command == "evidence-show":
            rc = cmd_evidence_show(args)
        else:
            print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
            rc = 1
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
