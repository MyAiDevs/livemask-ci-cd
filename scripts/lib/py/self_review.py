#!/usr/bin/env python3
"""
self_review.py — Self-review checker for the Claude dev loop.

Reads the task context file (produced by context.py) and applies a set
of heuristics to produce a review verdict.

Usage:
    self_review.py check <context_file>

Output (JSON on stdout):
    {"verdict":"pass|changes|blocked", "details":[...], "recommendations":[...]}
"""

import json
import os
import re
import sys
from pathlib import Path

from debug_utils import setup as _debug_setup, traced, logger as _logger


# ── Review rules ──────────────────────────────────────────────────────

def _check_acceptance_criteria(context: dict) -> list[str]:
    """Check that acceptance criteria are present."""
    issues = []
    criteria = context.get("acceptance_criteria", [])
    if not criteria:
        issues.append("no acceptance criteria defined")
    elif len(criteria) < 2:
        issues.append(f"only {len(criteria)} acceptance criterion — consider adding more")
    return issues


def _check_validation_commands(context: dict) -> list[str]:
    """Check that validation commands are present and reasonable."""
    issues = []
    cmds = context.get("validation_commands", [])
    if not cmds:
        issues.append("no validation commands defined")
    else:
        # Check for repo-native tools
        all_cmds = " ".join(cmds)
        if "build" not in all_cmds and "test" not in all_cmds and "run" not in all_cmds:
            issues.append("validation commands may not include build/test (verify repo-native tools)")
    return issues


def _check_title(context: dict) -> list[str]:
    """Check that the task has a meaningful title."""
    issues = []
    title = context.get("title", "")
    if not title:
        issues.append("no task title")
    elif len(title) < 10:
        issues.append(f"task title is very short ({len(title)} chars)")
    return issues


def _check_repo_assignment(context: dict) -> list[str]:
    """Warn if no repo is assigned."""
    issues = []
    repo = context.get("repo", "")
    if not repo:
        issues.append("no repo assigned to task")
    return issues


def _check_status(context: dict) -> list[str]:
    """Flag if task is in a blocked/completed state."""
    issues = []
    status = context.get("status", "").lower()
    valid_statuses = {"ready", "dispatched", "in_progress", "implementing", "verifying"}
    if status not in valid_statuses and status:
        issues.append(f"task status is '{status}' — may block implementation")
    elif not status:
        issues.append("no task status defined")
    return issues


# ── Command: check ────────────────────────────────────────────────────

def cmd_check(args: list[str]) -> int:
    """self_review.py check <context_file>"""
    if not args:
        print(json.dumps({"verdict": "blocked", "details": ["usage: check <context_file>"], "recommendations": []}))
        return 1

    context_file = args[0]

    if not os.path.isfile(context_file):
        print(json.dumps({
            "verdict": "blocked",
            "details": [f"context file not found: {context_file}"],
            "recommendations": ["run context.py load first"],
        }))
        return 0

    try:
        with open(context_file) as f:
            context = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(json.dumps({
            "verdict": "blocked",
            "details": [f"cannot parse context file: {e}"],
            "recommendations": ["re-run context.py load"],
        }))
        return 0

    all_issues = []
    all_issues.extend(_check_acceptance_criteria(context))
    all_issues.extend(_check_validation_commands(context))
    all_issues.extend(_check_title(context))
    all_issues.extend(_check_repo_assignment(context))
    all_issues.extend(_check_status(context))

    recommendations = []
    for issue in all_issues[:5]:
        if "criteria" in issue:
            recommendations.append("review acceptance criteria in task document")
        elif "validation" in issue or "build" in issue:
            recommendations.append("add validation commands to task document")
        elif "title" in issue:
            recommendations.append("add a descriptive title to the task document")
        elif "repo" in issue:
            recommendations.append("specify impacted repos in the task definition")
        elif "status" in issue:
            recommendations.append("check task status — may be blocked/completed")

    # Deduplicate recommendations
    recommendations = list(dict.fromkeys(recommendations))

    if not all_issues:
        verdict = "pass"
        details = ["all checks passed"]
    elif len([i for i in all_issues if "command" in i or "build" in i or "validation" in i]) > 1:
        verdict = "blocked"
        details = all_issues
        recommendations.append("run context.py load with --contracts to ensure validation commands")
    else:
        verdict = "changes"
        details = all_issues

    out = {
        "verdict": verdict,
        "details": details,
        "recommendations": recommendations,
    }
    print(json.dumps(out, indent=2))
    return 0


@traced
def main():
    _debug_setup()
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    cmd = sys.argv[1]
    rest = sys.argv[2:]

    if cmd == "check":
        return cmd_check(rest)

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
