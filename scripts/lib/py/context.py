#!/usr/bin/env python3
"""
context.py — Task context loader for the Claude dev loop.

Loads task context from the ledger, task document, and contracts directory,
then writes a structured JSON context file.

Usage:
    context.py load <task_id> --ledger <path> --docs <dir> --contracts <dir>

Output (JSON on stdout):
{
    "task_id": "TASK-...",
    "repo": "livemask-backend",
    "title": "...",
    "description": "...",
    "status": "...",
    "acceptance_criteria": [...],
    "validation_commands": [...],
    "contracts": [...],
    "source": "ledger|task-doc|contracts"
}
"""

import json
import os
import re
import sys
from pathlib import Path

from debug_utils import setup as _debug_setup, traced, logger as _logger


# ── Repo name resolution (mirrors dispatch.py) ────────────────────────

REPO_FIELD_MAP = {
    "livemask-backend": ("Backend", "go"),
    "livemask-admin": ("Admin", "node"),
    "livemask-website": ("Website", "node"),
    "livemask-app": ("App", "flutter"),
    "livemask-nodeagent": ("NodeAgent", "go"),
    "livemask-job-service": ("Job Service", "go"),
    "livemask-ci-cd": ("CI-CD", "shell"),
    "livemask-docs": ("Docs", "markdown"),
}


def _resolve_repo(impacted: str | list) -> str:
    if isinstance(impacted, str):
        impacted = [impacted]
    for ir in impacted:
        for repo, (kw, _) in REPO_FIELD_MAP.items():
            if kw.lower() in ir.lower():
                return repo
        if ir in REPO_FIELD_MAP:
            return ir
    return "livemask-docs"


def _normalize_repo(repo: str) -> str:
    """Convert repo keyword to directory name. (mirrors dispatch.py)"""
    if not repo:
        return "livemask-docs"
    repo_clean = repo.lower().strip()
    repo_with_spaces = repo_clean.replace("-", " ")
    for dirname, (keyword, _) in REPO_FIELD_MAP.items():
        key_lower = keyword.lower()
        if repo_clean == dirname or repo_with_spaces == key_lower or repo_clean == key_lower.replace(" ", "-"):
            return dirname
    return repo


# ── Ledger lookup ─────────────────────────────────────────────────────

def _find_task_in_ledger(ledger_path: str, task_id: str) -> dict | None:
    try:
        with open(ledger_path) as f:
            doc = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

    for mod in doc.get("modules", []):
        for t in mod.get("tasks", []):
            if t.get("id") == task_id or t.get("task_id") == task_id:
                t["module"] = mod.get("module", "")
                return t
    return None


# ── Task document parsing ─────────────────────────────────────────────

def _parse_task_doc(docs_dir: str, task_id: str) -> dict:
    """Parse a TASK-XXX.md file from the tasks directory."""
    tasks_dir = Path(docs_dir)
    if not tasks_dir.is_dir():
        return {}

    for f in tasks_dir.glob("*.md"):
        if task_id in f.stem:
            return _parse_md_doc(f)

    # Also check subdirectories
    for f in tasks_dir.rglob("*.md"):
        if task_id in f.stem:
            return _parse_md_doc(f)
    return {}


def _parse_md_doc(path: Path) -> dict:
    content = path.read_text()
    info = {"title": "", "description": "", "acceptance_criteria": [], "validation_commands": []}

    # Extract title from first heading
    m = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
    if m:
        info["title"] = m.group(1).strip()

    # Extract description (paragraph after title)
    m = re.search(r'^#\s+.+?\n\n(.+?)(?:\n\n|\Z)', content, re.MULTILINE | re.DOTALL)
    if m:
        info["description"] = m.group(1).strip()[:500]

    # Extract acceptance criteria from checklist
    criteria = re.findall(r'^- \[ \]\s+(.+)$', content, re.MULTILINE)
    if criteria:
        info["acceptance_criteria"] = criteria[:20]

    # Extract validation commands from code blocks
    cmds = re.findall(r'```(?:bash|sh|shell)\s*\n(.+?)```', content, re.DOTALL)
    if cmds:
        info["validation_commands"] = [c.strip() for c in cmds[0].strip().split("\n") if c.strip()]
    return info


# ── Contract scanning ─────────────────────────────────────────────────

def _scan_contracts(contracts_dir: str, task_id: str) -> list[dict]:
    """Scan contract index and return any contracts mentioning the task."""
    contracts_dir_p = Path(contracts_dir)

    # Try contract-index.md
    index_files = [
        contracts_dir_p / "contract-index.md",
        contracts_dir_p.parent / "contracts" / "contract-index.md",
    ]

    contracts = []
    for idx in index_files:
        if idx.exists():
            content = idx.read_text()
            tables = _extract_tables(content)
            for table in tables:
                for row in table.get("rows", []):
                    row_str = json.dumps(row)
                    if task_id in row_str or any(
                        keyword in row_str
                        for keyword in task_id.replace("TASK-", "").split("-")[:3]
                    ):
                        contracts.append({
                            "table_heading": table.get("heading", ""),
                            "row": row,
                        })
    if not contracts:
        # Generic: add impacted repos reference
        contracts.append({"note": "No specific contract reference found", "source": str(index_files[0]) if any(f.exists() for f in index_files) else "unknown"})
    return contracts


