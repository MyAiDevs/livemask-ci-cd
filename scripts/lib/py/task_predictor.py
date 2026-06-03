#!/usr/bin/env python3
"""
task_predictor.py — Task prophecy engine for LiveMask dev loop.

Analyzes the task graph, tag registry, contract index, and MVP plan to
PREDICT tasks that are implied but don't yet exist.  This enables the
system to proactively discover work before it's explicitly documented.

Prediction strategies:
  1. cross_repo_gap   — Domain tag spans repos A+B+C; A+B have tasks but C doesn't
  2. unlock_chain     — Task A 'unlocks' Task B; A is completed but B doesn't exist
  3. tag_pattern      — Common tag combos imply unplanned scope (e.g. auth+api+backend)
  4. domain_expansion — Repo X has N tasks in domain D; cross-repo partner repo doesn't
  5. phase_gap        — MVP shows future phase tasks that have no TASK-XXX doc or ledger entry

Usage:
    task_predictor.py predict --ledger PATH --contracts PATH [--mvp PATH] [--tags PATH]
    task_predictor.py predict --all
    task_predictor.py suggest-for <task_id>  # What should come after this task?
    task_predictor.py stats                  # Prediction confidence stats

Output: JSON to stdout.
"""

import json
import os
import re
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone

from debug_utils import setup as _debug_setup, traced, logger as _logger

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "cache")
PREDICTION_FILE = os.path.join(CACHE_DIR, "task-predictions.json")
LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT",
                                os.path.expanduser("~/Developer/LiveMask"))

# ── Well-known cross-repo domain mappings ───────────────────────────
# These define which repos should have tasks for which domain tags.
# Based on CROSS_REPO_TAGS in tags.py

DOMAIN_REPO_MAP: dict[str, list[str]] = {
    "domain:auth":     ["livemask-backend", "livemask-admin", "livemask-app", "livemask-website"],
    "domain:billing":  ["livemask-backend", "livemask-admin", "livemask-website"],
    "domain:vpn":      ["livemask-backend", "livemask-nodeagent", "livemask-app"],
    "domain:node":     ["livemask-backend", "livemask-nodeagent", "livemask-admin"],
    "domain:admin":    ["livemask-backend", "livemask-admin"],
    "domain:app":      ["livemask-backend", "livemask-app"],
    "domain:content":  ["livemask-backend", "livemask-admin", "livemask-app", "livemask-website"],
    "domain:geoip":    ["livemask-backend", "livemask-nodeagent", "livemask-admin"],
    "domain:user":     ["livemask-backend", "livemask-admin", "livemask-app"],
    "domain:notification": ["livemask-backend", "livemask-job-service"],
    "domain:marketplace":  ["livemask-backend", "livemask-admin", "livemask-website", "livemask-app"],
    "domain:growth":       ["livemask-backend", "livemask-admin", "livemask-website"],
    "domain:revenue":      ["livemask-backend", "livemask-admin"],
    "domain:i18n":    ["livemask-backend", "livemask-admin", "livemask-app", "livemask-website"],
    "domain:protocol":     ["livemask-backend", "livemask-nodeagent", "livemask-app"],
    "domain:security":     ["livemask-backend", "livemask-nodeagent", "livemask-admin"],
    "domain:observability": ["livemask-backend", "livemask-job-service", "livemask-admin"],
    "domain:ci-cd":   ["livemask-ci-cd", "livemask-backend", "livemask-admin"],
    "domain:release":      ["livemask-backend", "livemask-nodeagent", "livemask-admin"],
    "domain:governance":   ["livemask-backend", "livemask-admin", "livemask-app"],
}

CAPABILITY_REPO_MAP: dict[str, list[str]] = {
    "capability:api":      ["livemask-backend", "livemask-admin", "livemask-website"],
    "capability:db":       ["livemask-backend", "livemask-job-service"],
    "capability:ui":       ["livemask-admin", "livemask-app", "livemask-website"],
    "capability:payment":  ["livemask-backend", "livemask-admin"],
    "capability:scheduler": ["livemask-backend", "livemask-job-service"],
    "capability:realtime": ["livemask-backend", "livemask-nodeagent", "livemask-app"],
    "capability:dashboard": ["livemask-backend", "livemask-admin"],
    "capability:template":  ["livemask-backend", "livemask-nodeagent", "livemask-admin"],
}


