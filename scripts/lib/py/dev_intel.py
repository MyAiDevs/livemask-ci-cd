#!/usr/bin/env python3
"""
dev_intel.py — Developer Intelligence Engine for LiveMask dev loop.

Provides five integrated capabilities for AI agents:

  1. MEMORY - Fuzzy semantic memory lookup (fast keyword matching + context recall)
     Searches across: ledger, experience, tags, knowledge_base, cache, git log
     
  2. LOG ANALYSIS - Log file triage + error diagnosis
     Searches logs, fingerprints errors, cross-references experience, suggests fixes
     
  3. SMOKE VERIFICATION - Run/parse smoke tests, validate results
     Wraps local-verify.sh, parses output, validates against expected patterns
  
  4. GIT SUMMARY - Git history intelligence
     Recent commits, branch status, conflict detection, blame summaries
  
  5. LEARNING - Technology learning companion
     Query the knowledge_base, practice patterns, diagnose tech-specific errors

Usage:
    dev_intel.py memory search <query> [--limit N] [--source ledger|experience|tags|all]
    dev_intel.py log analyze <log_file> [--context LINES]
    dev_intel.py log watch <log_pattern> [--tail N] [--interval SEC]
    dev_intel.py smoke run <repo> [--quick]
    dev_intel.py smoke validate <log_file> [--expected PATTERN]
    dev_intel.py git summary [--repo R] [--since DAYS]
    dev_intel.py git blame <file> [--repo R]
    dev_intel.py learn search <query>          # Search knowledge base
    dev_intel.py learn get <topic> [--subtopic S]  # Get knowledge entry
    dev_intel.py learn list                     # List all topics

Output: JSON to stdout.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

from debug_utils import setup as _debug_setup, traced, logger as _logger

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "cache")
LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT",
                                os.path.expanduser("~/Developer/LiveMask"))
PY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)))


def _python(script: str, *args: str) -> str:
    """Run another Python tool and return stdout."""
    script_path = os.path.join(PY_DIR, script)
    try:
        r = subprocess.run(
            [sys.executable, script_path] + list(args),
            capture_output=True, text=True, timeout=30,
        )
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return json.dumps({"error": str(e)})


def _run_git(cmd: list[str], repo: str = "") -> str:
    """Run git command and return stdout."""
    cwd = os.path.join(LIVEMASK_ROOT, repo) if repo else LIVEMASK_ROOT
    try:
        r = subprocess.run(
            ["git"] + cmd, capture_output=True, text=True, timeout=15, cwd=cwd,
        )
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return json.dumps({"error": str(e)})


# ─────────────────────────────────────────────────────────────────────
# MEMORY — Fuzzy semantic memory lookup
# ─────────────────────────────────────────────────────────────────────

def memory_search(query: str, limit: int = 10, source: str = "all") -> dict:
    """Search across multiple data sources for fuzzy recall."""
    ql = query.lower()
    results = []

    # Source 1: Business tags
    if source in ("all", "tags"):
        tag_output = _python("tags.py", "search", query, "--limit", str(limit))
        try:
            tag_data = json.loads(tag_output)
            for r in tag_data.get("results", []):
                results.append({
                    "source": "tags",
                    "id": r["item_id"],
                    "tags": r.get("tags", []),
                    "match_type": "tagged_item",
                    "relevance": _score_match(query, r["item_id"], json.dumps(r.get("tags", []))),
                })
        except (json.JSONDecodeError, KeyError):
            pass

    # Source 2: Experience / error patterns
    if source in ("all", "experience"):
        exp_output = _python("experience.py", "stats")
        try:
            exp_data = json.loads(exp_output)
            for pattern, count in exp_data.get("pattern_breakdown", {}).items():
                if ql in pattern.lower():
                    results.append({
                        "source": "experience",
                        "id": f"pattern:{pattern}",
                        "pattern": pattern,
                        "count": count,
                        "match_type": "error_pattern",
                        "relevance": _score_match(query, pattern, ""),
                    })
        except (json.JSONDecodeError, KeyError):
            pass

    # Source 3: Cache
    if source in ("all", "cache"):
        cache_output = _python("cache.py", "stats")
        try:
            cache_data = json.loads(cache_output)
            for ns in cache_data.get("namespaces", []):
                ns_name = ns.get("namespace", "")
                if ql in ns_name.lower():
                    results.append({
                        "source": "cache",
                        "id": f"ns:{ns_name}",
                        "keys": ns.get("keys", 0),
                        "size_bytes": ns.get("size_bytes", 0),
                        "match_type": "cache_namespace",
                        "relevance": 50,
                    })
        except (json.JSONDecodeError, KeyError):
            pass

    # Source 4: Knowledge base
    if source in ("all", "knowledge"):
        kb_output = _python("knowledge_base.py", "search", query)
        try:
            kb_data = json.loads(kb_output)
            for r in kb_data.get("results", []):
                results.append({
                    "source": "knowledge_base",
                    "id": r["topic"],
                    "title": r["title"],
                    "tags": r.get("tags", []),
                    "score": r.get("score", 0),
                    "match_type": "tech_knowledge",
                    "relevance": min(r.get("score", 0), 99),
                })
        except (json.JSONDecodeError, KeyError):
            pass

    # Source 5: Task predictor predictions
    if source in ("all", "predictions"):
        pred_file = os.path.join(CACHE_DIR, "task-predictions.json")
        if os.path.exists(pred_file):
            try:
                with open(pred_file) as f:
                    pred_data = json.load(f)
                for p in pred_data.get("predictions", []):
                    reason = p.get("reason", "")
                    if ql in reason.lower() or ql in p.get("tag", "").lower():
                        results.append({
                            "source": "predictions",
                            "id": f"pred:{p.get('strategy', '?')}",
                            "strategy": p.get("strategy", ""),
                            "tag": p.get("tag", ""),
                            "missing_repo": p.get("missing_repo", ""),
                            "confidence": p.get("confidence", 0),
                            "match_type": "prediction",
                            "relevance": p.get("confidence", 0),
                        })
            except (json.JSONDecodeError, OSError):
                pass

    # Source 6: Recent git commits (fuzzy search in messages)
    if source in ("all", "git"):
        commits = _run_git(["log", "--oneline", "-50", "--format=%H %s"])
        for line in commits.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.strip().split(" ", 1)
            if len(parts) == 2:
                sha, msg = parts
                if ql in msg.lower():
                    results.append({
                        "source": "git_log",
                        "id": sha[:12],
                        "message": msg,
                        "match_type": "commit_message",
                        "relevance": _score_match(query, msg, ""),
                    })

    # Deduplicate by keeping highest relevance per unique item
    seen = {}
    for r in results:
        key = f"{r['source']}:{r.get('id', '')}"
        if key not in seen or r.get("relevance", 0) > seen[key].get("relevance", 0):
            seen[key] = r

    ranked = sorted(seen.values(), key=lambda x: -x.get("relevance", 0))
    top = ranked[:limit]

    # Summary by source
    source_counts = Counter(r["source"] for r in top)

    return {
        "status": "ok",
        "query": query,
        "total_matches": len(top),
        "by_source": dict(source_counts),
        "results": top,
    }


def _score_match(query: str, text1: str, text2: str) -> int:
    """Compute a simple relevance score for a match."""
    ql = query.lower()
    score = 0
    for t in (text1, text2):
        tl = t.lower()
        # Exact phrase match
        if ql in tl:
            score += 40
        # Word match
        for w in ql.split():
            if w in tl:
                score += 15
        # Starts with match
        if tl.startswith(ql):
            score += 25
    return min(score, 99)


def cmd_memory(args: list[str]) -> int:
    """dev_intel.py memory search <query> [--limit N] [--source S]"""
    if not args or args[0] != "search":
        print(json.dumps({"error": "usage: memory search <query> [--limit N] [--source S]"}))
        return 1

    query = ""
    limit = 10
    source = "all"

    i = 1
    while i < len(args):
        if args[i] == "--limit" and i + 1 < len(args):
            try: limit = int(args[i + 1])
            except ValueError: pass
            i += 2
        elif args[i] == "--source" and i + 1 < len(args):
            source = args[i + 1]; i += 2
        elif not query:
            query = args[i]; i += 1
        else:
            i += 1

    if not query:
        print(json.dumps({"error": "query required"}))
        return 1

    result = memory_search(query, limit, source)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


# ─────────────────────────────────────────────────────────────────────
# LOG ANALYSIS — Log triage + error diagnosis
# ─────────────────────────────────────────────────────────────────────

def cmd_log_analyze(args: list[str]) -> int:
    """dev_intel.py log analyze <log_file> [--context LINES]"""
    if not args or args[0] != "analyze":
        print(json.dumps({"error": "usage: log analyze <log_file> [--context LINES]"}))
        return 1

    log_file = ""
    context_lines = 5

    i = 1
    while i < len(args):
        if args[i] == "--context" and i + 1 < len(args):
            try: context_lines = int(args[i + 1])
            except ValueError: pass
            i += 2
        elif not log_file:
            log_file = args[i]; i += 1
        else:
            i += 1

    if not log_file:
        print(json.dumps({"error": "log file path required"}))
        return 1

    if not os.path.isfile(log_file):
        print(json.dumps({"error": f"file not found: {log_file}"}))
        return 1

    with open(log_file) as f:
        content = f.read()

    lines = content.split("\n")

    # Extract errors and warnings
    errors = []
    warnings = []
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        if re.search(r'\b(ERRO[R]?|FATAL|PANIC|CRITICAL)\b', stripped, re.IGNORECASE):
            ctx_start = max(0, idx - context_lines)
            ctx_end = min(len(lines), idx + context_lines + 1)
            errors.append({
                "line": idx + 1,
                "text": stripped[:200],
                "context": [lines[i].strip() for i in range(ctx_start, ctx_end) if lines[i].strip()],
            })
        elif re.search(r'\b(WARN|WARNING|ALERT)\b', stripped, re.IGNORECASE):
            ctx_start = max(0, idx - context_lines)
            ctx_end = min(len(lines), idx + context_lines + 1)
            warnings.append({
                "line": idx + 1,
                "text": stripped[:200],
                "context": [lines[i].strip() for i in range(ctx_start, ctx_end) if lines[i].strip()],
            })

    # Check for common Go patterns
    go_panics = [e for e in errors if "panic" in e["text"].lower()]
    nil_ptr = [e for e in errors if "nil pointer" in e["text"].lower() or "nil" in e["text"].lower()]
    db_errors = [e for e in errors if "pq:" in e["text"].lower() or "sql" in e["text"].lower() or "database" in e["text"].lower()]

    # Cross-reference with experience database
    exp_output = _python("experience.py", "suggest", log_file)
    experience_suggestions = []
    try:
        exp_data = json.loads(exp_output)
        experience_suggestions = exp_data.get("suggestions", [])
    except (json.JSONDecodeError, KeyError):
        pass

    # Detect file type and common patterns
    file_ext = Path(log_file).suffix.lower()
    tech_stack = "unknown"
    if file_ext == ".go" or any("go" in l.lower() for l in content.split("\n")[:10]):
        tech_stack = "go"
    elif file_ext in (".dart", ".flutter") or any("flutter" in l.lower() for l in content.split("\n")[:10]):
        tech_stack = "flutter"
    elif file_ext in (".ts", ".tsx", ".js", ".jsx") or any("npm" in l.lower() or "next" in l.lower() for l in content.split("\n")[:10]):
        tech_stack = "nodejs"
    elif any("tun" in l.lower() or "vpn" in l.lower() or "connect" in l.lower() for l in content.split("\n")[:20]):
        tech_stack = "vpn"

    # Load relevant knowledge if available
    tech_tips = None
    if tech_stack != "unknown":
        try:
            stderr_backup = sys.stderr
            sys.stderr = open(os.devnull, 'w')
            kb_data = json.loads(_python("knowledge_base.py", "search", tech_stack))
            sys.stderr.close()
            sys.stderr = stderr_backup
            if kb_data.get("results"):
                tech_tips = kb_data["results"][0]["topic"]
        except Exception:
            pass

    result = {
        "file": log_file,
        "total_lines": len(lines),
        "errors_found": len(errors),
        "warnings_found": len(warnings),
        "summary": {
            "has_fatal": len(errors) > 0,
            "has_warnings": len(warnings) > 0,
            "has_go_panics": len(go_panics),
            "has_nil_pointers": len(nil_ptr),
            "has_db_errors": len(db_errors),
            "detected_tech_stack": tech_stack,
        },
        "errors": errors[:20],  # Cap at 20
        "warnings": warnings[:20],
        "experience_suggestions": experience_suggestions[:5],
        "tech_topic_hint": tech_tips,
    }

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def cmd_log_watch(args: list[str]) -> int:
    """dev_intel.py log watch <log_pattern> [--tail N] [--interval SEC]"""
    # This is a thin wrapper around log-watch.sh
    print(json.dumps({
        "status": "hint",
        "message": "Use log-watch.sh for real-time monitoring: bash lib/log-watch.sh watch <pattern>",
    }))
    return 0


# ─────────────────────────────────────────────────────────────────────
# SMOKE VERIFICATION
# ─────────────────────────────────────────────────────────────────────

def cmd_smoke_run(args: list[str]) -> int:
    """dev_intel.py smoke run <repo> [--quick]"""
    if not args or args[0] != "run":
        print(json.dumps({"error": "usage: smoke run <repo> [--quick]"}))
        return 1

    repo = ""
    quick = False

    i = 1
    while i < len(args):
        if args[i] == "--quick":
            quick = True; i += 1
        elif not repo:
            repo = args[i]; i += 1
        else:
            i += 1

    if not repo:
        print(json.dumps({"error": "repo name required (e.g. livemask-backend, livemask-admin)"}))
        return 1

    # Find the local-verify.sh
    verify_script = os.path.join(LIVEMASK_ROOT, "livemask-ci-cd", "scripts", "lib", "local-verify.sh")
    if not os.path.exists(verify_script):
        # Try direct repo check
        verify_script = os.path.join(LIVEMASK_ROOT, repo, "scripts", "local-verify.sh")

    repo_path = os.path.join(LIVEMASK_ROOT, repo)
    if not os.path.isdir(repo_path):
        print(json.dumps({"error": f"repo not found: {repo_path}"}))
        return 1

    # Run verification
    commands = {
        "livemask-backend": ["go build ./...", "go test ./...", "go vet ./..."],
        "livemask-nodeagent": ["go build ./...", "go test ./...", "go vet ./..."],
        "livemask-job-service": ["go build ./...", "go test ./...", "go vet ./..."],
        "livemask-admin": ["npm run build"],
        "livemask-website": ["npm run build"],
        "livemask-ci-cd": ["bash -n scripts/*.sh"],
        "livemask-docs": ["bash scripts/check-docs.sh"],
        "livemask-app": ["flutter test"],
    }

    if quick and repo in commands:
        quick_cmds = commands[repo][:1]  # Only build/first-step
    else:
        quick_cmds = commands.get(repo, ["echo 'no commands defined for this repo'"])

    results = []
    all_pass = True

    for cmd_template in quick_cmds:
        cmd = f"cd {shlex.quote(repo_path)} && {cmd_template}"
        try:
            r = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, timeout=120,
            )
            passed = r.returncode == 0
            results.append({
                "command": cmd_template,
                "passed": passed,
                "return_code": r.returncode,
                "stdout_truncated": r.stdout[:300] if r.stdout else "",
                "stderr_truncated": r.stderr[:300] if r.stderr else "",
            })
            if not passed:
                all_pass = False
        except subprocess.TimeoutExpired:
            results.append({
                "command": cmd_template,
                "passed": False,
                "error": "timeout (120s)",
            })
            all_pass = False
        except Exception as e:
            results.append({
                "command": cmd_template,
                "passed": False,
                "error": str(e),
            })
            all_pass = False

    print(json.dumps({
        "repo": repo,
        "quick": quick,
        "all_passed": all_pass,
        "results": results,
    }, indent=2, ensure_ascii=False))
    return 0 if all_pass else 1


def cmd_smoke_validate(args: list[str]) -> int:
    """dev_intel.py smoke validate <log_file> [--expected PATTERN]"""
    if not args or args[0] != "validate":
        print(json.dumps({"error": "usage: smoke validate <log_file> [--expected PATTERN]"}))
        return 1

    log_file = ""
    expected_pattern = ""

    i = 1
    while i < len(args):
        if args[i] == "--expected" and i + 1 < len(args):
            expected_pattern = args[i + 1]; i += 2
        elif not log_file:
            log_file = args[i]; i += 1
        else:
            i += 1

    if not log_file or not os.path.isfile(log_file):
        print(json.dumps({"error": "log file path required and must exist"}))
        return 1

    with open(log_file) as f:
        content = f.read()

    lines = content.split("\n")

    # Count PASS/FAIL/SKIP patterns
    pass_count = len(re.findall(r'\bPASS\b', content))
    fail_count = len(re.findall(r'\bFAIL\b', content))
    skip_count = len(re.findall(r'\bSKIP\b', content))
    error_count = len(re.findall(r'\b(ERROR|FATAL|PANIC)\b', content))

    # Check for expected pattern
    expected_found = True
    if expected_pattern:
        expected_found = bool(re.search(expected_pattern, content, re.IGNORECASE))

    # Extract failed test names
    failed_tests = []
    for line in lines:
        if re.search(r'---\s+FAIL', line) or re.search(r'\bFAIL\b', line):
            m = re.search(r'(Test\w+|FAIL\s+\S+)', line)
            if m:
                failed_tests.append(m.group(1))

    print(json.dumps({
        "file": log_file,
        "total_lines": len(lines),
        "stats": {
            "pass_count": pass_count,
            "fail_count": fail_count,
            "skip_count": skip_count,
            "error_count": error_count,
        },
        "expected_pattern_match": expected_found if expected_pattern else "not_checked",
        "failed_tests": failed_tests[:20],
        "has_failures": fail_count > 0 or error_count > 0,
    }, indent=2, ensure_ascii=False))
    return 0


# ─────────────────────────────────────────────────────────────────────
# GIT SUMMARY — Git history intelligence
# ─────────────────────────────────────────────────────────────────────

def cmd_git_summary(args: list[str]) -> int:
    """dev_intel.py git summary [--repo R] [--since DAYS]"""
    if not args or args[0] != "summary":
        print(json.dumps({"error": "usage: git summary [--repo R] [--since DAYS]"}))
        return 1

    repo = ""
    since_days = 7

    i = 1
    while i < len(args):
        if args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]; i += 2
        elif args[i] == "--since" and i + 1 < len(args):
            try: since_days = int(args[i + 1])
            except ValueError: pass
            i += 2
        else:
            i += 1

    since_arg = f"--since={since_days}.days"

    # Recent commits
    log_output = _run_git(
        ["log", since_arg, "--oneline", "--format=%H|%an|%ar|%s", "-50"],
        repo,
    )

    commits = []
    authors = Counter()
    for line in log_output.strip().split("\n"):
        if not line.strip() or "|" not in line:
            continue
        parts = line.strip().split("|", 3)
        if len(parts) == 4:
            sha, author, rel_time, msg = parts
            commits.append({
                "sha": sha[:12],
                "author": author,
                "time_ago": rel_time,
                "message": msg,
            })
            authors[author] += 1

    # Branch info
    branch = _run_git(["rev-parse", "--abbrev-ref", "HEAD"], repo).strip()
    status = _run_git(["status", "--porcelain"], repo).strip()

    dirty = len([l for l in status.split("\n") if l.strip()]) if status else 0

    # Unpushed commits
    unpushed = _run_git(["log", "@{u}..HEAD", "--oneline"], repo).strip()

    # Recent tags
    tags = _run_git(["tag", "--sort=-creatordate", "--format=%(refname:short)|%(creatordate:short)", "-5"], repo).strip()

    parse_tags = []
    for line in tags.split("\n"):
        if "|" in line:
            tname, tdate = line.strip().split("|", 1)
            parse_tags.append({"tag": tname, "date": tdate})

    print(json.dumps({
        "repo": repo or "all",
        "branch": branch,
        "dirty_files": dirty,
        "authors": dict(authors.most_common()),
        "commit_count": len(commits),
        "recent_commits": commits[:20],
        "unpushed_count": len([l for l in unpushed.split("\n") if l.strip()]) if unpushed else 0,
        "recent_tags": parse_tags,
    }, indent=2, ensure_ascii=False))
    return 0


def cmd_git_blame(args: list[str]) -> int:
    """dev_intel.py git blame <file> [--repo R]"""
    if not args or args[0] != "blame":
        print(json.dumps({"error": "usage: git blame <file> [--repo R]"}))
        return 1

    file_path = ""
    repo = ""

    i = 1
    while i < len(args):
        if args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]; i += 2
        elif not file_path:
            file_path = args[i]; i += 1
        else:
            i += 1

    if not file_path:
        print(json.dumps({"error": "file path required"}))
        return 1

    blame_output = _run_git(["blame", "--line-porcelain", file_path], repo)

    authors = Counter()
    lines = 0
    for line in blame_output.split("\n"):
        if line.startswith("author "):
            authors[line[7:]] += 1
            lines += 1

    top_authors = dict(authors.most_common(5))
    if top_authors:
        top_author = list(top_authors.keys())[0]
        top_pct = round(top_authors[top_author] / lines * 100) if lines else 0
    else:
        top_author, top_pct = "", 0

    print(json.dumps({
        "file": file_path,
        "repo": repo or "auto",
        "total_lines_blamed": lines,
        "unique_authors": len(authors),
        "top_authors": top_authors,
        "primary_author": top_author,
        "primary_author_ownership_pct": top_pct,
    }, indent=2, ensure_ascii=False))
    return 0


# ─────────────────────────────────────────────────────────────────────
# LEARNING — Technology knowledge + practice
# ─────────────────────────────────────────────────────────────────────

def cmd_learn(args: list[str]) -> int:
    """dev_intel.py learn <search|get|list> [...]"""
    if not args or args[0] not in ("search", "get", "list"):
        print(json.dumps({"error": "usage: learn <search|get|list> [...]"}))
        return 1

    sub = args[0]
    sub_args = args[1:]

    # Delegate to knowledge_base.py
    if sub == "list":
        output = _python("knowledge_base.py", "list")
    elif sub == "search":
        if not sub_args:
            print(json.dumps({"error": "usage: learn search <query>"}))
            return 1
        output = _python("knowledge_base.py", "search", *sub_args)
    elif sub == "get":
        if not sub_args:
            print(json.dumps({"error": "usage: learn get <topic> [--subtopic S]"}))
            return 1
        output = _python("knowledge_base.py", "get", *sub_args)
    else:
        print(json.dumps({"error": f"unknown learn subcommand: {sub}"}))
        return 1

    try:
        data = json.loads(output)
        print(json.dumps(data, indent=2, ensure_ascii=False))
    except json.JSONDecodeError:
        print(output)
    return 0


# ─────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────

@traced
def main():
    if len(sys.argv) < 3 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    domain = sys.argv[1]
    command = sys.argv[2]
    args = sys.argv[3:]

    dispatch = {
        "memory": {
            "search": cmd_memory,
        },
        "log": {
            "analyze": cmd_log_analyze,
            "watch": cmd_log_watch,
        },
        "smoke": {
            "run": cmd_smoke_run,
            "validate": cmd_smoke_validate,
        },
        "git": {
            "summary": cmd_git_summary,
            "blame": cmd_git_blame,
        },
        "learn": {
            "search": cmd_learn,
            "get": cmd_learn,
            "list": cmd_learn,
        },
    }

    if domain not in dispatch:
        print(json.dumps({"error": f"unknown domain: {domain}. Use: memory, log, smoke, git, learn"}), file=sys.stderr)
        return 1

    if command not in dispatch[domain]:
        print(json.dumps({"error": f"unknown {domain} command: {command}"}), file=sys.stderr)
        return 1

    try:
        rc = dispatch[domain][command](sys.argv[2:])  # Pass full subcommand array
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    _debug_setup()
    main()
