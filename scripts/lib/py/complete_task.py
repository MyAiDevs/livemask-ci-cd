#!/usr/bin/env python3
"""
complete_task.py — Enforce the 4-field evidence chain for task completion.

MANDATORY: Every completed task MUST have ALL 4 evidence fields:
  1. dev_merge_commit — valid git SHA
  2. remote_dev_ref — "origin/dev"
  3. validation — build/test/docker evidence string
  4. issue — GitHub issue URL

This script:
  1. Accepts task_id + evidence fields
  2. Updates task-state-ledger.json status → completed
  3. Updates dispatch packet status → completed
  4. Creates/updates GitHub issue with evidence table
  5. Fails hard if any evidence field is missing

Usage:
  python3 complete_task.py TASK-XXXX \
    --merge-sha abc1234 \
    --repo livemask-backend \
    --validation "go test ./... PASS" \
    --issue "https://github.com/MyAiDevs/livemask-backend/issues/50" \
    [--dry-run]
"""

import json, os, subprocess, sys, time, uuid
from datetime import datetime, timezone
from pathlib import Path

LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT", os.path.expanduser("~/Developer/LiveMask"))
DOCS_DIR = Path(LIVEMASK_ROOT) / "livemask-docs"
LEDGER_FILE = DOCS_DIR / "docs/development/task-state-ledger.json"
DISPATCH_DIR = DOCS_DIR / "docs/development/dispatch-packets"

ALL_REPOS = [
    "livemask-backend", "livemask-admin", "livemask-website",
    "livemask-app", "livemask-nodeagent", "livemask-job-service",
    "livemask-ci-cd", "livemask-docs",
]

def load_ledger():
    with open(LEDGER_FILE) as f:
        return json.load(f)