# ── Data Loaders ────────────────────────────────────────────────────

def _load_tags(path: str = "") -> dict:
    """Load the tag registry."""
    if not path:
        path = os.path.join(CACHE_DIR, "business-tags.json")
    if os.path.exists(path):
        try:
            with open(path) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {"items": {}}


def _load_ledger(path: str) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        return {"modules": []}


def _load_experience() -> dict:
    path = os.path.join(CACHE_DIR, "experience.json")
    if os.path.exists(path):
        try:
            with open(path) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {"patterns": {}}


def _auto_tag_text(text: str) -> list[str]:
    """Mirror auto-tag from tags.py for quick tag extraction."""
    from tags import KEYWORD_TAG_MAP
    found = set()
    for pattern, tag in KEYWORD_TAG_MAP:
        if pattern.search(text):
            found.add(tag)
    # Add language tags
    lower = text.lower()
    if "go" in lower and any(f.endswith(".go") for f in text.split()):
        found.add("scope:backend")
    if any(k in lower for k in ["flutter", "dart", "widget", "screen"]):
        found.add("scope:mobile")
    if any(k in lower for k in ["react", "next.js", "component", "jsx"]):
        found.add("scope:frontend")
    if any(k in lower for k in ["documentation", "readme", "docs"]):
        found.add("scope:documentation")
    if any(k in lower for k in ["cross", "multi.repo", "chain", "closed.loop"]):
        found.add("scope:cross-repo")
    return sorted(found)


# ── Prediction Strategies ───────────────────────────────────────────

def _predict_cross_repo_gaps(tags_data: dict, ledger_data: dict) -> list[dict]:
    """Strategy 1: Cross-repo domain gaps.
    
    If a domain tag (e.g. 'domain:auth') is found on tasks in repos A and B,
    but repo C (which also should handle this domain per DOMAIN_REPO_MAP)
    has NO tasks with that tag, predict a new task.
    """
    predictions = []
    tag_items = tags_data.get("items", {})

    # Build {tag: {repo: [task_ids]}}
    tag_repo_tasks: dict[str, dict[str, list[str]]] = {}
    for item_id, item in tag_items.items():
        for tag in item.get("tags", []):
            meta = item.get("meta", {})
            repo = meta.get("repo", "")
            if not repo and item_id.startswith("TASK-"):
                # Try to infer repo from item_id naming convention
                for known_repo in ["backend", "admin", "app", "nodeagent", "job-service", "ci-cd", "docs", "website"]:
                    if known_repo in item_id.lower():
                        repo = f"livemask-{known_repo}"
                        break
            if repo:
                tag_repo_tasks.setdefault(tag, {}).setdefault(repo, []).append(item_id)

    # Check cross-repo domain tags
    for tag, repos_expected in DOMAIN_REPO_MAP.items():
        repos_with = tag_repo_tasks.get(tag, {})
        repos_found = set(repos_with.keys())

        for expected_repo in repos_expected:
            if expected_repo not in repos_found:
                # This repo is missing a task for this domain
                examples = []
                for r, tasks in repos_with.items():
                    for t in tasks[:2]:
                        examples.append(f"{t} ({r})")

                confidence = 60 + (10 * len(repos_found))  # More repos with it = higher confidence
                confidence = min(confidence, 90)

                predictions.append({
                    "strategy": "cross_repo_gap",
                    "tag": tag,
                    "missing_repo": expected_repo,
                    "repos_with_tasks": sorted(repos_found),
                    "example_tasks": examples[:3],
                    "confidence": confidence,
                    "reason": f"{tag} spans repos {', '.join(repos_expected)}; "
                              f"{expected_repo} has no tasks tagged with {tag}",
                })

    return predictions


