#!/usr/bin/env python3
"""
tags.py — Business tag registry + fast lookup for LiveMask dev loop.

Provides a centralized tag taxonomy with diskcache-backed fast search,
cross-repo business context tagging, and multi-task relationship queries.

Tag Categories (hierarchical):
  domain:{value}     — auth, billing, vpn, node, admin, app, content, geoip
  repo:{value}       — livemask-backend, livemask-admin, livemask-app, etc
  capability:{value} — api, db, ui, config, i18n, notification, payment, realtime
  architecture:{value} — closed-loop, control-plane, data-plane, event-driven, polling
  business:{value}   — growth, revenue, user, marketplace, governance, compliance
  stage:{value}      — planning, implementing, verifying, completed, blocked
  scope:{value}      — backend, frontend, mobile, cross-repo, documentation, ops
  dep:{value}        — depends-on-TASK-ID, unlocks-TASK-ID

Usage:
    tags.py search <query>                # Full-text search across tagged items
    tags.py search --tag domain:auth      # Filter by tag
    tags.py search --repo livemask-backend # Filter by repo
    tags.py tag <item_id> <tag1,tag2,...> [--source ledger|experience|manual]
    tags.py tag-add <item_id> <tag>       # Add single tag
    tags.py tag-remove <item_id> <tag>    # Remove single tag
    tags.py get <item_id>                 # Get all tags for an item
    tags.py related <item_id>             # Find related items through shared tags
    tags.py cross-repo <item_id>          # Show cross-repo tag relations
    tags.py taxonomy                      # List all known tags by category
    tags.py stats                         # Tag usage statistics
    tags.py enrich [--ledger PATH] [--contracts PATH] [--mvp PATH]
                                          # Auto-tag ledger tasks + contracts

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
TAG_FILE = os.path.join(CACHE_DIR, "business-tags.json")
LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT",
                                os.path.expanduser("~/Developer/LiveMask"))

# ── Tag Taxonomy ──────────────────────────────────────────────────────
# Each category has a list of known valid values.

TAG_TAXONOMY: dict[str, list[str]] = {
    "domain": [
        "auth", "billing", "vpn", "node", "admin", "app",
        "content", "geoip", "user", "notification", "marketplace",
        "growth", "revenue", "i18n", "protocol", "security",
        "observability", "ci-cd", "release", "governance",
    ],
    "repo": [
        # Dynamic — any livemask-* repo name is valid
        "livemask-backend", "livemask-admin", "livemask-app",
        "livemask-nodeagent", "livemask-website", "livemask-job-service",
        "livemask-ci-cd", "livemask-docs",
    ],
    "capability": [
        "api", "db", "ui", "config", "i18n", "notification",
        "payment", "realtime", "speedtest", "bandwidth",
        "connect", "disconnect", "reconnect", "dashboard",
        "reporting", "analytics", "search", "scheduler", "job",
        "template", "rollout", "rollback",
    ],
    "architecture": [
        "closed-loop", "control-plane", "data-plane",
        "event-driven", "polling", "pub-sub", "webhook",
        "state-machine", "gateway", "proxy",
    ],
    "business": [
        "growth", "revenue", "user-acquisition", "retention",
        "marketplace", "governance", "compliance", "reward",
        "sponsor", "referral", "three-level-reward",
        "subscription", "tier", "traffic-analytics",
    ],
    "stage": [
        "planning", "implementing", "verifying",
        "completed", "blocked", "cancelled", "deprecated",
    ],
    "scope": [
        "backend", "frontend", "mobile", "cross-repo",
        "documentation", "ops", "devops", "testing",
        "smoke-test", "e2e", "unit-test", "benchmark",
    ],
}

# Tag → parent category reverse lookup
TAG_TO_CATEGORY: dict[str, str] = {}
for cat, values in TAG_TAXONOMY.items():
    for v in values:
        TAG_TO_CATEGORY[f"{cat}:{v}"] = cat

# Dynamic valid prefixes (values not pre-defined)
DYNAMIC_CATEGORIES = {"repo", "intake", "type", "scope"}

# ── Cross-repo tag relationships ────────────────────────────────────
# These define business relationships across repos.
# Format: tag → [(repo_a, repo_b), ...] meaning the tag connects these repos.

CROSS_REPO_TAGS: dict[str, list[tuple[str, str]]] = {
    "domain:auth":    [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-app"), ("livemask-backend", "livemask-website")],
    "domain:billing": [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-website")],
    "domain:vpn":     [("livemask-backend", "livemask-nodeagent"), ("livemask-backend", "livemask-app")],
    "domain:node":    [("livemask-nodeagent", "livemask-backend"), ("livemask-nodeagent", "livemask-admin")],
    "domain:admin":   [("livemask-admin", "livemask-backend"), ("livemask-admin", "livemask-job-service")],
    "domain:app":     [("livemask-app", "livemask-backend"), ("livemask-app", "livemask-nodeagent")],
    "domain:content": [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-app"), ("livemask-backend", "livemask-website")],
    "domain:geoip":   [("livemask-backend", "livemask-nodeagent"), ("livemask-backend", "livemask-admin")],
    "domain:user":    [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-app")],
    "domain:notification": [("livemask-backend", "livemask-job-service")],
    "domain:marketplace":  [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-website"), ("livemask-backend", "livemask-app")],
    "domain:growth":       [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-website")],
    "domain:revenue":      [("livemask-backend", "livemask-admin")],
    "domain:i18n":    [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-app"), ("livemask-backend", "livemask-website")],
    "domain:protocol":     [("livemask-backend", "livemask-nodeagent"), ("livemask-backend", "livemask-app")],
    "domain:security":     [("livemask-backend", "livemask-nodeagent"), ("livemask-backend", "livemask-app"), ("livemask-backend", "livemask-admin")],
    "domain:observability": [("livemask-backend", "livemask-job-service"), ("livemask-backend", "livemask-admin")],
    "domain:ci-cd":   [("livemask-ci-cd", "livemask-backend"), ("livemask-ci-cd", "livemask-admin"), ("livemask-ci-cd", "livemask-app")],
    "domain:release":      [("livemask-backend", "livemask-nodeagent"), ("livemask-backend", "livemask-admin")],
    "domain:governance":   [("livemask-backend", "livemask-admin"), ("livemask-backend", "livemask-app")],
}

# ── Business Domain → Normalized Tags ───────────────────────────────
# When a task title/desc mentions certain keywords, auto-tag

KEYWORD_TAG_MAP: list[tuple[re.Pattern, str]] = [
    # Auth
    (re.compile(r'(auth|login|logout|token|session|rback|permission|role|jwt)', re.I), "domain:auth"),
    (re.compile(r'(auth|login|logout|token|session|permission|role)', re.I), "capability:api"),
    # Billing
    (re.compile(r'(billing|payment|invoice|pricing|plan|tier|subscription|usdt|pay)', re.I), "domain:billing"),
    (re.compile(r'(payment|usdt|pay)', re.I), "capability:payment"),
    # VPN
    (re.compile(r'(vpn|connect|disconnect|proxy|sing-box|hysteria|tunnel)', re.I), "domain:vpn"),
    (re.compile(r'(connect|disconnect|reconnect)', re.I), "capability:connect"),
    # Node
    (re.compile(r'(node|agent|speedtest|bandwidth|nat)', re.I), "domain:node"),
    (re.compile(r'(speedtest|bandwidth)', re.I), "capability:speedtest"),
    # Admin
    (re.compile(r'(admin|dashboard|settings|navigation|ia|manager)', re.I), "domain:admin"),
    (re.compile(r'(dashboard|reporting|analytics)', re.I), "capability:dashboard"),
    # App
    (re.compile(r'(app|flutter|mobile|client|release)', re.I), "domain:app"),
    # Content
    (re.compile(r'(content|cms|article|announcement|notification|template)', re.I), "domain:content"),
    # GeoIP
    (re.compile(r'(geoip|geo|ip|location)', re.I), "domain:geoip"),
    # User
    (re.compile(r'(user|profile|account|contact|notification)', re.I), "domain:user"),
    (re.compile(r'(notification|contact|email|sms|lark)', re.I), "capability:notification"),
    # Marketplace / Growth
    (re.compile(r'(marketplace|commerce|store|purchase)', re.I), "domain:marketplace"),
    (re.compile(r'(growth|referral|sponsor|reward|invite)', re.I), "domain:growth"),
    (re.compile(r'(reward|three.level|sponsor)', re.I), "business:reward"),
    (re.compile(r'(referral|invite|sponsor)', re.I), "business:referral"),
    # Revenue
    (re.compile(r'(revenue|analytics|traffic)', re.I), "domain:revenue"),
    (re.compile(r'(traffic.analytics)', re.I), "business:traffic-analytics"),
    # I18N
    (re.compile(r'(i18n|locale|translat|localization|language)', re.I), "domain:i18n"),
    # Protocol
    (re.compile(r'(protocol|endpoint|template|rollout|parity)', re.I), "domain:protocol"),
    (re.compile(r'(template|rollout|rollback)', re.I), "capability:template"),
    # Security
    (re.compile(r'(security|encrypt|credential|secret|certificate)', re.I), "domain:security"),
    # Observability
    (re.compile(r'(observability|log|metric|audit|monitor|alert)', re.I), "domain:observability"),
    # CI/CD
    (re.compile(r'(ci|cd|pipeline|build|deploy|smoke|test)', re.I), "domain:ci-cd"),
    # Scheduler
    (re.compile(r'(scheduler|cron|job|worker|queue)', re.I), "capability:scheduler"),
    (re.compile(r'(job|job.service)', re.I), "domain:notification"),
    # State machine
    (re.compile(r'(state.machine|status|transition|workflow)', re.I), "architecture:state-machine"),
    # Closed loop
    (re.compile(r'(closed.loop|control.plane)', re.I), "architecture:closed-loop"),
    # Real-time
    (re.compile(r'(realtime|websocket|event|stream)', re.I), "capability:realtime"),
    # Template
    (re.compile(r'(template|rollout|rollback)', re.I), "capability:template"),
]

# ── Data Helpers ─────────────────────────────────────────────────────

def _load_tags() -> dict:
    """Load the full tag registry. {item_id: {tags: [...], meta: {...}}}"""
    if not os.path.exists(TAG_FILE):
        return {"version": 2, "items": {}}
    try:
        with open(TAG_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"version": 2, "items": {}}


def _save_tags(data: dict):
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(TAG_FILE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def _get_cache():
    """Return a diskcache instance for fast tag lookups."""
    from diskcache import Cache
    os.makedirs(CACHE_DIR, exist_ok=True)
    return Cache(os.path.join(CACHE_DIR, "tags-cache"))


def _validate_tag(tag: str) -> tuple[bool, str]:
    """Validate that a tag follows the cat:value format and is known."""
    if ":" not in tag:
        return False, "tag must be in format 'category:value'"
    cat = tag.split(":")[0]
    # Dynamic categories (any value is valid)
    if cat in DYNAMIC_CATEGORIES:
        return True, ""
    if tag not in TAG_TO_CATEGORY:
        return False, f"unknown tag: {tag} (see tags.py taxonomy for known tags)"
    return True, ""


def _auto_tag_text(text: str) -> list[str]:
    """Scan text for keywords and return matching tags."""
    found = set()
    for pattern, tag in KEYWORD_TAG_MAP:
        if pattern.search(text):
            found.add(tag)
    return sorted(found)


def _normalize_item_id(item_id: str) -> str:
    """Normalize an item ID (task ID, error fingerprint, etc)."""
    return item_id.strip().replace(".md", "")


# ── Commands ─────────────────────────────────────────────────────────

def cmd_taxonomy(args: list[str]) -> int:
    """List all known tags by category."""
    result = {}
    for cat, values in TAG_TAXONOMY.items():
        result[cat] = [f"{cat}:{v}" for v in values]
    print(json.dumps(result, indent=2))
    return 0


def cmd_stats(args: list[str]) -> int:
    """Show tag usage statistics."""
    data = _load_tags()
    items = data.get("items", {})

    total_tagged = len(items)
    tag_counter = Counter()
    category_counter = Counter()
    repo_counter = Counter()

    for item_id, item in items.items():
        for tag in item.get("tags", []):
            tag_counter[tag] += 1
            cat = TAG_TO_CATEGORY.get(tag, "unknown")
            category_counter[cat] += 1
            # Detect repo from item_id or meta
            meta = item.get("meta", {})
            repo = meta.get("repo", "")
            if repo:
                repo_counter[repo] += 1

    # Also compute cross-repo stats
    cross_repo_items = 0
    for item_id, item in items.items():
        tags = item.get("tags", [])
        repos_involved = set()
        for tag in tags:
            if tag in CROSS_REPO_TAGS:
                for r1, r2 in CROSS_REPO_TAGS[tag]:
                    repos_involved.add(r1)
                    repos_involved.add(r2)
        if len(repos_involved) > 1:
            cross_repo_items += 1

    print(json.dumps({
        "total_tagged_items": total_tagged,
        "unique_tags": len(tag_counter),
        "cross_repo_items": cross_repo_items,
        "tags_by_category": dict(category_counter.most_common()),
        "top_tags": dict(tag_counter.most_common(20)),
        "items_by_repo": dict(repo_counter.most_common()),
    }, indent=2))
    return 0


def cmd_tag(args: list[str]) -> int:
    """tags.py tag <item_id> <tag_list> [--source ledger|experience|manual] [--meta KEY:VAL ...]"""
    if len(args) < 2:
        print(json.dumps({"error": "usage: tag <item_id> <tag1,tag2,...> [--source S] [--meta KEY:VAL]"}))
        return 1

    item_id = _normalize_item_id(args[0])
    raw_tags = args[1].split(",")
    source = "manual"
    meta = {}

    i = 2
    while i < len(args):
        if args[i] == "--source" and i + 1 < len(args):
            source = args[i + 1]; i += 2
        elif args[i] == "--meta" and i + 1 < len(args):
            kv = args[i + 1]
            if ":" in kv:
                k, v = kv.split(":", 1)
                meta[k.strip()] = v.strip()
            i += 2
        else:
            i += 1

    valid_tags = []
    errors = []
    for t in raw_tags:
        t = t.strip()
        if not t:
            continue
        ok, err = _validate_tag(t)
        if ok:
            valid_tags.append(t)
        else:
            errors.append({"tag": t, "error": err})

    # Auto-tag from item_id if no valid tags provided
    if not valid_tags:
        valid_tags = _auto_tag_text(item_id)

    data = _load_tags()
    items = data.setdefault("items", {})

    if item_id not in items:
        items[item_id] = {
            "tags": [],
            "meta": {"source": source, "created": time.time()},
        }
    items[item_id]["meta"].update(meta)
    items[item_id]["meta"]["source"] = source
    items[item_id]["meta"]["last_modified"] = time.time()

    # Merge tags (preserve existing)
    existing = set(items[item_id]["tags"])
    existing.update(valid_tags)
    items[item_id]["tags"] = sorted(existing)

    _save_tags(data)

    # Also update diskcache for fast search
    with _get_cache() as c:
        for tag in valid_tags:
            c.set(f"tag:{tag}:{item_id}", {
                "item_id": item_id, "tag": tag, "source": source,
                "timestamp": time.time(),
            })
        c.set(f"item:{item_id}", items[item_id])

    result = {
        "status": "ok",
        "item_id": item_id,
        "tags_added": valid_tags,
        "total_tags": len(existing),
        "warnings": errors or None,
    }
    print(json.dumps(result, indent=2))
    return 0 if not errors else 1


def cmd_tag_add(args: list[str]) -> int:
    """tags.py tag-add <item_id> <tag>"""
    if len(args) < 2:
        print(json.dumps({"error": "usage: tag-add <item_id> <tag>"}))
        return 1

    item_id = _normalize_item_id(args[0])
    tag = args[1].strip()

    ok, err = _validate_tag(tag)
    if not ok:
        print(json.dumps({"error": err, "tag": tag}))
        return 1

    data = _load_tags()
    items = data.setdefault("items", {})
    if item_id not in items:
        items[item_id] = {"tags": [], "meta": {"source": "manual", "created": time.time()}}
    items[item_id]["meta"]["last_modified"] = time.time()

    existing = set(items[item_id]["tags"])
    existing.add(tag)
    items[item_id]["tags"] = sorted(existing)
    _save_tags(data)

    with _get_cache() as c:
        c.set(f"tag:{tag}:{item_id}", {
            "item_id": item_id, "tag": tag, "source": "manual",
            "timestamp": time.time(),
        })
        c.set(f"item:{item_id}", items[item_id])

    print(json.dumps({"status": "ok", "item_id": item_id, "tag": tag}))
    return 0


def cmd_tag_remove(args: list[str]) -> int:
    """tags.py tag-remove <item_id> <tag>"""
    if len(args) < 2:
        print(json.dumps({"error": "usage: tag-remove <item_id> <tag>"}))
        return 1

    item_id = _normalize_item_id(args[0])
    tag = args[1].strip()

    data = _load_tags()
    items = data.get("items", {})
    if item_id not in items:
        print(json.dumps({"error": f"item not found: {item_id}"}))
        return 1

    if tag not in items[item_id]["tags"]:
        print(json.dumps({"error": f"tag not found on item", "tag": tag, "item_id": item_id}))
        return 1

    items[item_id]["tags"] = [t for t in items[item_id]["tags"] if t != tag]
    items[item_id]["meta"]["last_modified"] = time.time()
    _save_tags(data)

    with _get_cache() as c:
        c.delete(f"tag:{tag}:{item_id}")
        c.set(f"item:{item_id}", items[item_id])

    print(json.dumps({"status": "ok", "item_id": item_id, "tag_removed": tag}))
    return 0


def cmd_get(args: list[str]) -> int:
    """tags.py get <item_id>"""
    if not args:
        print(json.dumps({"error": "usage: get <item_id>"}))
        return 1

    item_id = _normalize_item_id(args[0])

    data = _load_tags()
    items = data.get("items", {})

    if item_id in items:
        result = {"status": "found", "item_id": item_id, **items[item_id]}
    else:
        # Try diskcache for fast lookup
        with _get_cache() as c:
            cached = c.get(f"item:{item_id}")
        if cached:
            result = {"status": "found", "item_id": item_id, **cached}
        else:
            result = {"status": "not_found", "item_id": item_id}

    print(json.dumps(result, indent=2))
    return 0


def cmd_search(args: list[str]) -> int:
    """tags.py search [query] [--tag TAG] [--repo REPO] [--category CAT] [--limit N]"""
    query = ""
    tag_filter = ""
    repo_filter = ""
    category_filter = ""
    limit = 50

    i = 0
    while i < len(args):
        if args[i] == "--tag" and i + 1 < len(args):
            tag_filter = args[i + 1]; i += 2
        elif args[i] == "--repo" and i + 1 < len(args):
            repo_filter = args[i + 1]; i += 2
        elif args[i] == "--category" and i + 1 < len(args):
            category_filter = args[i + 1]; i += 2
        elif args[i] == "--limit" and i + 1 < len(args):
            try: limit = int(args[i + 1])
            except ValueError: pass
            i += 2
        elif not query:
            query = args[i]; i += 1
        else:
            i += 1

    data = _load_tags()
    items = data.get("items", {})

    results = []
    for item_id, item in items.items():
        tags = item.get("tags", [])
        meta = item.get("meta", {})
        repo = meta.get("repo", "")

        # Apply filters
        if tag_filter and tag_filter not in tags:
            continue
        if repo_filter and repo_filter not in (repo, item_id):
            continue
        if category_filter:
            cat_tags = [t for t in tags if t.startswith(f"{category_filter}:")]
            if not cat_tags:
                continue

        # Apply search query
        if query:
            ql = query.lower()
            if ql not in item_id.lower() and not any(ql in t for t in tags):
                continue

        results.append({
            "item_id": item_id,
            "tags": tags,
            "meta": meta,
        })

    if query and len(results) < limit:
        # If not enough results, try diskcache full-text
        with _get_cache() as c:
            for key in c.iterkeys():
                if key.startswith("item:"):
                    cached = c.get(key)
                    if cached and "tags" in cached:
                        cid = key[5:]
                        if cid not in {r["item_id"] for r in results}:
                            ql = query.lower()
                            if ql in cid.lower() or any(ql in t for t in cached.get("tags", [])):
                                results.append({
                                    "item_id": cid,
                                    "tags": cached.get("tags", []),
                                    "meta": cached.get("meta", {}),
                                })
                                if len(results) >= limit:
                                    break

    results.sort(key=lambda x: len(x["tags"]), reverse=True)
    results = results[:limit]

    print(json.dumps({
        "query": query or "*",
        "total_matches": len(results),
        "results": results,
    }, indent=2))
    return 0


def cmd_related(args: list[str]) -> int:
    """tags.py related <item_id> — find related items through shared tags."""
    if not args:
        print(json.dumps({"error": "usage: related <item_id>"}))
        return 1

    item_id = _normalize_item_id(args[0])

    data = _load_tags()
    items = data.get("items", {})

    if item_id not in items:
        print(json.dumps({"error": f"item not found: {item_id}"}))
        return 1

    my_tags = set(items[item_id].get("tags", []))
    if not my_tags:
        print(json.dumps({"status": "no_tags", "item_id": item_id}))
        return 0

    related = []
    for other_id, other in items.items():
        if other_id == item_id:
            continue
        other_tags = set(other.get("tags", []))
        shared = my_tags & other_tags
        if shared:
            related.append({
                "item_id": other_id,
                "shared_tags": sorted(shared),
                "shared_count": len(shared),
                "meta": other.get("meta", {}),
            })

    related.sort(key=lambda x: -x["shared_count"])

    print(json.dumps({
        "item_id": item_id,
        "my_tags": sorted(my_tags),
        "total_related": len(related),
        "related_items": related[:20],
    }, indent=2))
    return 0


def cmd_cross_repo(args: list[str]) -> int:
    """tags.py cross-repo <item_id> — show cross-repo business relations."""
    if not args:
        print(json.dumps({"error": "usage: cross-repo <item_id>"}))
        return 1

    item_id = _normalize_item_id(args[0])

    data = _load_tags()
    items = data.get("items", {})
    my_tags = set(items.get(item_id, {}).get("tags", []))
    meta = items.get(item_id, {}).get("meta", {})

    cross_repo = {}
    for tag in my_tags:
        if tag in CROSS_REPO_TAGS:
            cross_repo[tag] = CROSS_REPO_TAGS[tag]

    # Also find other items with the same tags
    related_items = []
    for tag in my_tags:
        related_by_tag = []
        for oid, oitem in items.items():
            if oid == item_id:
                continue
            if tag in oitem.get("tags", []):
                related_by_tag.append({
                    "item_id": oid,
                    "meta": oitem.get("meta", {}),
                })
        if related_by_tag:
            related_items.append({
                "tag": tag,
                "items": related_by_tag,
            })

    print(json.dumps({
        "item_id": item_id,
        "my_tags": sorted(my_tags),
        "meta": meta,
        "cross_repo_connections": cross_repo,
        "related_by_tag": related_items,
    }, indent=2))
    return 0


def cmd_enrich(args: list[str]) -> int:
    """tags.py enrich — auto-tag ledger tasks + contracts from project docs."""
    ledger_path = ""
    contracts_path = ""
    mvp_path = ""

    i = 0
    while i < len(args):
        if args[i] == "--ledger" and i + 1 < len(args):
            ledger_path = args[i + 1]; i += 2
        elif args[i] == "--contracts" and i + 1 < len(args):
            contracts_path = args[i + 1]; i += 2
        elif args[i] == "--mvp" and i + 1 < len(args):
            mvp_path = args[i + 1]; i += 2
        else:
            i += 1

    root = os.environ.get("LIVEMASK_ROOT", os.path.expanduser("~/Developer/LiveMask"))
    docs_dir = os.path.join(root, "livemask-docs", "docs")

    if not ledger_path:
        ledger_path = os.path.join(docs_dir, "development", "task-state-ledger.json")
    if not contracts_path:
        contracts_path = os.path.join(docs_dir, "contracts", "contract-index.md")

    enriched = {"tasks": 0, "contracts": 0, "errors": []}

    # 1. Enrich ledger tasks
    if os.path.exists(ledger_path):
        try:
            with open(ledger_path) as f:
                ledger = json.load(f)

            for module in ledger.get("modules", []):
                for task in module.get("tasks", []):
                    tid = task.get("task_id", "")
                    if not tid:
                        continue

                    # Build context for auto-tagging
                    context = " ".join(filter(None, [
                        task.get("title", ""),
                        task.get("description", ""),
                        module.get("module", ""),
                        task.get("repo", ""),
                        task.get("status", ""),
                    ]))

                    tags = _auto_tag_text(context)

                    # Add stage tag
                    stage_tag = f"stage:{task.get('status', 'planning').lower()}"
                    if stage_tag in TAG_TO_CATEGORY:
                        tags.append(stage_tag)

                    # Add repo tag
                    repo = task.get("repo", "")
                    if repo and repo.startswith("livemask-"):
                        tags.append(f"repo:{repo}")
                    else:
                        # Try to infer from module
                        for dirname, (keyword, _) in [
                            ("livemask-backend", "Backend"),
                            ("livemask-admin", "Admin"),
                            ("livemask-app", "App"),
                            ("livemask-nodeagent", "NodeAgent"),
                            ("livemask-job-service", "Job Service"),
                            ("livemask-ci-cd", "CI-CD"),
                            ("livemask-docs", "Docs"),
                            ("livemask-website", "Website"),
                        ]:
                            if keyword in module.get("module", "") or keyword in tid:
                                tags.append(f"repo:{dirname}")
                                break

                    if tags:
                        # Suppress per-task output — redirect internal call
                        old_stdout, sys.stdout = sys.stdout, open(os.devnull, 'w')
                        try:
                            cmd_tag([tid, ",".join(set(tags)), "--source", "enrich",
                                     "--meta", f"repo:{repo}", "--meta", f"module:{module.get('module','')}"])
                        finally:
                            sys.stdout.close()
                            sys.stdout = old_stdout
                        enriched["tasks"] += 1
        except Exception as e:
            enriched["errors"].append(f"ledger: {e}")

    # 2. Enrich contracts
    if os.path.exists(contracts_path):
        try:
            # Use planner's contract parser if available
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            from planner import parse_contract_index
            contracts = parse_contract_index(contracts_path)
            for c in contracts:
                tid = c.get("task_id", "")
                if not tid:
                    continue
                context = " ".join(filter(None, [
                    c.get("name", ""),
                    c.get("domain", ""),
                    c.get("contract", ""),
                ]))
                tags = _auto_tag_text(context)
                if c.get("domain"):
                    tags.append(f"domain:{c['domain'].lower()}")
                if c.get("status", "").lower() in ("ready", "draft", "stable", "deprecated"):
                    tags.append(f"stage:{c['status'].lower()}")

                if tags:
                    # Suppress per-task output
                    old_stdout, sys.stdout = sys.stdout, open(os.devnull, 'w')
                    try:
                        cmd_tag([tid, ",".join(set(tags)), "--source", "enrich",
                                 "--meta", f"domain:{c.get('domain','')}"])
                    finally:
                        sys.stdout.close()
                        sys.stdout = old_stdout
                    enriched["contracts"] += 1
        except Exception as e:
            enriched["errors"].append(f"contracts: {e}")

    # Refresh diskcache
    with _get_cache() as c:
        data = _load_tags()
        c.set("_taxonomy", TAG_TAXONOMY)

    enriched["status"] = "ok"
    print(json.dumps(enriched, indent=2))
    return 0


@traced
def main():
    _debug_setup()
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "tag": cmd_tag,
        "tag-add": cmd_tag_add,
        "tag-remove": cmd_tag_remove,
        "get": cmd_get,
        "search": cmd_search,
        "related": cmd_related,
        "cross-repo": cmd_cross_repo,
        "taxonomy": cmd_taxonomy,
        "stats": cmd_stats,
        "enrich": cmd_enrich,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        return 1

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
