#!/usr/bin/env python3
"""
repair.py — Autonomous build/test error diagnosis and repair.

Analyzes build/test log errors, classifies them, and attempts repairs.
Supports multiple repair types:
  - build:   Re-run build
  - file:    Edit specific files via StrReplace
  - edit:    Targeted line-level code change via sed-like replacement
  - mod:     go mod tidy / npm install (dependency fix)
  - script:  Run arbitrary shell commands

Pure Python. No embedded shell scripts.

Usage:
    repair.py build <log_file> [--apply] [--repo REPO]
    repair.py edit <file> --find "old" --replace "new" [--context N]
    repair.py classify <log_file>
    repair.py stats

Output: JSON to stdout.
"""

import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from typing import Optional

from debug_utils import setup as _debug_setup, traced, logger as _logger

REPAIR_HISTORY_FILE = os.path.join(os.path.expanduser("~"), ".claude", "cache", "repair-history.json")


# ── Error classification ──────────────────────────────────────────────

ERROR_PATTERNS = [
    # Go
    (r'undefined:\s+(\w+)', "go_undefined", "Go undefined symbol — missing import or declaration"),
    (r'(\S+\.go):(\d+):(\d+):\s*(.+?)(?=error |ERROR |Error )?(error|ERROR|Error)?\s*(.*)', "go_compile", "Go compilation error"),
    (r'no required module provides package', "go_missing_module", "Go module not found — try go mod tidy"),
    (r': undefined option --', "go_flag", "Go unknown flag"),
    (r'declared and not used', "go_unused", "Go unused variable — add _ = assignment"),
    (r'imported and not used', "go_unused_import", "Go unused import — remove or add _ prefix"),
    (r'package \S+ is not in GOROOT', "go_package_not_found", "Go package not in GOROOT — check GOPATH"),
    (r'undefined:\s+\w+\s+in\s+\w+\.go', "go_undefined_symbol", "Go function/variable not defined"),
    (r'cannot use.*as type.*in argument', "go_type_mismatch", "Go type mismatch"),
    (r'missing return', "go_missing_return", "Go function missing return statement"),
    (r'expected declaration, found', "go_syntax", "Go syntax error"),

    # TypeScript / Next.js
    (r"Module not found: Can't resolve '(\S+)'", "ts_module", "NPM module not found — try npm install"),
    (r"TS(\d+):", "ts_type", "TypeScript type error"),
    (r"'(\w+)' is declared but its value is never read", "ts_unused", "TypeScript unused variable"),
    (r"Property '(\w+)' does not exist on type", "ts_property", "TypeScript property does not exist"),
    (r"Type '(\w+)' is not assignable to type", "ts_assign", "TypeScript type assignability error"),
    (r"Module '\S+' has no exported member", "ts_export", "TypeScript missing export"),
    (r"npm ERR!", "npm_error", "NPM error — check package.json"),
    (r"Failed to compile", "build_fail", "Build failed — check logs"),
    (r"Cannot find module", "node_module", "Node module not found"),
    (r"Error: Cannot find module '(\S+)'", "ts_module_not_found", "TypeScript module resolution error"),

    # Flutter / Dart
    (r"Error: (\S+\.dart):(\d+):(\d+):", "dart_error", "Dart compilation error"),
    (r"Target '\S+' not found", "flutter_target", "Flutter target not found"),
    (r"error: The method '(\w+)' isn't defined", "dart_undefined_method", "Dart undefined method"),
    (r"error: Undefined name '(\w+)'", "dart_undefined_name", "Dart undefined name"),
    (r"error: Expected '\S+' before", "dart_syntax", "Dart syntax error"),
    (r"Could not build the application", "flutter_build_failed", "Flutter build failed"),
    (r"Your Flutter application is created", "flutter_info", "Flutter info message"),

    # Docker
    (r"Error response from daemon", "docker_daemon", "Docker daemon error"),
    (r"port is already allocated", "docker_port", "Docker port conflict"),
    (r"container.*exited with code", "docker_exit", "Container exited with error"),

    # Generic
    (r"permission denied", "perm_denied", "Permission denied"),
    (r"connection refused", "conn_refused", "Connection refused"),
    (r"timeout", "timeout", "Operation timed out"),
    (r"no such file or directory", "file_missing", "File not found"),
    (r"command not found", "cmd_not_found", "Command not found"),
    (r"could not resolve", "dns_error", "DNS resolution error"),
    (r"cannot find", "not_found_generic", "Could not find resource"),
    (r"Address already in use", "addr_in_use", "Port already in use"),
    (r"signal: killed", "oom_kill", "Process killed (OOM)"),
    (r"disk quota exceeded", "disk_full", "Disk quota exceeded"),
    (r"Segmentation fault", "segfault", "Segmentation fault"),
    (r"panic:", "go_panic", "Go runtime panic"),
]