def _predict_unlock_chain(ledger_data: dict) -> list[dict]:
    """Strategy 2: Unlock chain prediction.
    
    If Task A has 'unlocks: [Task B, Task C]' and Task A is completed but
    B or C don't exist in the ledger, predict them.
    """
    predictions = []
    ledger_ids = set()

    for module in ledger_data.get("modules", []):
        for task in module.get("tasks", []):
            tid = task.get("task_id", "")
            if tid:
                ledger_ids.add(tid)

    for module in ledger_data.get("modules", []):
        for task in module.get("tasks", []):
            tid = task.get("task_id", "")
            status = task.get("status", "").lower()
            unlocks = task.get("unlocks", [])

            if status in ("completed", "completed_with_skip") and unlocks:
                for unlocked_tid in unlocks:
                    if unlocked_tid not in ledger_ids:
                        predictions.append({
                            "strategy": "unlock_chain",
                            "trigger_task": tid,
                            "predicted_task": unlocked_tid,
                            "module": module.get("module_id", ""),
                            "confidence": 90,  # Explicit unlock from completed task = very high
                            "reason": f"Completed task {tid} unlocks {unlocked_tid}, "
                                      f"but {unlocked_tid} doesn't exist in ledger",
                        })

    return predictions


def _predict_tag_pattern_gaps(tags_data: dict, ledger_data: dict) -> list[dict]:
    """Strategy 3: Tag pattern gaps.
    
    Common tag combinations imply related tasks. E.g., if we have many
    'domain:auth' + 'capability:api' tasks in backend, we should also have
    'domain:auth' + 'capability:ui' tasks in admin.
    """
    predictions = []
    tag_items = tags_data.get("items", {})

    # Build tag co-occurrence matrix
    tag_pairs: defaultdict[str, Counter] = defaultdict(Counter)
    item_tags: dict[str, list[str]] = {}

    for item_id, item in tag_items.items():
        tags = item.get("tags", [])
        item_tags[item_id] = tags
        for i in range(len(tags)):
            for j in range(i + 1, len(tags)):
                t1, t2 = tags[i], tags[j]
                if t1 < t2:
                    tag_pairs[t1][t2] += 1
                else:
                    tag_pairs[t2][t1] += 1

    # Find strong co-occurrence patterns (pairs seen 3+ times)
    strong_pairs = {}
    for t1, partners in tag_pairs.items():
        for t2, count in partners.items():
            if count >= 2:  # At least 2 items share this pair
                strong_pairs[(t1, t2)] = count

    # For each strong pair, check which repos have it and which are missing
    pair_repos: dict[tuple, set[str]] = {}
    for item_id, tags in item_tags.items():
        for (t1, t2), _ in strong_pairs.items():
            if t1 in tags and t2 in tags:
                meta = tag_items.get(item_id, {}).get("meta", {})
                repo = meta.get("repo", "")
                if repo:
                    pair_repos.setdefault((t1, t2), set()).add(repo)

    # Predict: if a strong pair exists in repo A but not in repo B that handles both tags
    for (t1, t2), repos_found in pair_repos.items():
        all_possible = set()
        for tag in (t1, t2):
            for mapping in (DOMAIN_REPO_MAP, CAPABILITY_REPO_MAP):
                if tag in mapping:
                    all_possible.update(mapping[tag])
        for possible_repo in all_possible:
            if possible_repo not in repos_found:
                predictions.append({
                    "strategy": "tag_pattern",
                    "tag_pair": [t1, t2],
                    "pair_frequency": strong_pairs[(t1, t2)],
                    "missing_repo": possible_repo,
                    "repos_with_pattern": sorted(repos_found),
                    "confidence": 50 + (10 * strong_pairs[(t1, t2)]),
                    "reason": f"Strong tag co-occurrence {t1} + {t2} (seen {strong_pairs[(t1, t2)]}x) "
                              f"in {', '.join(sorted(repos_found))}, but not in {possible_repo}",
                })

    return predictions