def _extract_tables(md: str) -> list[dict]:
    """Extract markdown tables with their preceding heading."""
    tables = []
    lines = md.split("\n")
    current_heading = ""
    in_table = False
    headers = []
    rows = []

    for i, line in enumerate(lines):
        if line.startswith("##") or line.startswith("#"):
            current_heading = line.lstrip("#").strip()
        if "|" in line and "---" not in line:
            cols = [c.strip() for c in line.split("|") if c.strip()]
            if not in_table:
                if cols:
                    headers = cols
                    in_table = True
                    rows = []
            else:
                if cols:
                    rows.append(cols)
        else:
            if in_table and rows:
                tables.append({"heading": current_heading, "headers": headers, "rows": rows})
            in_table = False
            headers = []
            rows = []

    if in_table and rows:
        tables.append({"heading": current_heading, "headers": headers, "rows": rows})
    return tables


# ── Repo-specific validation commands ─────────────────────────────────

def _get_build_commands(repo: str) -> list[str]:
    """Return standard build/test commands for a repo."""
    cmds = {
        "livemask-backend": ["go build ./...", "go test ./...", "go vet ./..."],
        "livemask-admin": ["npm run build", "npm test"],
        "livemask-website": ["npm run build"],
        "livemask-app": ["flutter build apk --debug", "flutter test"],
        "livemask-nodeagent": ["go build ./...", "go test ./...", "go vet ./..."],
        "livemask-job-service": ["go build ./...", "go test ./...", "go vet ./..."],
        "livemask-ci-cd": ["bash -n scripts/*.sh"],
        "livemask-docs": ["bash scripts/check-docs.sh"],
    }
    return cmds.get(repo, [])


# ── Command: load ─────────────────────────────────────────────────────

@traced
def cmd_load(args: list[str]) -> int:
    """context.py load <task_id> --ledger <path> --docs <dir> --contracts <dir>"""
    if not args:
        print(json.dumps({"status": "error", "message": "usage: load <task_id> --ledger <path> --docs <dir> --contracts <dir>"}))
        return 1

    task_id = args[0]
    ledger_path = ""
    docs_dir = ""
    contracts_dir = ""

    i = 1
    while i < len(args):
        if args[i] == "--ledger" and i + 1 < len(args):
            ledger_path = args[i + 1]
            i += 2
        elif args[i] == "--docs" and i + 1 < len(args):
            docs_dir = args[i + 1]
            i += 2
        elif args[i] == "--contracts" and i + 1 < len(args):
            contracts_dir = args[i + 1]
            i += 2
        else:
            i += 1

    # 1. Ledger lookup
    ledger_task = _find_task_in_ledger(ledger_path, task_id) if ledger_path else None

    # 2. Task doc
    doc_info = _parse_task_doc(docs_dir, task_id) if docs_dir else {}

    # 3. Contracts
    contracts = _scan_contracts(contracts_dir, task_id) if contracts_dir else []

    # 4. Resolve repo
    repo = ""
    if ledger_task:
        impacted = ledger_task.get("impacted_repos", ledger_task.get("module", ""))
        repo = _normalize_repo(_resolve_repo(impacted))
    elif doc_info.get("title"):
        repo = "livemask-docs"  # default for doc-based tasks

    # 5. Build context
    repo_safe = repo or os.environ.get("LIVEMASK_TARGET_REPO", "")
    validation_cmds = doc_info.get("validation_commands", [])
    if not validation_cmds:
        validation_cmds = _get_build_commands(repo_safe)
    if not validation_cmds:
        validation_cmds = ["go build ./...", "go test ./..."]  # universal fallback

    context = {
        "task_id": task_id,
        "repo": repo_safe,
        "title": ledger_task.get("title", "") if ledger_task else doc_info.get("title", ""),
        "description": ledger_task.get("description", "") if ledger_task else doc_info.get("description", ""),
        "status": ledger_task.get("status", "ready") if ledger_task else "ready",
        "acceptance_criteria": doc_info.get("acceptance_criteria", []),
        "validation_commands": validation_cmds,
        "contracts": contracts[:5],
        "module": ledger_task.get("module", "") if ledger_task else "",
        "priority": ledger_task.get("priority", 0) if ledger_task else 0,
        "source": "ledger" if ledger_task else "task-doc" if doc_info else "contracts",
    }

    print(json.dumps(context))
    return 0


# ── Entry point ───────────────────────────────────────────────────────

def main():
    _debug_setup()
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    cmd = sys.argv[1]
    rest = sys.argv[2:]

    if cmd == "load":
        return cmd_load(rest)

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