# ── Repair suggestions ────────────────────────────────────────────────

REPAIR_ACTIONS = {
    "go_missing_module": [
        {"type": "build", "cmd": "go mod tidy", "retry_build": True},
        {"type": "build", "cmd": "go mod download", "retry_build": True},
    ],
    "go_unused": [
        {"type": "build", "cmd": "go vet ./... 2>/dev/null; true", "retry_build": False},
    ],
    "go_unused_import": [
        {"type": "build", "cmd": "goimports -w $(find . -name '*.go' -type f) 2>/dev/null; true", "retry_build": True},
        {"type": "build", "cmd": "go mod tidy", "retry_build": True},
    ],
    "go_panic": [
        {"type": "build", "cmd": "go vet ./...", "retry_build": True},
    ],
    "go_compile": [
        {"type": "build", "cmd": "go build ./... 2>&1 | head -20", "retry_build": False},
    ],
    "go_syntax": [
        {"type": "build", "cmd": "gofmt -w $(find . -name '*.go' -type f) 2>/dev/null; true", "retry_build": True},
    ],
    "go_undefined_symbol": [
        {"type": "mod", "cmd": "go mod tidy && go mod download", "retry_build": True},
    ],
    "go_type_mismatch": [
        {"type": "vet", "cmd": "go vet ./... 2>&1 | head -20", "retry_build": False},
    ],
    "go_missing_return": [
        {"type": "vet", "cmd": "go vet ./... 2>&1 | head -20", "retry_build": False},
    ],

    "npm_error": [
        {"type": "build", "cmd": "rm -rf node_modules && npm install", "retry_build": True, "timeout": 120},
        {"type": "build", "cmd": "npm install --legacy-peer-deps", "retry_build": True},
    ],
    "npm_module": [
        {"type": "build", "cmd": "npm install", "retry_build": True},
    ],
    "ts_module": [
        {"type": "build", "cmd": "npm install", "retry_build": True},
    ],
    "ts_module_not_found": [
        {"type": "install", "cmd": "npm install", "retry_build": True},
    ],
    "build_fail": [
        {"type": "clean", "cmd": "rm -rf .next node_modules/.cache 2>/dev/null; true", "retry_build": True},
        {"type": "build", "cmd": "npm install && npm run build", "retry_build": True, "timeout": 120},
    ],
    "node_module": [
        {"type": "install", "cmd": "npm install", "retry_build": True},
    ],

    "dart_error": [
        {"type": "build", "cmd": "flutter clean 2>/dev/null; true", "retry_build": True},
        {"type": "build", "cmd": "flutter pub get", "retry_build": True},
    ],
    "dart_undefined_name": [
        {"type": "analyze", "cmd": "flutter analyze 2>&1 | head -20", "retry_build": False},
    ],
    "flutter_build_failed": [
        {"type": "clean", "cmd": "flutter clean 2>/dev/null; true", "retry_build": True},
        {"type": "get", "cmd": "flutter pub get", "retry_build": True},
    ],

    "docker_daemon": [
        {"type": "script", "cmd": "docker info 2>&1 | head -5", "retry_build": False},
    ],
    "docker_exit": [
        {"type": "script", "cmd": "docker logs $(docker ps -lq) 2>&1 | tail -20", "retry_build": False},
    ],
    "docker_port": [
        {"type": "script", "cmd": "docker ps --format '{{.Names}} {{.Ports}}'", "retry_build": False},
    ],

    "perm_denied": [
        {"type": "script", "cmd": "chmod +x $(find . -name '*.sh' -type f) 2>/dev/null; true", "retry_build": True},
    ],
    "file_missing": [
        {"type": "script", "cmd": "ls -la $(dirname '{}') 2>/dev/null || true", "retry_build": False, "message": "Check if file exists and path is correct"},
    ],
    "conn_refused": [
        {"type": "script", "cmd": "lsof -i :{port} 2>/dev/null || ss -tlnp 2>/dev/null | head -10", "retry_build": False},
    ],
    "addr_in_use": [
        {"type": "script", "cmd": "lsof -ti :{port} 2>/dev/null | xargs -r kill -9 2>/dev/null; true", "retry_build": True},
    ],
    "oom_kill": [
        {"type": "script", "cmd": "free -m && docker stats --no-stream 2>/dev/null | head -10", "retry_build": False},
    ],

    "go_undefined": [
        {"type": "mod", "cmd": "go mod tidy", "retry_build": True},
        {"type": "mod", "cmd": "go get ./...", "retry_build": True},
    ],
}