def _predict_domain_expansion(tags_data: dict, ledger_data: dict) -> list[dict]:
    """Strategy 4: Domain expansion prediction.
    
    If a repo has a high density of tasks for domain X, predict that
    cross-repo partners also need tasks for domain X.
    """
    predictions = []
    tag_items = tags_data.get("items", {})

    # Count tasks per (domain_tag, repo)
    domain_repo_count: defaultdict[str, Counter] = defaultdict(Counter)
    for item_id, item in tag_items.items():
        meta = item.get("meta", {})
        repo = meta.get("repo", "")
        if not repo:
            continue
        for tag in item.get("tags", []):
            if tag.startswith("domain:"):
                domain_repo_count[tag][repo] += 1

    # For each domain with high concentration in one repo, check partners
    for domain_tag, repo_counts in domain_repo_count.items():
        if domain_tag not in DOMAIN_REPO_MAP:
            continue
        for repo_with, count in repo_counts.items():
            if count >= 3:  # Significant density
                expected_repos = DOMAIN_REPO_MAP[domain_tag]
                for expected in expected_repos:
                    if repo_counts.get(expected, 0) < count / 2:
                        predictions.append({
                            "strategy": "domain_expansion",
                            "tag": domain_tag,
                            "dense_repo": repo_with,
                            "density_count": count,
                            "missing_repo": expected,
                            "existing_in_missing": repo_counts.get(expected, 0),
                            "confidence": 40 + (10 * min(count, 5)),
                            "reason": f"{domain_tag} has {count} task(s) in {repo_with}, "
                                      f"but only {repo_counts.get(expected, 0)} task(s) in {expected}",
                        })

    return predictions


def _predict_phase_gaps(ledger_data: dict) -> list[dict]:
    """Strategy 5: Phase gap prediction.
    
    Look for unlocked chains where the successor task is very likely needed
    but may not be tracked yet. Also detect incomplete evidence chains.
    """
    predictions = []

    # Find tasks that reference specific features needing follow-up
    evidence_dir = os.path.join(os.environ.get("HOME", "/tmp"), ".claude", "role-cache", "evidence")
    if os.path.isdir(evidence_dir):
        for fname in os.listdir(evidence_dir):
            if not fname.endswith(".json"):
                continue
            try:
                with open(os.path.join(evidence_dir, fname)) as f:
                    ev = json.load(f)
                tid = ev.get("task_id", "")
                if not tid:
                    continue
                # Check if evidence has issue but no merge commit = still in progress
                issue = ev.get("issue", "")
                sha = ev.get("dev_merge_commit", "")
                if issue and not sha:
                    predictions.append({
                        "strategy": "phase_gap",
                        "task_id": tid,
                        "confidence": 70,
                        "reason": f"Task {tid} has GitHub issue but no merge SHA "
                                  f"— implementation evidence chain incomplete",
                    })
            except (json.JSONDecodeError, OSError):
                continue

    return predictions


# ── Prediction Engine ───────────────────────────────────────────────

def predict(ledger_path: str, contracts_path: str = "",
            mvp_path: str = "", tags_path: str = "") -> dict:
    """Run all prediction strategies and return ranked results."""

    ledger_data = _load_ledger(ledger_path) if ledger_path else {"modules": []}
    tags_data = _load_tags(tags_path) if tags_path else _load_tags()

    all_predictions = []
    all_predictions.extend(_predict_cross_repo_gaps(tags_data, ledger_data))
    all_predictions.extend(_predict_unlock_chain(ledger_data))
    all_predictions.extend(_predict_tag_pattern_gaps(tags_data, ledger_data))
    all_predictions.extend(_predict_domain_expansion(tags_data, ledger_data))
    all_predictions.extend(_predict_phase_gaps(ledger_data))

    # Deduplicate
    seen_keys = set()
    unique = []
    for p in all_predictions:
        key = json.dumps(p, sort_keys=True, default=str)
        if key not in seen_keys:
            seen_keys.add(key)
            unique.append(p)

    # Sort by confidence descending
    unique.sort(key=lambda x: -x.get("confidence", 0))

    # Count by strategy
    strategy_counts = Counter(p["strategy"] for p in unique)

    prediction = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total_predictions": len(unique),
        "by_strategy": dict(strategy_counts.most_common()),
        "high_confidence": sum(1 for p in unique if p.get("confidence", 0) >= 80),
        "medium_confidence": sum(1 for p in unique if 50 <= p.get("confidence", 0) < 80),
        "low_confidence": sum(1 for p in unique if p.get("confidence", 0) < 50),
        "predictions": unique,
    }

    # Save predictions to disk
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(PREDICTION_FILE, "w") as f:
        json.dump(prediction, f, indent=2, default=str)

    return prediction


# ── Suggest what comes after a specific task ────────────────────────

