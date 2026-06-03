#!/usr/bin/env python3
"""
doc_parser.py — Fast, structured parser for LiveMask docs.

Key capabilities:
  - orjson-backed JSON loading (3-5x faster than stdlib)
  - diskcache-backed ledger lookup (no full-file re-parse on repeated access)
  - Robust markdown table parser (regex-based, handles pipes inside code cells,
    alignment rows, optional leading/trailing pipes)

Usage:
    from doc_parser import parse_md_tables, fast_json_load, ledger_lookup, ledger_refresh

    # Parse markdown tables
    tables = parse_md_tables("doc.md")
    
    # Fast JSON
    data = fast_json_load("ledger.json")
    
    # Cached task lookup
    task = ledger_lookup("TASK-XXX", "ledger.json")
    
    # Refresh cache
    ledger_refresh("ledger.json")
"""

import json
import os
import re
import sys
import time
from typing import Any, Optional


# ── Fast JSON via orjson ───────────────────────────────────────────────

_ORJSON = False
try:
    import orjson
    _ORJSON = True
except ImportError:
    pass


def fast_json_load(path: str) -> Any:
    """Load JSON via orjson (binary, 3-5x faster) with stdlib fallback."""
    if not os.path.exists(path):
        raise FileNotFoundError(f"JSON not found: {path}")
    with open(path, "rb") as f:
        raw = f.read()
    if _ORJSON:
        return orjson.loads(raw)
    return json.loads(raw)


def fast_json_dumps(data: Any, indent: int = 2) -> str:
    """Fast JSON serialization."""
    if _ORJSON:
        raw = orjson.dumps(data, option=orjson.OPT_INDENT_2 | orjson.OPT_SORT_KEYS)
        return raw.decode("utf-8")
    return json.dumps(data, indent=indent, ensure_ascii=False)


def fast_json_dump(data: Any, path: str, indent: int = 2):
    """Fast JSON write to file."""
    content = fast_json_dumps(data, indent)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


# ── Robust Markdown Table Parser ────────────────────────────────────────
# Regex-based, handles:
#   - Leading/trailing | optional
#   - Alignment separator rows (| --- | :--- | :---: | ---: |)
#   - Inline codes with pipe characters (`|` inside ``)
#   - Multi-line content within cells

_TABLE_ROW_RE = re.compile(
    r'^\s*\|?'                     # optional leading pipe
    r'((?:[^|`]|`[^`]*`)*\|)*'    # cells: non-pipe or backtick-quoted, pipe-separated
    r'(?:[^|`]|`[^`]*`)*'         # last cell
    r'\|?\s*$'                     # optional trailing pipe
)

_CELL_SPLIT_RE = re.compile(r'\|')
_ALIGN_RE = re.compile(r'^:?-+:?$')
_BACKTICK_RE = re.compile(r'`[^`]*`')
_CODEBLOCK_RE = re.compile(r'```[\s\S]*?```')


def parse_md_tables(filepath: str) -> list[dict]:
    """Parse markdown tables into structured data.

    Returns:
        [{
            "headers": [str, ...],
            "rows": [{col_name: value, ...}, ...],
        }, ...]
    """
    if not os.path.exists(filepath):
        return []

    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    return _parse_tables_str(content)


