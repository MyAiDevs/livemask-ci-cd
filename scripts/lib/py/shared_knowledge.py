#!/usr/bin/env python3
"""
shared_knowledge.py — Unified Shared Knowledge Base for LiveMask dev loop.

Integrates five knowledge sources into a single queryable system:

  1. LOCAL_MEMORY — cache.py + tags.py + experience.py + knowledge_base.py
  2. DOCS — architecture docs, contracts, task documents, development docs
  3. GITHUB — repo metadata, milestones, releases, open issues, CI status
  4. OPEN_SOURCE — upstream docs/repos for Go, Flutter, sing-box, Hysteria2,
                   PostgreSQL, Next.js (indexed from web + local cache)
  5. SUPPLEMENT — manually curated supplement docs for project-specific
                  technology knowledge not covered by official docs

Usage:
    shared_knowledge.py build [--all]                     # Rebuild full index
    shared_knowledge.py search <query> [--source S] [--limit N]  # Search all sources
    shared_knowledge.py get <source>:<id>                 # Get specific entry
    shared_knowledge.py sources                            # List all sources + stats
    shared_knowledge.py sync-github [--repo R] [--all]    # Sync GitHub data
    shared_knowledge.py sync-upstream                     # Sync upstream docs cache
    shared_knowledge.py stats                              # Index statistics

Output: JSON to stdout.
"""

import json
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from debug_utils import setup as _debug_setup, traced, logger as _logger

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "cache")
SHARED_INDEX_FILE = os.path.join(CACHE_DIR, "shared-knowledge-index.json")
SUPPLEMENT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "supplement")
LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT",
                                os.path.expanduser("~/Developer/LiveMask"))
PY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)))


# ── Helper: run another Python tool ──────────────────────────────────

def _python(script: str, *args: str) -> str:
    script_path = os.path.join(PY_DIR, script)
    try:
        r = subprocess.run(
            [sys.executable, script_path] + list(args),
            capture_output=True, text=True, timeout=30,
        )
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return json.dumps({"error": str(e)})


def _run_gh(*args: str) -> str:
    """Run GitHub CLI and return stdout."""
    try:
        r = subprocess.run(
            ["gh"] + list(args), capture_output=True, text=True, timeout=30,
        )
        return r.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


# ── Index Schema ─────────────────────────────────────────────────────
# Each entry in the index has:
#   source: str       — local_memory | docs | github | open_source | supplement
#   source_type: str  — subcategory
#   id: str           — unique ID within source
#   title: str        — human-readable title
#   content: str      — full text content (truncated in search results)
#   tags: list[str]   — searchable tags
#   url: str          — reference URL (for docs/GitHub/upstream)
#   meta: dict        — additional metadata
#   indexed_at: str   — ISO timestamp


def _load_index() -> dict:
    """Load the shared knowledge index from diskcache."""
    if not os.path.exists(SHARED_INDEX_FILE):
        return {"version": 2, "entries": {}, "sources": {}, "last_build": ""}
    try:
        with open(SHARED_INDEX_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"version": 2, "entries": {}, "sources": {}, "last_build": ""}


def _save_index(idx: dict):
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(SHARED_INDEX_FILE, "w") as f:
        json.dump(idx, f, indent=2, ensure_ascii=False)
    # Also write to diskcache for fast search
    try:
        from diskcache import Cache
        with Cache(os.path.join(CACHE_DIR, "shared-knowledge-cache")) as c:
            c.set("_index", idx)
    except ImportError:
        pass


def _add_entry(idx: dict, entry: dict):
    """Add or update an entry in the index."""
    key = f"{entry['source']}:{entry['id']}"
    idx.setdefault("entries", {})[key] = entry
    src_count = idx.setdefault("sources", {}).setdefault(entry["source"], {})
    src_count["count"] = src_count.get("count", 0) + 1


# ── Source 1: LOCAL_MEMORY ───────────────────────────────────────────