def cmd_suggest_for(args: list[str]) -> int:
    """task_predictor.py suggest-for <task_id>"""
    if not args:
        print(json.dumps({"error": "usage: suggest-for <task_id>"}))
        return 1

    task_id = args[0]

    # Load existing predictions
    if os.path.exists(PREDICTION_FILE):
        try:
            with open(PREDICTION_FILE) as f:
                predictions = json.load(f)
        except (json.JSONDecodeError, OSError):
            predictions = {"predictions": []}
    else:
        predictions = {"predictions": []}

    # Filter to predictions related to this task
    related = []
    for p in predictions.get("predictions", []):
        if task_id in json.dumps(p):
            related.append(p)

    # Also check ledger for what this task unlocks
    ledger_path = ""
    for p in predictions.get("predictions", []):
        if p.get("trigger_task") == task_id:
            related.append(p)

    # Also scan unlock graph directly
    root = os.environ.get("LIVEMASK_ROOT", os.path.expanduser("~/Developer/LiveMask"))
    ledger_path_o = os.path.join(root, "livemask-docs", "docs", "development", "task-state-ledger.json")
    if os.path.exists(ledger_path_o):
        ledger_data = _load_ledger(ledger_path_o)
        for module in ledger_data.get("modules", []):
            for task in module.get("tasks", []):
                if task.get("task_id") == task_id:
                    unlocks = task.get("unlocks", [])
                    blocked_by = task.get("blocked_by", [])
                    related.append({
                        "context": "direct_ledger",
                        "unlocks": unlocks,
                        "blocked_by": blocked_by,
                    })
                    break

    print(json.dumps({
        "task_id": task_id,
        "related_predictions": len(related),
        "predictions": related,
    }, indent=2))
    return 0


# ── Stats ───────────────────────────────────────────────────────────

def cmd_stats(args: list[str]) -> int:
    """task_predictor.py stats"""
    if os.path.exists(PREDICTION_FILE):
        try:
            with open(PREDICTION_FILE) as f:
                data = json.load(f)
            print(json.dumps({
                "status": "ok",
                "total_predictions": data.get("total_predictions", 0),
                "by_strategy": data.get("by_strategy", {}),
                "high_confidence": data.get("high_confidence", 0),
                "medium_confidence": data.get("medium_confidence", 0),
                "low_confidence": data.get("low_confidence", 0),
                "generated_at": data.get("generated_at", ""),
            }, indent=2))
        except Exception as e:
            print(json.dumps({"error": str(e)}))
            return 1
    else:
        print(json.dumps({"status": "no_predictions",
                          "message": "Run 'task_predictor.py predict' first"}))
    return 0


# ── Main CLI ────────────────────────────────────────────────────────

def main():
    _debug_setup()
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    command = sys.argv[1]
    args = sys.argv[2:]

    if command == "predict":
        ledger_path = ""
        contracts_path = ""
        mvp_path = ""
        tags_path = ""

        i = 0
        while i < len(args):
            if args[i] == "--ledger" and i + 1 < len(args):
                ledger_path = args[i + 1]; i += 2
            elif args[i] == "--contracts" and i + 1 < len(args):
                contracts_path = args[i + 1]; i += 2
            elif args[i] == "--mvp" and i + 1 < len(args):
                mvp_path = args[i + 1]; i += 2
            elif args[i] == "--tags" and i + 1 < len(args):
                tags_path = args[i + 1]; i += 2
            elif args[i] == "--all":
                root = os.environ.get("LIVEMASK_ROOT", os.path.expanduser("~/Developer/LiveMask"))
                docs = os.path.join(root, "livemask-docs", "docs")
                ledger_path = os.path.join(docs, "development", "task-state-ledger.json")
                contracts_path = os.path.join(docs, "contracts", "contract-index.md")
                mvp_path = os.path.join(docs, "development", "MVP_IMPLEMENTATION_PLAN.md")
                tags_path = os.path.join(CACHE_DIR, "business-tags.json")
                i += 1
            else:
                i += 1

        if not ledger_path:
            print(json.dumps({"error": "usage: predict --ledger PATH [--contracts PATH] [--mvp PATH] [--tags PATH] [--all]"}))
            return 1

        result = predict(ledger_path, contracts_path, mvp_path, tags_path)
        print(json.dumps(result, indent=2, default=str))
        return 0

    elif command == "suggest-for":
        return cmd_suggest_for(args)

    elif command == "stats":
        return cmd_stats(args)

    print(f"unknown command: {command}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    main()