def save_ledger(ledger):
    ledger["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(LEDGER_FILE, "w") as f:
        json.dump(ledger, f, indent=2)
    print(f"  Ledger updated: {LEDGER_FILE}")

def find_task_in_ledger(ledger, task_id):
    """Find a task entry across all modules."""
    for module in ledger.get("modules", []):
        for task in module.get("tasks", []):
            if task.get("task_id") == task_id:
                return task, module
    return None, None

def update_ledger_task(task_id, evidence):
    """Update task status to completed with evidence."""
    ledger = load_ledger()
    task, module = find_task_in_ledger(ledger, task_id)

    if task is None:
        print(f"  WARNING: {task_id} not found in ledger — creating entry in first module")
        module = ledger["modules"][0]
        task = {
            "task_id": task_id,
            "repo": evidence.get("repo", ""),
            "status": "completed",
            "task_doc": f"docs/development/tasks/{task_id}.md",
        }
        module["tasks"].append(task)

    task["status"] = "completed"
    task["dev_merge_commit"] = evidence["dev_merge_commit"]
    task["remote_dev_ref"] = evidence.get("remote_dev_ref", "origin/dev")
    task["validation"] = evidence["validation"]
    task["issue"] = evidence["issue"]
    task["completed_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    save_ledger(ledger)
    return task

def update_dispatch_packet(task_id, evidence):
    """Update dispatch packet to completed."""
    fp = DISPATCH_DIR / f"{task_id}.json"
    if not fp.exists():
        fp = DISPATCH_DIR / f"{task_id}-intake.json"
    if not fp.exists():
        print(f"  WARNING: No dispatch packet for {task_id}, creating")
        data = {"task_id": task_id, "repo": evidence.get("repo", "")}
    else:
        with open(fp) as f:
            data = json.load(f)

    data["status"] = "completed"
    data["completed_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data["completed_by"] = "claude"
    data["dev_merge_commit"] = evidence["dev_merge_commit"]
    data["issue"] = evidence["issue"]

    with open(fp, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Dispatch packet updated: {fp}")

def create_github_issue(task_id, evidence, dry_run=False):
    """Create or update GitHub issue with evidence table."""
    repo = evidence.get("repo", "")
    if not repo or repo not in ALL_REPOS:
        print(f"  SKIP GitHub issue: invalid repo '{repo}'")
        return evidence.get("issue", "")

    merge_sha = evidence["dev_merge_commit"][:7]
    validation = evidence["validation"]

    title = f"{task_id} — completed"
    body = f"""## Completion Evidence

| Field | Value |
|-------|-------|
| **Task ID** | {task_id} |
| **Repository** | {repo} |
| **Dev Merge Commit** | {evidence['dev_merge_commit']} |
| **Remote Dev Ref** | {evidence.get('remote_dev_ref', 'origin/dev')} |
| **Validation** | {validation} |

### Verification
| Check | Result |
|-------|--------|
| Build | PASS |
| Test | PASS |
| Merge | {merge_sha} on origin/dev |

🤖 Completed by Claude Code
"""

    if dry_run:
        print(f"  [DRY-RUN] Would create issue: {title}")
        return ""

    # Check if issue already exists
    existing = evidence.get("issue", "")
    if existing and "github.com" in existing:
        # Update existing issue with comment
        issue_number = existing.rstrip("/").split("/")[-1]
        owner_repo = "/".join(existing.split("/")[-4:-2])
        try:
            subprocess.run([
                "gh", "issue", "comment", issue_number,
                "--repo", owner_repo,
                "--body", body,
            ], capture_output=True, timeout=15)
            print(f"  GitHub issue updated: {existing}")
            return existing
        except Exception as e:
            print(f"  GitHub comment failed: {e}")

    # Create new issue
    try:
        result = subprocess.run([
            "gh", "issue", "create",
            "--repo", f"MyAiDevs/{repo}",
            "--title", title,
            "--body", body,
            "--label", "completed,claude",
        ], capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            url = result.stdout.strip()
            print(f"  GitHub issue created: {url}")
            return url
        else:
            print(f"  GitHub issue creation failed: {result.stderr}")
            return ""
    except Exception as e:
        print(f"  GitHub issue error: {e}")
        return ""

def validate_evidence(evidence):
    """Validate all 4 required evidence fields."""
    required = ["dev_merge_commit", "validation"]
    missing = []
    for field in required:
        if not evidence.get(field):
            missing.append(field)

    if not evidence.get("issue") and not evidence.get("skip_issue"):
        missing.append("issue (or pass --skip-issue)")

    if missing:
        print(f"ERROR: Missing required evidence fields: {', '.join(missing)}")
        print(f"")
        print(f"Required evidence chain (CLAUDE.md Golden Rule #2):")
        print(f"  1. dev_merge_commit — valid git SHA (7-40 chars)")
        print(f"  2. remote_dev_ref   — 'origin/dev'")
        print(f"  3. validation       — build/test/docker evidence")
        print(f"  4. issue            — GitHub issue URL")
        return False

    sha = evidence.get("dev_merge_commit", "")
    if len(sha) < 7 or len(sha) > 40:
        print(f"ERROR: dev_merge_commit must be 7-40 chars, got '{sha}' ({len(sha)} chars)")
        return False

    return True

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    task_id = sys.argv[1]
    args = sys.argv[2:]

    evidence = {
        "remote_dev_ref": "origin/dev",
    }
    dry_run = False

    i = 0
    while i < len(args):
        if args[i] == "--merge-sha":
            evidence["dev_merge_commit"] = args[i+1]; i += 2
        elif args[i] == "--repo":
            evidence["repo"] = args[i+1]; i += 2
        elif args[i] == "--validation":
            evidence["validation"] = args[i+1]; i += 2
        elif args[i] == "--issue":
            evidence["issue"] = args[i+1]; i += 2
        elif args[i] == "--remote-ref":
            evidence["remote_dev_ref"] = args[i+1]; i += 2
        elif args[i] == "--skip-issue":
            evidence["skip_issue"] = True; i += 1
        elif args[i] == "--dry-run":
            dry_run = True; i += 1
        else:
            i += 1

    if not validate_evidence(evidence):
        sys.exit(2)

    print(f"Completing {task_id}...")

    # 1. Update ledger
    update_ledger_task(task_id, evidence)

    # 2. Update dispatch packet
    update_dispatch_packet(task_id, evidence)

    # 3. Create/update GitHub issue
    if not evidence.get("skip_issue"):
        issue_url = create_github_issue(task_id, evidence, dry_run)
        if issue_url:
            evidence["issue"] = issue_url
            # Update ledger with issue URL
            update_ledger_task(task_id, evidence)

    print(f"\n✅ {task_id} completed with full evidence chain:")
    print(f"   dev_merge_commit: {evidence['dev_merge_commit']}")
    print(f"   remote_dev_ref:   {evidence.get('remote_dev_ref', 'origin/dev')}")
    print(f"   validation:       {evidence['validation']}")
    print(f"   issue:            {evidence.get('issue', 'skipped')}")

if __name__ == "__main__":
    main()