def _index_local_memory(idx: dict):
    """Index from cache.py, tags.py, experience.py, knowledge_base.py."""
    # Tags
    tag_output = _python("tags.py", "stats")
    try:
        tag_data = json.loads(tag_output)
        _add_entry(idx, {
            "source": "local_memory", "source_type": "tags_stats",
            "id": "tags-stats", "title": "Business Tags Statistics",
            "content": json.dumps(tag_data, indent=2),
            "tags": ["tags", "business", "stats"],
            "url": "", "meta": {"total_items": tag_data.get("total_tagged_items", 0)},
            "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
    except (json.JSONDecodeError, KeyError):
        pass

    # Experience stats
    exp_output = _python("experience.py", "stats")
    try:
        exp_data = json.loads(exp_output)
        _add_entry(idx, {
            "source": "local_memory", "source_type": "experience_stats",
            "id": "experience-stats", "title": "Error Experience Statistics",
            "content": json.dumps(exp_data, indent=2),
            "tags": ["experience", "errors", "stats"],
            "url": "", "meta": {"patterns": exp_data.get("known_patterns", 0)},
            "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
    except (json.JSONDecodeError, KeyError):
        pass

    # Knowledge base topics
    kb_output = _python("knowledge_base.py", "list")
    try:
        kb_data = json.loads(kb_output)
        for topic in kb_data.get("topics", []):
            _add_entry(idx, {
                "source": "local_memory", "source_type": "knowledge_topic",
                "id": f"topic:{topic['topic']}",
                "title": topic["title"],
                "content": topic.get("summary", ""),
                "tags": topic.get("tags", []),
                "url": "", "meta": {"topic": topic["topic"]},
                "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            })
    except (json.JSONDecodeError, KeyError):
        pass

    # Cache namespaces
    cache_output = _python("cache.py", "stats")
    try:
        cache_data = json.loads(cache_output)
        for ns in cache_data.get("namespaces", []):
            _add_entry(idx, {
                "source": "local_memory", "source_type": "cache_ns",
                "id": f"cache:{ns['namespace']}",
                "title": f"Cache Namespace: {ns['namespace']}",
                "content": f"Keys: {ns.get('keys', 0)}, Size: {ns.get('size_bytes', 0)} bytes",
                "tags": ["cache", ns["namespace"]],
                "url": "", "meta": ns,
                "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            })
    except (json.JSONDecodeError, KeyError):
        pass


# ── Source 2: DOCS ───────────────────────────────────────────────────

def _index_docs(idx: dict):
    """Index architecture docs, contracts, task documents, development docs."""
    docs_root = os.path.join(LIVEMASK_ROOT, "livemask-docs", "docs")

    if not os.path.isdir(docs_root):
        return

    # Architecture docs
    arch_dir = os.path.join(docs_root, "architecture")
    if os.path.isdir(arch_dir):
        for root, dirs, files in os.walk(arch_dir):
            for fname in files:
                if not fname.endswith(".md"):
                    continue
                fpath = os.path.join(root, fname)
                rel = os.path.relpath(fpath, docs_root)
                content = _read_file(fpath)
                title = _extract_title(content) or fname
                tags = ["docs", "architecture"] + [os.path.basename(root)]
                _add_entry(idx, {
                    "source": "docs", "source_type": "architecture",
                    "id": rel, "title": title,
                    "content": content[:2000],
                    "tags": tags, "url": rel,
                    "meta": {"path": rel, "lines": len(content.split("\n"))},
                    "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })

    # Contracts
    contracts_dir = os.path.join(docs_root, "contracts")
    if os.path.isdir(contracts_dir):
        for root, dirs, files in os.walk(contracts_dir):
            for fname in files:
                if not fname.endswith(".md"):
                    continue
                fpath = os.path.join(root, fname)
                rel = os.path.relpath(fpath, docs_root)
                content = _read_file(fpath)
                title = _extract_title(content) or fname
                tags = ["docs", "contract"] + [os.path.basename(os.path.dirname(fpath))]
                _add_entry(idx, {
                    "source": "docs", "source_type": "contract",
                    "id": rel, "title": title,
                    "content": content[:3000],
                    "tags": tags, "url": rel,
                    "meta": {"path": rel, "lines": len(content.split("\n"))},
                    "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })

    # Development docs (key ones)
    dev_dir = os.path.join(docs_root, "development")
    key_dev_docs = [
        "AI_PROJECT_STATUS_ONBOARDING.md",
        "MVP_IMPLEMENTATION_PLAN.md",
        "DEFINITION_OF_DONE.md",
        "DEVELOPMENT_CLOSED_LOOP_CHECKLIST.md",
        "LiveMask_AI辅助开发工作流与规范_v3.7.md",
        "ISSUE_TASK_SYNC_GOVERNANCE.md",
        "CODEX_LOOP_RULES.md",
        "TASK_LOCK_SYSTEM.md",
    ]
    if os.path.isdir(dev_dir):
        for fname in key_dev_docs:
            fpath = os.path.join(dev_dir, fname)
            if not os.path.isfile(fpath):
                continue
            content = _read_file(fpath)
            title = _extract_title(content) or fname
            rel = os.path.relpath(fpath, docs_root)
            _add_entry(idx, {
                "source": "docs", "source_type": "development",
                "id": rel, "title": title,
                "content": content[:3000],
                "tags": ["docs", "development"],
                "url": rel,
                "meta": {"path": rel, "lines": len(content.split("\n"))},
                "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            })

        # Task README (task index)
        tasks_readme = os.path.join(dev_dir, "tasks", "README.md")
        if os.path.isfile(tasks_readme):
            content = _read_file(tasks_readme)
            _add_entry(idx, {
                "source": "docs", "source_type": "task_index",
                "id": "development/tasks/README.md",
                "title": "Task Workspace Index",
                "content": content[:3000],
                "tags": ["docs", "tasks", "index"],
                "url": "development/tasks/README.md",
                "meta": {"path": "development/tasks/README.md", "lines": len(content.split("\n"))},
                "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            })

    # Task docs (top 100 most recent by modification time)
    tasks_dir = os.path.join(dev_dir, "tasks")
    if os.path.isdir(tasks_dir):
        task_files = sorted(
            [f for f in Path(tasks_dir).glob("TASK-*.md") if f.is_file()],
            key=lambda p: p.stat().st_mtime, reverse=True,
        )[:100]
        for fpath in task_files:
            content = _read_file(str(fpath))
            title = _extract_title(content) or fpath.name
            rel = os.path.relpath(str(fpath), docs_root)
            # Extract TASK ID from filename
            tid = fpath.stem
            _add_entry(idx, {
                "source": "docs", "source_type": "task_doc",
                "id": rel, "title": title,
                "content": content[:2000],
                "tags": ["docs", "task", tid[:20]],
                "url": rel,
                "meta": {"path": rel, "task_id": tid, "lines": len(content.split("\n"))},
                "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            })


def _read_file(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read(10000)
    except (OSError, UnicodeDecodeError):
        return ""


def _extract_title(content: str) -> str:
    """Extract the first Markdown heading as title."""
    m = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
    if m:
        return m.group(1).strip()
    m = re.search(r'^#+\s+(.+)$', content, re.MULTILINE)
    if m:
        return m.group(1).strip()
    return ""


# ── Source 3: GITHUB ─────────────────────────────────────────────────

def _index_github(idx: dict):
    """Index GitHub repo metadata using gh CLI."""
    repos = [
        "MyAiDevs/livemask-backend",
        "MyAiDevs/livemask-admin",
        "MyAiDevs/livemask-app",
        "MyAiDevs/livemask-website",
        "MyAiDevs/livemask-nodeagent",
        "MyAiDevs/livemask-job-service",
        "MyAiDevs/livemask-ci-cd",
        "MyAiDevs/livemask-docs",
    ]

    for full_repo in repos:
        repo_name = full_repo.split("/")[-1]

        # Repo metadata
        info = _run_gh("repo", "view", full_repo, "--json", "name,description,url,primaryLanguage,forkCount,stargazerCount")
        try:
            repo_info = json.loads(info) if info else {}
        except json.JSONDecodeError:
            repo_info = {}

        desc = repo_info.get("description", "")
        lang = repo_info.get("primaryLanguage", {}).get("name", "") if isinstance(repo_info.get("primaryLanguage"), dict) else ""

        _add_entry(idx, {
            "source": "github", "source_type": "repo_meta",
            "id": f"repo:{repo_name}",
            "title": f"GitHub Repo: {repo_name}",
            "content": f"Description: {desc}\nLanguage: {lang}\nURL: {full_repo}",
            "tags": ["github", "repo", repo_name],
            "url": f"https://github.com/{full_repo}",
            "meta": {"repo": full_repo, **repo_info},
            "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })

        # Recent open issues (max 10 per repo)
        issues = _run_gh("issue", "list", "--repo", full_repo, "--state", "open", "--limit", "10",
                          "--json", "number,title,state,labels,updatedAt,url")
        try:
            issues_data = json.loads(issues) if issues else []
            for issue in issues_data:
                inum = issue.get("number", 0)
                labels = [l.get("name", "") for l in issue.get("labels", []) if isinstance(l, dict)]
                _add_entry(idx, {
                    "source": "github", "source_type": "open_issue",
                    "id": f"issue:{repo_name}#{inum}",
                    "title": f"[{repo_name}#{inum}] {issue.get('title', '')}",
                    "content": f"Repo: {repo_name}\nState: {issue.get('state', '')}\nUpdated: {issue.get('updatedAt', '')}",
                    "tags": ["github", "issue", repo_name] + [f"label:{l}" for l in labels],
                    "url": issue.get("url", f"https://github.com/{full_repo}/issues/{inum}"),
                    "meta": {"repo": full_repo, "number": inum, "labels": labels},
                    "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })
        except (json.JSONDecodeError, KeyError):
            pass

        # Recent releases (max 3 per repo)
        releases = _run_gh("release", "list", "--repo", full_repo, "--limit", "3",
                            "--json", "tagName,name,isLatest,createdAt,url")
        try:
            rel_data = json.loads(releases) if releases else []
            for r in rel_data:
                _add_entry(idx, {
                    "source": "github", "source_type": "release",
                    "id": f"release:{repo_name}:{r.get('tagName', '')}",
                    "title": f"Release {r.get('tagName', '')}: {r.get('name', '')}",
                    "content": f"Repo: {repo_name}\nTag: {r.get('tagName', '')}\nLatest: {r.get('isLatest', False)}\nCreated: {r.get('createdAt', '')}",
                    "tags": ["github", "release", repo_name],
                    "url": r.get("url", f"https://github.com/{full_repo}/releases"),
                    "meta": {"repo": full_repo, "tag": r.get("tagName", "")},
                    "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })
        except (json.JSONDecodeError, KeyError):
            pass


# ── Source 4: OPEN_SOURCE (Upstream Docs) ────────────────────────────

def _index_open_source(idx: dict):
    """Index upstream documentation references for key technologies."""
    upstream_refs = [
        # Go
        {
            "id": "go-official-docs", "title": "Go Official Documentation",
            "content": "https://go.dev/doc/ — Effective Go, Go by Example, Standard library docs. "
                       "The Go programming language: static typing, goroutines, channels, interfaces, error handling.",
            "tags": ["go", "official", "upstream", "golang"],
            "url": "https://go.dev/doc/",
            "source_type": "language_docs",
        },
        {
            "id": "go-pgx", "title": "pgx — PostgreSQL Driver for Go",
            "content": "https://github.com/jackc/pgx — pgx v5 is the PostgreSQL driver used by livemask-backend. "
                       "Connection pooling via pgxpool, prepared statements, COPY protocol, PostgreSQL type system.",
            "tags": ["go", "database", "postgresql", "pgx", "upstream"],
            "url": "https://github.com/jackc/pgx",
            "source_type": "library_docs",
        },
        {
            "id": "go-chi", "title": "chi — Go HTTP Router",
            "content": "https://github.com/go-chi/chi — Lightweight, idiomatic HTTP router for Go. "
                       "Used by livemask-backend for route definitions, middleware chains, RESTful APIs.",
            "tags": ["go", "router", "http", "chi", "upstream"],
            "url": "https://github.com/go-chi/chi",
            "source_type": "library_docs",
        },
        {
            "id": "go-asynq", "title": "Asynq — Go Distributed Task Queue",
            "content": "https://github.com/hibiken/asynq — Go distributed task queue backed by Redis. "
                       "Used by livemask for job scheduling, background workers, delayed tasks.",
            "tags": ["go", "task-queue", "redis", "asynq", "upstream"],
            "url": "https://github.com/hibiken/asynq",
            "source_type": "library_docs",
        },
        # Flutter/Dart
        {
            "id": "flutter-official-docs", "title": "Flutter Official Documentation",
            "content": "https://docs.flutter.dev/ — Widget catalog, state management, platform channels, "
                       "build and release, testing, animation. Used by livemask-app for cross-platform VPN client UI.",
            "tags": ["flutter", "dart", "official", "upstream"],
            "url": "https://docs.flutter.dev/",
            "source_type": "language_docs",
        },
        {
            "id": "flutter-provider", "title": "Provider — Flutter State Management",
            "content": "https://pub.dev/packages/provider — State management for Flutter. "
                       "ChangeNotifier, MultiProvider, Consumer. Used by livemask-app for reactive UI state.",
            "tags": ["flutter", "state-management", "provider", "upstream"],
            "url": "https://pub.dev/packages/provider",
            "source_type": "library_docs",
        },
        {
            "id": "flutter_secure_storage", "title": "flutter_secure_storage",
            "content": "https://pub.dev/packages/flutter_secure_storage — Secure storage plugin for Flutter. "
                       "Wraps Keychain (iOS) and EncryptedSharedPreferences (Android). Used for token storage.",
            "tags": ["flutter", "security", "storage", "upstream"],
            "url": "https://pub.dev/packages/flutter_secure_storage",
            "source_type": "library_docs",
        },
        {
            "id": "dart-io", "title": "Dart IO & Platform Channels",
            "content": "https://api.dart.dev/stable/dart-io/dart-io-library.html — Dart IO library. "
                       "Socket, HTTP client/server, file system, process management. Foundation for Flutter networking.",
            "tags": ["dart", "io", "network", "socket", "upstream"],
            "url": "https://api.dart.dev/stable/dart-io/dart-io-library.html",
            "source_type": "language_docs",
        },
        # sing-box
        {
            "id": "sing-box-github", "title": "sing-box — Universal Proxy Platform",
            "content": "https://github.com/SagerNet/sing-box — The universal proxy platform. Go-based. "
                       "Supports TUN mode, Hysteria2, VLESS, Shadowsocks, Trojan, WireGuard outbound/inbound. "
                       "Config is JSON-based. Used by livemask-nodeagent and livemask-app (via gomobile).",
            "tags": ["vpn", "sing-box", "proxy", "go", "upstream", "github"],
            "url": "https://github.com/SagerNet/sing-box",
            "source_type": "project_repo",
        },
        {
            "id": "sing-box-config-docs", "title": "sing-box Configuration Reference",
            "content": "https://sing-box.sagernet.org/configuration/ — Official sing-box configuration docs. "
                       "Inbound/outbound types, route rules, DNS, TUN, experimental features. "
                       "JSON schema for all protocol configurations.",
            "tags": ["vpn", "sing-box", "config", "upstream", "docs"],
            "url": "https://sing-box.sagernet.org/configuration/",
            "source_type": "official_docs",
        },
        # Hysteria2
        {
            "id": "hysteria2-github", "title": "Hysteria2 — Proxy Protocol Based on QUIC",
            "content": "https://github.com/apernet/hysteria — Hysteria2 is a powerful, censorship-resistant proxy. "
                       "Based on QUIC protocol. Features masquerade, brutal congestion control, bandwidth estimation. "
                       "Used by livemask as primary VPN protocol via sing-box integration.",
            "tags": ["vpn", "hysteria2", "quic", "proxy", "upstream", "github"],
            "url": "https://github.com/apernet/hysteria",
            "source_type": "project_repo",
        },
        {
            "id": "hysteria2-docs", "title": "Hysteria2 Official Documentation",
            "content": "https://hysteria.network/docs/ — Hysteria2 protocol docs. "
                       "Server/client configuration, ACL, masquerade, bandwidth, benchmarks.",
            "tags": ["vpn", "hysteria2", "docs", "upstream"],
            "url": "https://hysteria.network/docs/",
            "source_type": "official_docs",
        },
        # VLESS / Xray
        {
            "id": "xray-github", "title": "Xray-core — VLESS Protocol",
            "content": "https://github.com/XTLS/Xray-core — Xray-core implements VLESS, VMess, Trojan, Shadowsocks. "
                       "VLESS is a lightweight proxy protocol with TLS encryption. "
                       "XTLS Vision flow for anti-censorship. Used by livemask-nodeagent via sing-box.",
            "tags": ["vpn", "vless", "xray", "proxy", "upstream", "github"],
            "url": "https://github.com/XTLS/Xray-core",
            "source_type": "project_repo",
        },
        # PostgreSQL
        {
            "id": "postgresql-docs", "title": "PostgreSQL Official Documentation",
            "content": "https://www.postgresql.org/docs/current/ — PostgreSQL documentation: SQL syntax, "
                       "data types, indexing, partitioning, replication, pg_stat_statements, EXPLAIN ANALYZE. "
                       "Used as primary database for livemask-backend and livemask-job-service.",
            "tags": ["database", "postgresql", "sql", "upstream", "docs"],
            "url": "https://www.postgresql.org/docs/current/",
            "source_type": "official_docs",
        },
        # Redis
        {
            "id": "redis-docs", "title": "Redis Official Documentation",
            "content": "https://redis.io/docs/latest/ — Redis data structures, commands, persistence, replication, "
                       "sentinel, cluster, streams, pub/sub. Used by livemask for caching, task queues (Asynq), "
                       "session storage, rate limiting.",
            "tags": ["redis", "cache", "queue", "upstream", "docs"],
            "url": "https://redis.io/docs/latest/",
            "source_type": "official_docs",
        },
        # Next.js
        {
            "id": "nextjs-docs", "title": "Next.js Official Documentation",
            "content": "https://nextjs.org/docs — Next.js App Router, pages router, API routes, middleware, "
                       "server components, client components, data fetching, revalidation. "
                       "Used by livemask-admin (dashboard) and livemask-website (marketing site).",
            "tags": ["nextjs", "react", "frontend", "upstream", "docs"],
            "url": "https://nextjs.org/docs",
            "source_type": "official_docs",
        },
        # Docker / Compose
        {
            "id": "docker-compose-docs", "title": "Docker Compose Documentation",
            "content": "https://docs.docker.com/compose/ — Docker Compose for local development. "
                       "Multi-container setup for livemask: backend, admin, website, nodeagent, "
                       "job-service, postgres, redis.",
            "tags": ["docker", "compose", "devops", "upstream", "docs"],
            "url": "https://docs.docker.com/compose/",
            "source_type": "official_docs",
        },
        # Flutter gomobile
        {
            "id": "gomobile-docs", "title": "gomobile — Go Mobile Bind",
            "content": "https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile — gomobile bind compiles Go packages "
                       "into Android AAR and iOS framework. Used by livemask-app to integrate sing-box Go engine "
                       "into Flutter via platform channels.",
            "tags": ["go", "mobile", "android", "ios", "gomobile", "upstream"],
            "url": "https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile",
            "source_type": "library_docs",
        },
        # go-jose / JWT
        {
            "id": "go-jose", "title": "go-jose — JWT Implementation for Go",
            "content": "https://github.com/go-jose/go-jose — Go implementation of JSON Object Signing and Encryption. "
                       "Used for JWT token signing/verification in livemask-backend auth system.",
            "tags": ["go", "jwt", "auth", "security", "upstream"],
            "url": "https://github.com/go-jose/go-jose",
            "source_type": "library_docs",
        },
        # Testify
        {
            "id": "testify", "title": "testify — Go Testing Toolkit",
            "content": "https://github.com/stretchr/testify — Go testing toolkit with assertions, mocking, "
                       "test suites. Used in all livemask Go repos for unit and integration tests.",
            "tags": ["go", "testing", "assert", "mock", "upstream"],
            "url": "https://github.com/stretchr/testify",
            "source_type": "library_docs",
        },
    ]

    for ref in upstream_refs:
        _add_entry(idx, {
            "source": "open_source", "source_type": ref["source_type"],
            "id": ref["id"], "title": ref["title"],
            "content": ref["content"],
            "tags": ref["tags"], "url": ref["url"],
            "meta": {"source_type": ref["source_type"]},
            "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })

    # Also add GitHub repo URLs for the open-source projects
    os_projects = [
        ("SagerNet/sing-box", "sing-box", "Universal proxy platform (Go)"),
        ("apernet/hysteria", "hysteria2", "Hysteria2 proxy protocol (Go)"),
        ("XTLS/Xray-core", "xray-core", "Xray-core VLESS protocol (Go)"),
        ("jackc/pgx", "pgx", "PostgreSQL driver for Go"),
        ("go-chi/chi", "chi", "Go HTTP router"),
        ("hibiken/asynq", "asynq", "Go distributed task queue"),
        ("stretchr/testify", "testify", "Go testing toolkit"),
        ("SagerNet/sing-box", "sing-box", "Universal proxy platform"),
    ]

    for full_repo, short_name, desc in os_projects:
        try:
            info = _run_gh("repo", "view", full_repo, "--json", "name,description,url,stargazerCount")
            repo_info = json.loads(info) if info else {}
            if repo_info:
                _add_entry(idx, {
                    "source": "open_source", "source_type": "github_meta",
                    "id": f"gh:{short_name}",
                    "title": f"GitHub: {full_repo}",
                    "content": f"{desc}\nStars: {repo_info.get('stargazerCount', '?')}\nURL: {repo_info.get('url', '')}",
                    "tags": ["open-source", short_name, "github"],
                    "url": repo_info.get("url", f"https://github.com/{full_repo}"),
                    "meta": {"repo": full_repo, **repo_info},
                    "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })
        except Exception:
            pass


# ── Source 5: SUPPLEMENT (Supplement Docs) ──────────────────────────

def _index_supplement(idx: dict):
    """Index supplement documents from the supplement/ directory."""
    supp_dir = SUPPLEMENT_DIR
    if not os.path.isdir(supp_dir):
        # Create it
        os.makedirs(supp_dir, exist_ok=True)
        # Create default supplement docs
        _create_default_supplements(supp_dir)

    for fname in sorted(os.listdir(supp_dir)):
        if not fname.endswith(".md"):
            continue
        fpath = os.path.join(supp_dir, fname)
        content = _read_file(fpath)
        if not content:
            continue
        title = _extract_title(content) or fname.replace(".md", "")
        topic = fname.replace(".md", "")
        _add_entry(idx, {
            "source": "supplement", "source_type": "tech_doc",
            "id": topic, "title": title,
            "content": content[:5000],
            "tags": ["supplement", topic.split("-")[0] if "-" in topic else topic],
            "url": fpath,
            "meta": {"path": fpath, "topic": topic, "lines": len(content.split("\n"))},
            "indexed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })


def _create_default_supplements(supp_dir: str):
    """Create default supplement documents for core technologies."""
    supplements = {
        "sing-box-config-patterns.md": _SINGBOX_PATTERNS,
        "hysteria2-deployment.md": _HYSTERIA2_DEPLOY,
        "postgresql-performance.md": _POSTGRESQL_PERF,
        "flutter-vpn-integration.md": _FLUTTER_VPN,
        "nextjs-admin-patterns.md": _NEXTJS_ADMIN,
        "go-concurrency-patterns.md": _GO_CONCURRENCY,
        "docker-dev-stack.md": _DOCKER_DEV,
    }
    for fname, content in supplements.items():
        fpath = os.path.join(supp_dir, fname)
        if not os.path.exists(fpath):
            with open(fpath, "w") as f:
                f.write(content)


# ── Default supplement documents ────────────────────────────────────

_SINGBOX_PATTERNS = """# sing-box Configuration Patterns

> Supplement document — livemask-nodeagent sing-box integration patterns
> Source: https://sing-box.sagernet.org/ + livemask implementation

## Common Profiles in livemask

### TUN Inbound (Standard)

```json
{
  "inbounds": [{
    "type": "tun",
    "interface_name": "tun0",
    "address": ["10.0.0.1/30"],
    "mtu": 1500,
    "auto_route": true,
    "strict_route": false
  }]
}
```

### Hysteria2 Outbound

```json
{
  "outbounds": [{
    "type": "hysteria2",
    "tag": "hy2-out",
    "server": "example.com:443",
    "up_mbps": 100,
    "down_mbps": 500,
    "password": "auth-token",
    "tls": {
      "enabled": true,
      "server_name": "example.com",
      "insecure": false
    }
  }]
}
```

### VLESS Outbound

```json
{
  "outbounds": [{
    "type": "vless",
    "tag": "vless-out",
    "server": "example.com:443",
    "uuid": "uuid-here",
    "flow": "xtls-rprx-vision",
    "tls": { "enabled": true, "server_name": "example.com" }
  }]
}
```

## Route Rules

```json
{
  "route": {
    "rules": [
      { "rule_set": ["geoip-cn"], "outbound": "direct" },
      { "rule_set": ["geosite-cn"], "outbound": "direct" },
      { "rule_set": ["geosite-category-ads"], "outbound": "block" }
    ],
    "rule_set": [
      { "type": "remote", "tag": "geoip-cn", "url": "https://...", "download_detour": "proxy-out" },
      { "type": "remote", "tag": "geosite-cn", "url": "https://..." }
    ],
    "final": "hy2-out",
    "auto_detect_interface": true
  }
}
```

## Key Rules for livemask

1. Never store full config in code — construct from ProtocolProfile
2. Always set `tls.insecure: false` in production
3. Use `"domain_strategy": "prefer_ipv6"` for IPv6 support
4. Keep `"experimental"` section minimal — only CLASH_API for metrics
5. TUN MTU: 1500 is safe default; lower (1300-1400) for lossy networks
"""

_HYSTERIA2_DEPLOY = """# Hysteria2 Deployment Notes

> Supplement document — Hysteria2 protocol deployment and tuning
> Source: https://github.com/apernet/hysteria + community best practices

## Server Configuration

```yaml
listen: :443
tls:
  cert: /path/to/cert.pem
  key: /path/to/key.pem
auth:
  type: password
  password: changeme
quic:
  init_stream_ receive_window: 8388608
  max_stream_receive_window: 8388608
  keep_alive_period: 10s
bandwidth:
  up: 1 gbps
  down: 1 gbps
masquerade:
  type: proxy
  proxy:
    url: https://example.com/
    rewrite_host: true
```

## Client Configuration (standalone, not sing-box)

```yaml
server: example.com:443
auth: password
tls:
  sni: example.com
  insecure: false
bandwidth:
  up: 100 mbps
  down: 500 mbps
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
```

## Performance Tuning

1. Bandwidth estimation: enable client-side for adaptive speed
2. QUIC buffer: increase kernel UDP buffer (net.core.rmem_max, net.core.wmem_max)
3. Masquerade: always enable to bypass DPI
4. Obfuscation: use password-based obfuscation if TLS fingerprint is an issue
5. Multi-port: use `"listen": ":443"` single-port for simplicity

## Known Issues

- QUIC over UDP: some ISPs throttle UDP; TCP fallback not natively supported
- Connection migration: NOT fully supported in hysteria2 (unlike raw QUIC)
- Bandwidth cap: enforced server-side; client cap is advisory
"""

_POSTGRESQL_PERF = """# PostgreSQL Performance Guide

> Supplement document — PostgreSQL tuning for livemask-backend
> Source: https://www.postgresql.org/docs/current/ + livemask deployment experience

## Connection Pool Settings (pgxpool)

```go
config, _ := pgxpool.ParseConfig(dsn)
config.MaxConns = 50
config.MinConns = 10
config.MaxConnLifetime = 30 * time.Minute
config.MaxConnIdleTime = 5 * time.Minute
config.HealthCheckPeriod = 1 * time.Minute
```

## Indexing Strategy for livemask

- All foreign keys: always index
- status + created_at: composite index for task/job/node listing queries
- user_id + created_at: for user-centric pagination
- node_id + timestamp: for time-series and heartbeat queries
- Partial indexes: `CREATE INDEX ... WHERE status = 'active'` for hot rows

## Common Migration Patterns

```sql
-- Safe column add with default
ALTER TABLE users ADD COLUMN referral_code VARCHAR(64) UNIQUE;
-- Backfill in batches (avoid long-running lock)
UPDATE users SET referral_code = gen_random_uuid()::text WHERE referral_code IS NULL LIMIT 1000;
```

## Query Performance Tips

1. Use `EXPLAIN ANALYZE` before deploying new queries
2. Prefer `LIMIT` + `OFFSET` cursor over `OFFSET` for pagination
3. Use `pg_stat_statements` to identify slow queries
4. Use connection pooling (pgxpool) — never open/close per request
5. CTEs are optimization fences in PG — materialize explicitly when needed
6. Use `jsonb` for flexible config fields, not EAV
"""

_FLUTTER_VPN = """# Flutter VPN Integration Patterns

> Supplement document — Flutter VPN client integration with sing-box via gomobile
> Source: livemask-app implementation + community patterns

## Architecture Flow

```
Flutter UI (Dart)
    ↓ MethodChannel ('com.livemask/vpn')
Platform Native (Kotlin/Swift)
    ↓ VpnService (Android) / PacketTunnelProvider (iOS)
TUN File Descriptor
    ↓ fd passed to Go engine
sing-box Engine (Go, via gomobile AAR)
    ↓ proxy connection
VPN Server
```

## Android VpnService Integration

```kotlin
// Android native
class LiveMaskVpnService : VpnService() {
    private fun setupTun(): ParcelFileDescriptor {
        return Builder()
            .setMtu(1500)
            .addAddress("10.0.0.2", 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .establish()
    }
}
```

## Flutter Platform Channel

```dart
class VpnChannel {
  static const channel = MethodChannel('com.livemask/vpn');

  static Future<bool> connect(Map<String, dynamic> config) async {
    return await channel.invokeMethod('connect', config);
  }

  static Future<bool> disconnect() async {
    return await channel.invokeMethod('disconnect');
  }

  static Stream<Map<String, dynamic>> get statusStream {
    return EventChannel('com.livemask/vpn/status')
        .receiveBroadcastStream()
        .cast<Map<String, dynamic>>();
  }
}
```

## Build & Dependencies

1. Gomobile AAR: `gomobile bind -target=android/arm64 -o android/app/libs/engine.aar ./pkg/mobile/`
2. Add to android/app/build.gradle: `implementation files('libs/engine.aar')`
3. iOS framework: `gomobile bind -target=ios -o ios/Frameworks/Engine.framework ./pkg/mobile/`
4. iOS must disable bitcode for gomobile frameworks
"""

_NEXTJS_ADMIN = """# Next.js Admin Dashboard Patterns

> Supplement document — livemask-admin Next.js patterns
> Source: Next.js docs + livemask-admin implementation

## Route Organization

```
app/
  (dashboard)/              # Route group — shared layout
    layout.tsx              # Sidebar + header layout
    page.tsx                # Default dashboard page
    nodes/
      page.tsx              # Node list
      [id]/
        page.tsx            # Node detail
    users/
      page.tsx              # User list
      [id]/
        page.tsx            # User detail
    settings/
      page.tsx              # System settings
  api/                      # API routes (proxy to backend)
    [...path]/
      route.ts              # Catch-all proxy
  auth/
    login/
      page.tsx              # Login page
    layout.tsx              # Auth layout (no sidebar)
```

## Backend Proxy Pattern

```typescript
// app/api/[...path]/route.ts
export async function GET(
  req: NextRequest,
  { params }: { params: { path: string[] } }
) {
  const backendUrl = process.env.NEXT_PUBLIC_API_BASE || 'http://backend:8080';
  const path = params.path.join('/');
  const url = new URL(path, backendUrl);
  url.search = req.nextUrl.search;

  const res = await fetch(url, {
    headers: {
      'Authorization': req.headers.get('Authorization') || '',
      'Content-Type': 'application/json',
    },
  });

  return new Response(res.body, {
    status: res.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
```

## State Management with Provider + Zustand

```typescript
// lib/stores/auth-store.ts
import { create } from 'zustand';

interface AuthState {
  token: string | null;
  user: User | null;
  login: (token: string) => void;
  logout: () => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  token: null,
  user: null,
  login: (token: string) => set({ token }),
  logout: () => set({ token: null, user: null }),
}));
```
"""

_GO_CONCURRENCY = """# Go Concurrency Patterns for livemask-backend

> Supplement document — concurrency patterns used in livemask
> Source: Go blog + Effective Go + livemask-backend codebase

## Worker Pool Pattern (Asynq)

```go
// Asynq server handles worker pool automatically
srv := asynq.NewServer(redisClient, asynq.Config{
    Concurrency: 10, // 10 concurrent workers
    Queues: map[string]int{
        "critical": 6,
        "default":  3,
        "low":      1,
    },
})
```

## Fan-Out Pattern (Parallel Processing)

```go
func processNodes(ctx context.Context, nodes []Node) error {
    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(10) // max 10 concurrent

    for _, node := range nodes {
        node := node // capture
        g.Go(func() error {
            return processNode(ctx, node)
        })
    }
    return g.Wait()
}
```

## Graceful Shutdown

```go
ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer cancel()

srv := &http.Server{Addr: ":8080", Handler: router}
go srv.ListenAndServe()

<-ctx.Done()
shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
defer shutdownCancel()
srv.Shutdown(shutdownCtx)
```

## Rate Limiting

```go
limiter := rate.NewLimiter(rate.Limit(100), 1) // 100 req/s
if !limiter.Allow() {
    return &RateLimitError{RetryAfter: time.Second}
}
```

## Context Propagation

```go
// Always pass context through the entire call chain
func (s *Service) GetUser(ctx context.Context, id uuid.UUID) (*User, error) {
    // Context carries: trace ID, auth info, deadline, cancellation
    return s.repo.FindByID(ctx, id)
}
```
"""

_DOCKER_DEV = """# Docker Development Stack

> Supplement document — local Docker Compose stack for livemask development
> Source: livemask-ci-cd docker-compose.yml

## Service Layout

| Service | Container | Port Mapping | Dependencies |
|---------|-----------|-------------|--------------|
| Backend API | livemask-local-backend-1 | 18080→8080 | postgres, redis |
| Admin UI | livemask-local-admin-1 | 3001→3000 | backend |
| Website | livemask-local-website-1 | 3002→5173 | backend |
| NodeAgent | livemask-local-nodeagent-1 | 19090→9100 | backend |
| Job Service | livemask-local-job-service-1 | 19191→19191 | backend, postgres, redis |
| PostgreSQL | livemask-local-postgres-1 | 15432→5432 | — |
| Redis | livemask-local-redis-1 | 16379→6379 | — |

## Network

All services are on a shared Docker network (`livemask-local-network`) for internal DNS resolution.
Services refer to each other by container name (e.g. `http://livemask-local-backend-1:8080`).

## Building

```bash
# Build all services
cd livemask-ci-cd && docker compose build

# Start all services
docker compose up -d

# Check status
docker compose ps

# View logs
docker compose logs -f livemask-local-backend-1

# Stop all
docker compose down
```

## Data Persistence

- PostgreSQL data: `pgdata` Docker volume
- Redis data: `redis-data` Docker volume
- To reset: `docker compose down -v` (destroys volumes)
"""


# ── Commands ─────────────────────────────────────────────────────────

def cmd_build(args: list[str]) -> int:
    """shared_knowledge.py build [--all] [--skip-github]"""
    idx = {"version": 2, "entries": {}, "sources": {}, "last_build": ""}
    skip_github = "--skip-github" in args

    print(json.dumps({"status": "building", "sources": []}))

    # Source 1: Local memory
    t0 = time.time()
    _index_local_memory(idx)
    t1 = time.time()
    print(json.dumps({"source": "local_memory", "entries": len([k for k in idx["entries"] if k.startswith("local_memory:")]), "elapsed": round(t1-t0, 2)}))

    # Source 2: Docs
    t0 = time.time()
    _index_docs(idx)
    t1 = time.time()
    print(json.dumps({"source": "docs", "entries": len([k for k in idx["entries"] if k.startswith("docs:")]), "elapsed": round(t1-t0, 2)}))

    # Source 3: GitHub (skip if --skip-github)
    if not skip_github:
        t0 = time.time()
        _index_github(idx)
        t1 = time.time()
        print(json.dumps({"source": "github", "entries": len([k for k in idx["entries"] if k.startswith("github:")]), "elapsed": round(t1-t0, 2)}))
    else:
        print(json.dumps({"source": "github", "skipped": True}))

    # Source 4: Open source
    t0 = time.time()
    _index_open_source(idx)
    t1 = time.time()
    print(json.dumps({"source": "open_source", "entries": len([k for k in idx["entries"] if k.startswith("open_source:")]), "elapsed": round(t1-t0, 2)}))

    # Source 5: Supplement
    t0 = time.time()
    _index_supplement(idx)
    t1 = time.time()
    print(json.dumps({"source": "supplement", "entries": len([k for k in idx["entries"] if k.startswith("supplement:")]), "elapsed": round(t1-t0, 2)}))

    idx["last_build"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _save_index(idx)

    total = len(idx["entries"])
    print(json.dumps({"status": "ok", "action": "build", "total_entries": total,
                       "sources": {k: v["count"] for k, v in sorted(idx["sources"].items())}}))
    return 0


def cmd_search(args: list[str]) -> int:
    """shared_knowledge.py search <query> [--source S] [--limit N]"""
    if not args:
        print(json.dumps({"error": "usage: search <query> [--source S] [--limit N]"}))
        return 1

    query = ""
    source_filter = ""
    limit = 15

    i = 0
    while i < len(args):
        if args[i] == "--source" and i + 1 < len(args):
            source_filter = args[i + 1]; i += 2
        elif args[i] == "--limit" and i + 1 < len(args):
            try: limit = int(args[i + 1])
            except ValueError: pass
            i += 2
        elif not query:
            query = args[i]; i += 1
        else:
            i += 1

    if not query:
        print(json.dumps({"error": "query required"}))
        return 1

    idx = _load_index()
    entries = idx.get("entries", {})
    ql = query.lower()

    results = []
    for key, entry in entries.items():
        # Source filter
        if source_filter and entry.get("source") != source_filter:
            continue

        # Build searchable text
        searchable = f"{entry.get('title', '')} {entry.get('content', '')} {' '.join(entry.get('tags', []))}"
        sl = searchable.lower()

        # Scoring
        score = 0
        words = ql.split()
        for w in words:
            count = sl.count(w)
            score += count * 10

        if ql in sl:
            score += 50

        for word in words:
            if word in sl:
                score += 5

        # Tag bonus
        for tag in entry.get("tags", []):
            if ql in tag.lower():
                score += 20

        if score > 0:
            results.append({
                "key": key,
                "source": entry.get("source", ""),
                "source_type": entry.get("source_type", ""),
                "id": entry.get("id", ""),
                "title": entry.get("title", ""),
                "match_snippet": _snippet(entry.get("content", ""), query),
                "tags": entry.get("tags", [])[:5],
                "url": entry.get("url", ""),
                "score": score,
            })

    results.sort(key=lambda x: -x["score"])
    results = results[:limit]

    # Summary by source
    source_counts = Counter(r["source"] for r in results)

    print(json.dumps({
        "status": "ok",
        "query": query,
        "source_filter": source_filter or "all",
        "total_matches": len(results),
        "by_source": dict(source_counts),
        "results": results,
    }, indent=2, ensure_ascii=False))
    return 0


def _snippet(content: str, query: str) -> str:
    """Extract a relevant snippet around the query match."""
    if not content:
        return ""
    ql = query.lower()
    cl = content.lower()
    pos = cl.find(ql)
    if pos < 0:
        return content[:150] + "..."
    start = max(0, pos - 60)
    end = min(len(content), pos + len(query) + 100)
    snippet = content[start:end].strip()
    if start > 0:
        snippet = "..." + snippet
    if end < len(content):
        snippet = snippet + "..."
    return snippet[:250]


def cmd_get(args: list[str]) -> int:
    """shared_knowledge.py get <source>:<id>"""
    if not args:
        print(json.dumps({"error": "usage: get <source>:<id> [--full]"}))
        return 1

    key = args[0]
    full = "--full" in args

    idx = _load_index()
    entries = idx.get("entries", {})

    if key not in entries:
        # Try partial match
        matches = [k for k in entries if key in k]
        if matches:
            key = matches[0]
        else:
            print(json.dumps({"error": f"entry not found: {key}"}))
            return 1

    entry = entries[key]
    if full:
        print(json.dumps(entry, indent=2, ensure_ascii=False))
    else:
        # Truncate content for display
        display = {k: v for k, v in entry.items()}
        if len(str(display.get("content", ""))) > 500:
            display["content"] = display["content"][:500] + "..."
        print(json.dumps(display, indent=2, ensure_ascii=False))
    return 0


def cmd_sources(args: list[str]) -> int:
    """shared_knowledge.py sources"""
    idx = _load_index()
    entries = idx.get("entries", {})

    source_stats = {}
    type_stats = {}
    tag_counter = Counter()

    for key, entry in entries.items():
        src = entry.get("source", "unknown")
        stype = entry.get("source_type", "unknown")
        source_stats[src] = source_stats.get(src, 0) + 1
        type_stats[f"{src}:{stype}"] = type_stats.get(f"{src}:{stype}", 0) + 1
        for tag in entry.get("tags", []):
            tag_counter[tag] += 1

    print(json.dumps({
        "status": "ok",
        "total_entries": len(entries),
        "last_build": idx.get("last_build", ""),
        "sources": source_stats,
        "source_types": dict(sorted(type_stats.items(), key=lambda x: -x[1])),
        "top_tags": dict(tag_counter.most_common(20)),
    }, indent=2, ensure_ascii=False))
    return 0


def cmd_sync_github(args: list[str]) -> int:
    """shared_knowledge.py sync-github [--repo R] [--all]"""
    # Re-index GitHub data into existing index
    idx = _load_index()

    # Remove old GitHub entries
    idx["entries"] = {k: v for k, v in idx.get("entries", {}).items()
                       if not k.startswith("github:")}

    _index_github(idx)
    idx["last_build"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _save_index(idx)

    gh_count = len([k for k in idx["entries"] if k.startswith("github:")])
    print(json.dumps({
        "status": "ok", "action": "sync-github",
        "github_entries": gh_count,
        "total_entries": len(idx["entries"]),
    }))
    return 0


def cmd_sync_upstream(args: list[str]) -> int:
    """shared_knowledge.py sync-upstream"""
    # Refresh upstream data (mostly static, but re-fetches GitHub repo info)
    idx = _load_index()

    idx["entries"] = {k: v for k, v in idx.get("entries", {}).items()
                       if not k.startswith("open_source:")}

    _index_open_source(idx)
    idx["last_build"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _save_index(idx)

    os_count = len([k for k in idx["entries"] if k.startswith("open_source:")])
    print(json.dumps({
        "status": "ok", "action": "sync-upstream",
        "open_source_entries": os_count,
        "total_entries": len(idx["entries"]),
    }))
    return 0


def cmd_stats(args: list[str]) -> int:
    """shared_knowledge.py stats"""
    idx = _load_index()
    entries = idx.get("entries", {})

    source_stats = {}
    for key, entry in entries.items():
        src = entry.get("source", "unknown")
        source_stats[src] = source_stats.get(src, 0) + 1

    print(json.dumps({
        "total_entries": len(entries),
        "last_build": idx.get("last_build", "never"),
        "sources": source_stats,
        "status": "ok",
    }, indent=2))
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
        "build": cmd_build,
        "search": cmd_search,
        "get": cmd_get,
        "sources": cmd_sources,
        "sync-github": cmd_sync_github,
        "sync-upstream": cmd_sync_upstream,
        "stats": cmd_stats,
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