def _parse_tables_str(content: str) -> list[dict]:
    """Core table parser from raw markdown string."""
    # Remove code blocks first to avoid false positives
    code_blocks = []
    def _save_cb(m):
        code_blocks.append(m.group(0))
        return f"__CODEBLOCK_{len(code_blocks)-1}__"
    
    cleaned = _CODEBLOCK_RE.sub(_save_cb, content)
    lines = cleaned.split("\n")
    
    tables = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        # Detect table start: a line with at least one pipe
        if line.count("|") >= 1 and not line.startswith("```"):
            # Check next line is an alignment row
            if i + 1 < len(lines):
                next_line = lines[i + 1].strip()
                # Alignment row: only |, -, :, whitespace
                align_raw = next_line.replace("|", "").replace("-", "").replace(":", "").replace(" ", "")
                if align_raw == "" and "-" in next_line:
                    # This is a table
                    header_row = _split_table_row(line)
                    align_row = _split_table_row(next_line)
                    
                    rows = []
                    j = i + 2
                    while j < len(lines):
                        rl = lines[j].strip()
                        if rl == "" or rl.startswith("```") or rl.count("|") < 1:
                            break
                        cells = _split_table_row(rl)
                        # Pad or truncate cells to match header count
                        while len(cells) < len(header_row):
                            cells.append("")
                        row_dict = {}
                        for ci, cell_val in enumerate(cells):
                            col_name = header_row[ci].strip() if ci < len(header_row) else f"col_{ci}"
                            row_dict[col_name] = cell_val.strip()
                        rows.append(row_dict)
                        j += 1
                    
                    if rows:
                        tables.append({
                            "headers": [h.strip() for h in header_row],
                            "rows": rows,
                        })
                    
                    i = j
                    continue
        i += 1
    
    # Restore code blocks (not strictly needed since we only use table structure)
    return tables


def _split_table_row(line: str) -> list[str]:
    """Split a markdown table row into cells, respecting backtick-quoted pipes."""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    
    # Replace backtick-quoted pipes with placeholders
    placeholders = []
    def _save_pipe(m):
        placeholders.append(m.group(0))
        return f"__PIPE_{len(placeholders)-1}__"
    
    escaped = _BACKTICK_RE.sub(_save_pipe, s)
    
    # Split on remaining pipes
    raw_cells = _CELL_SPLIT_RE.split(escaped)
    
    # Restore placeholders
    result = []
    for cell in raw_cells:
        for pi, ph in enumerate(placeholders):
            cell = cell.replace(f"__PIPE_{pi}__", ph)
        result.append(cell.strip())
    
    return result


# ── Contract table parsing ──────────────────────────────────────────────

def parse_contract_index(filepath: str) -> list[dict]:
    """Parse contract-index.md into structured contract list."""
    tables = parse_md_tables(filepath)
    contracts = []

    for table in tables:
        headers = table["headers"]
        if "Contract" not in headers:
            continue

        for row in table["rows"]:
            contract = {}
            for col_name, key in [
                ("Domain", "domain"),
                ("Contract", "name"),
                ("Status", "status"),
                ("Task ID", "task_id"),
                ("Primary Task", "task_id"),
                ("Impacted Repos", "repos"),
            ]:
                if col_name in headers and col_name in row:
                    contract[key] = row[col_name]

            raw_tid = contract.get("task_id", "")
            raw_name = contract.get("name", "")
            m = re.search(r'`([^`]+)`', raw_tid)
            if m:
                contract["contract_id"] = m.group(1)
            elif raw_tid:
                contract["contract_id"] = raw_tid.strip()
            else:
                contract["contract_id"] = raw_name

            raw_repos = contract.get("repos", "")
            if isinstance(raw_repos, str):
                contract["repos"] = [r.strip() for r in raw_repos.split("/") if r.strip()]
            elif isinstance(raw_repos, list):
                contract["repos"] = raw_repos
            else:
                contract["repos"] = []

            contracts.append(contract)

    return contracts


# ── MVP Plan table parsing ──────────────────────────────────────────────

def parse_mvp_tables(filepath: str) -> list[dict]:
    """Parse MVP_IMPLEMENTATION_PLAN.md tables into structured entries."""
    tables = parse_md_tables(filepath)
    entries = []

    for table in tables:
        headers = table["headers"]
        has_task = "Task ID" in headers or "task_id" in headers or "TASK" in headers
        has_status = "Status" in headers or "status" in headers or "状态" in headers
        if not has_task or not has_status:
            continue

        for row in table["rows"]:
            entry = {}
            for col_name, key in [
                ("Domain", "domain"),
                ("Task ID", "task_id"),
                ("TASK", "task_id"),
                ("Status", "status"),
                ("状态", "status"),
                ("Contract", "contract"),
                ("Priority", "priority"),
                ("Repo", "repo"),
                ("Repository", "repo"),
                ("Notes", "notes"),
            ]:
                if col_name in headers and col_name in row:
                    entry[key] = row[col_name]

            raw_tid = entry.get("task_id", "")
            m = re.search(r'`([^`]+)`', raw_tid)
            if m:
                entry["task_id"] = m.group(1)
            elif raw_tid:
                entry["task_id"] = raw_tid.strip()

            if not entry.get("task_id"):
                continue
            entries.append(entry)

    return entries


