#!/usr/bin/env python3
"""gaps.py — Contract gap detection for autonomous task creation.

Usage:
  python3 gaps.py detect DOCS-DIR              # → JSON [{domain, repo, repos_raw}, ...]
  python3 gaps.py audit AUDIT-FILE             # → debt_count blocker_count
"""
import json, re, sys, argparse
from pathlib import Path
from debug_utils import setup as _debug_setup, traced, logger as _logger

REPO_MAP = {
    "Backend": "livemask-backend", "Admin": "livemask-admin",
    "App": "livemask-app", "Website": "livemask-website",
    "CI-CD": "livemask-ci-cd", "CI/CD": "livemask-ci-cd",
    "NodeAgent": "livemask-nodeagent", "Job Service": "livemask-job-service",
    "Jobs": "livemask-job-service", "Docs": "livemask-docs",
}

TERMINAL_STATUSES = {"completed", "completed_with_skip", "cancelled", "closed"}


def detect_contract_gaps(docs_dir: Path) -> list[dict]:
    """Find Ready contracts without open implementation tasks."""
    ledger_path = docs_dir / "docs/development/task-state-ledger.json"
    if not ledger_path.exists():
        return []

    ledger = json.loads(ledger_path.read_text(encoding="utf-8"))

    # Open task IDs — only non-terminal tasks block gap creation
    open_task_ids = set()
    open_text_parts = []
    for mod in ledger.get("modules", []):
        for t in mod.get("tasks", []):
            tid = t.get("task_id", "")
            if not tid:
                continue
            if t.get("status") not in TERMINAL_STATUSES:
                open_task_ids.add(tid)
                open_text_parts.append((t.get("notes", "") + " " + t.get("task_doc", "")).lower())
    open_text = " ".join(open_text_parts)

    ci = docs_dir / "docs/contracts/contract-index.md"
    if not ci.exists():
        return []

    gaps = []
    for line in ci.read_text(encoding="utf-8", errors="replace").splitlines():
        if "| Ready |" not in line:
            continue

        # Extract referenced task IDs from contract line
        tasks_in_line = re.findall(r"TASK-[A-Z0-9-]+", line)
        # Only skip if there's an OPEN task (completed doc tasks don't block)
        if tasks_in_line and any(tid in open_task_ids for tid in tasks_in_line):
            continue

        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 6:
            continue

        domain = (parts[1] or "unknown")[:80]
        domain_key = re.sub(r"[^a-z0-9]+", "-", domain.lower()).strip("-")[:30]
        if domain_key and domain_key in open_text:
            continue

        repos_raw = (parts[5] or "Backend")[:120]
        first_repo = repos_raw.split("/")[0].strip()
        repo = REPO_MAP.get(first_repo, first_repo if first_repo.startswith("livemask-") else "livemask-backend")

        gaps.append({
            "domain": domain,
            "repo": repo,
            "repos_raw": repos_raw,
            "contract_tasks": tasks_in_line,
        })

    return gaps


def audit_debt(audit_file: Path) -> tuple[int, int]:
    """Read closed-loop audit file, return (debt_count, blocker_count)."""
    if not audit_file.exists():
        return 0, 0
    try:
        d = json.loads(audit_file.read_text(encoding="utf-8"))
        s = d.get("summary", {})
        return int(s.get("completion_debt_count", 0)), int(s.get("active_blocker_count", 0))
    except Exception:
        return 0, 0


@traced
def main():
    _debug_setup()
    parser = argparse.ArgumentParser(description="Contract gap detection")
    sub = parser.add_subparsers(dest="command", required=True)

    p_detect = sub.add_parser("detect", help="Detect Ready contracts without open implementation tasks")
    p_detect.add_argument("docs_dir")

    p_audit = sub.add_parser("audit", help="Read closed-loop audit file")
    p_audit.add_argument("audit_file")

    args = parser.parse_args()

    if args.command == "detect":
        gaps = detect_contract_gaps(Path(args.docs_dir))
        print(json.dumps({"gaps": gaps, "count": len(gaps)}, indent=2))
        sys.exit(0)

    elif args.command == "audit":
        debt, blockers = audit_debt(Path(args.audit_file))
        print(f"{debt} {blockers}")
        sys.exit(0)


if __name__ == "__main__":
    main()