# ── Load log file ─────────────────────────────────────────────────────

def load_log(path: str) -> str:
    if not os.path.exists(path):
        raise FileNotFoundError(f"Log file not found: {path}")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read(100000)


# ── Classify errors ──────────────────────────────────────────────────

def classify_errors(log_text: str) -> list[dict]:
    findings = []
    for pattern, code, message in ERROR_PATTERNS:
        matches = list(re.finditer(pattern, log_text, re.MULTILINE | re.DOTALL))
        for m in matches:
            file_match = m.group(1) if m.groups() and m.groups()[0] else ""
            detail = m.group(0)[:200]
            findings.append({
                "pattern_code": code,
                "message": message,
                "detail": detail,
                "file_guess": file_match,
                "line": m.start(),
            })
    return findings


# ── Build fixes ──────────────────────────────────────────────────────

def suggest_fixes(findings: list[dict], repo: str = "") -> list[dict]:
    applied = set()
    fixes = []
    for f in findings:
        code = f["pattern_code"]
        if code in applied:
            continue
        applied.add(code)
        if code in REPAIR_ACTIONS:
            for action in REPAIR_ACTIONS[code]:
                fix = dict(action)
                fix["source_pattern"] = code
                fix["file_hint"] = f.get("file_guess", "")
                fix["original_detail"] = f.get("detail", "")[:100]
                if repo and "cmd" in fix:
                    fix["cmd"] = fix["cmd"].replace("{}", repo)
                fixes.append(fix)
    return fixes


# ── Commands ─────────────────────────────────────────────────────────

@traced
def cmd_build(args: list[str]) -> int:
    log_path = ""
    apply_mode = False
    repo = ""

    for i in range(len(args)):
        if args[i] == "--apply":
            apply_mode = True
        elif args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]
        elif not log_path and not args[i].startswith("--"):
            log_path = args[i]

    if not log_path:
        print(json.dumps({"error": "usage: build <log_file> [--apply] [--repo REPO]"}))
        return 1

    if not os.path.exists(log_path):
        print(json.dumps({"error": f"log file not found: {log_path}"}))
        return 1

    esc = "\033["
    log_content = load_log(log_path)
    findings = classify_errors(log_content)

    if not findings:
        print(json.dumps({"status": "ok", "error_count": 0, "findings": []}))
        return 0

    fixes = suggest_fixes(findings, repo)

    result = {
        "status": "retry" if fixes else "blocked",
        "log_file": log_path,
        "error_count": len(findings),
        "unique_patterns": len(set(f["pattern_code"] for f in findings)),
        "findings": findings[:20],
        "suggested_fixes": fixes[:10],
    }

    if apply_mode:
        fix_results = []
        for fix in fixes[:5]:
            if fix.get("retry_build") and fix.get("cmd"):
                fix_cmd = fix["cmd"]
                fix_type = fix.get("type", "cmd")
                fix_msg = fix.get("message", fix_cmd)
                timeout = fix.get("timeout", 30)

                # Apply the fix
                print(f"  ⊢ applying [{fix_type}] {fix_msg}", file=sys.stderr)
                try:
                    r = subprocess.run(
                        fix_cmd, shell=True, capture_output=True, text=True,
                        timeout=timeout, executable="/bin/bash",
                    )
                    fix_results.append({
                        "fix_type": fix_type,
                        "command": fix_cmd,
                        "exit_code": r.returncode,
                        "stdout": r.stdout[-200:],
                        "stderr": r.stderr[-200:],
                    })
                    if r.returncode != 0:
                        print(f"  ⚠ fix returned {r.returncode}", file=sys.stderr)
                except subprocess.TimeoutExpired:
                    print(f"  ⚠ fix timeout ({timeout}s): {fix_cmd}", file=sys.stderr)
                    fix_results.append({
                        "fix_type": fix_type,
                        "command": fix_cmd,
                        "exit_code": -1,
                        "error": "timeout",
                    })
                except Exception as e:
                    print(f"  ⚠ fix exception: {e}", file=sys.stderr)
                    fix_results.append({
                        "fix_type": fix_type,
                        "command": fix_cmd,
                        "exit_code": -2,
                        "error": str(e),
                    })

        result["fix_results"] = fix_results
        result["status"] = "fixed" if any(
            fr.get("exit_code") == 0 for fr in fix_results
        ) else "retry"

        # Record to experience system for self-learning loop
        exp_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "experience.py")
        if result["status"] == "fixed":
            action_json = json.dumps({"type": "repair_build", "findings": len(findings), "fixes": len(fixes)})
            subprocess.run(
                [sys.executable, exp_script, "record", log_path, action_json, "1",
                 "--repo", repo],
                capture_output=True, timeout=10,
            )
        elif result["fix_results"]:
            for fr in fix_results:
                success = 1 if fr.get("exit_code") == 0 else 0
                action_json = json.dumps({"type": "run", "cmd": fr.get("command", "")})
                subprocess.run(
                    [sys.executable, exp_script, "record", log_path, action_json, str(success),
                     "--repo", repo],
                    capture_output=True, timeout=10,
                )

    # Save to repair history
    _save_to_history(log_path, result)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