# ── Cached Ledger Lookup ────────────────────────────────────────────────

_CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "cache")


def _open_cache(ns: str = "ledger-lookup"):
    """Open diskcache namespace."""
    from diskcache import Cache
    os.makedirs(_CACHE_DIR, exist_ok=True)
    return Cache(os.path.join(_CACHE_DIR, ns))


def ledger_refresh(ledger_path: str) -> dict:
    """Full refresh: parse ledger JSON once, cache all tasks individually."""
    data = fast_json_load(ledger_path)
    stats = {"modules": 0, "tasks": 0}

    with _open_cache() as cache:
        cache.set("_full_data", data, expire=3600)
        for module in data.get("modules", []):
            mid = module.get("module_id", "unknown")
            stats["modules"] += 1
            for task in module.get("tasks", []):
                tid = task.get("task_id", "")
                if tid:
                    cache.set(f"task:{tid}", task, expire=3600)
                    stats["tasks"] += 1

        # Module index
        module_index = {}
        for module in data.get("modules", []):
            mid = module.get("module_id", "unknown")
            module_index[mid] = [
                t.get("task_id", "")
                for t in module.get("tasks", []) if t.get("task_id")
            ]
        cache.set("_module_index", module_index, expire=3600)

    return stats


def ledger_lookup(task_id: str, ledger_path: Optional[str] = None) -> Optional[dict]:
    """Fast task lookup via diskcache."""
    with _open_cache() as cache:
        task = cache.get(f"task:{task_id}")
        if task is not None:
            return task

    if ledger_path and os.path.exists(ledger_path):
        try:
            data = fast_json_load(ledger_path)
            for module in data.get("modules", []):
                for task in module.get("tasks", []):
                    if task.get("task_id") == task_id:
                        with _open_cache() as c:
                            c.set(f"task:{task_id}", task, expire=3600)
                        return task
        except Exception:
            pass

    return None


def ledger_query(ledger_path: str) -> dict:
    """Get cached ledger data, refresh on miss."""
    with _open_cache() as cache:
        full = cache.get("_full_data")
        if full is not None:
            return full
    return fast_json_load(ledger_path)


# ── CLI ─────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        print("Usage: doc_parser.py <parse-md|parse-contracts|parse-mvp|parse-json|ledger-lookup|ledger-refresh> <path> [args...]")
        sys.exit(1)

    cmd = sys.argv[1]
    path = sys.argv[2]

    try:
        if cmd == "parse-md":
            tables = parse_md_tables(path)
            print(json.dumps({
                "table_count": len(tables),
                "total_rows": sum(len(t["rows"]) for t in tables),
            }, indent=2))

        elif cmd == "parse-mvp":
            entries = parse_mvp_tables(path)
            print(json.dumps({"entry_count": len(entries)}, indent=2))

        elif cmd == "parse-contracts":
            contracts = parse_contract_index(path)
            print(json.dumps({"contract_count": len(contracts), "contracts": contracts}, indent=2, ensure_ascii=False))

        elif cmd == "parse-json":
            data = fast_json_load(path)
            print(json.dumps({"status": "ok", "size_bytes": os.path.getsize(path), "type": type(data).__name__}))

        elif cmd == "ledger-lookup":
            task_id = sys.argv[3] if len(sys.argv) > 3 else ""
            task = ledger_lookup(task_id, path)
            print(json.dumps({"found": task is not None}))

        elif cmd == "ledger-refresh":
            stats = ledger_refresh(path)
            print(json.dumps({"status": "ok", "cached": stats}, indent=2))

        else:
            print(json.dumps({"error": f"unknown cmd: {cmd}"}))
            sys.exit(1)

    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