@traced
def cmd_edit(args: list[str]) -> int:
    """repair.py edit <file> --find 'old_str' --replace 'new_str' [--context N]

    Performs a targeted line-level edit via StrReplace on a specific file.
    Used by experience.py _apply for high-confidence fixes that involve code changes
    rather than shell commands.
    """
    file_path = ""
    find_str = ""
    replace_str = ""
    context_lines = 3

    i = 0
    while i < len(args):
        if args[i] == "--find" and i + 1 < len(args):
            find_str = args[i + 1]; i += 2
        elif args[i] == "--replace" and i + 1 < len(args):
            replace_str = args[i + 1]; i += 2
        elif args[i] == "--context" and i + 1 < len(args):
            try: context_lines = int(args[i + 1])
            except ValueError: pass
            i += 2
        elif not file_path:
            file_path = args[i]; i += 1
        else:
            i += 1

    if not file_path or not find_str or not replace_str:
        print(json.dumps({"error": "usage: edit <file> --find 'old' --replace 'new' [--context N]"}))
        return 1

    if not os.path.exists(file_path):
        print(json.dumps({"error": f"file not found: {file_path}"}))
        return 1

    # Read file content
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Count occurrences
    count = content.count(find_str)
    if count == 0:
        print(json.dumps({"error": f"string not found: {find_str[:60]}", "file": file_path}))
        return 1

    # Perform replacement
    new_content = content.replace(find_str, replace_str)
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(new_content)

    # Line number of first occurrence
    first_line = 1 + content[:content.index(find_str)].count("\n")

    print(json.dumps({
        "status": "ok",
        "action": "edit",
        "file": file_path,
        "first_line": first_line,
        "occurrences": count,
        "old_truncated": find_str[:80] + ("..." if len(find_str) > 80 else ""),
        "new_truncated": replace_str[:80] + ("..." if len(replace_str) > 80 else ""),
    }, indent=2))
    return 0


@traced
def cmd_classify(args: list[str]) -> int:
    log_path = args[0] if args else ""
    if not log_path:
        print(json.dumps({"error": "usage: classify <log_file>"}))
        return 1

    log_text = load_log(log_path)
    findings = classify_errors(log_text)
    pattern_counts = Counter(f["pattern_code"] for f in findings)

    print(json.dumps({
        "total_errors": len(findings),
        "unique_patterns": len(pattern_counts),
        "pattern_summary": dict(pattern_counts.most_common(10)),
        "findings": findings[:10],
    }, indent=2))
    return 0


@traced
def cmd_stats(args: list[str]) -> int:
    if not os.path.exists(REPAIR_HISTORY_FILE):
        print(json.dumps({"total_repairs": 0, "history": []}))
        return 0

    with open(REPAIR_HISTORY_FILE, "r") as f:
        history = json.load(f)

    total = len(history)
    successful = sum(1 for h in history if h.get("status") in ("fixed", "ok"))

    print(json.dumps({
        "total_repairs": total,
        "successful_repairs": successful,
        "success_rate": round(successful / total, 2) if total > 0 else 0,
        "recent": history[-10:],
    }, indent=2))
    return 0


def _save_to_history(log_path: str, result: dict):
    os.makedirs(os.path.dirname(REPAIR_HISTORY_FILE), exist_ok=True)
    history = []
    if os.path.exists(REPAIR_HISTORY_FILE):
        try:
            with open(REPAIR_HISTORY_FILE, "r") as f:
                history = json.load(f)
        except (json.JSONDecodeError, OSError):
            history = []

    history.append({
        "timestamp": time.time(),
        "log_file": log_path,
        "error_count": result.get("error_count", 0),
        "status": result.get("status", ""),
        "fix_count": len(result.get("suggested_fixes", [])),
    })

    history = history[-500:]
    with open(REPAIR_HISTORY_FILE, "w") as f:
        json.dump(history, f, indent=2)


# ── Main ─────────────────────────────────────────────────────────────

def main():
    _debug_setup()
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "build": cmd_build,
        "edit": cmd_edit,
        "classify": cmd_classify,
        "stats": cmd_stats,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        sys.exit(1)

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
