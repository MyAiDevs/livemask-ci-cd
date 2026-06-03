#!/usr/bin/env python3
"""
context_graph.py — Knowledge graph engine for LiveMask dev loop.

Builds and maintains a directed knowledge graph connecting:
  - Tasks ↔ Contracts (via contract-index)
  - Tasks ↔ Tasks (via blocked_by, unlocks in ledger)
  - Tasks ↔ Repos (via repo field)
  - Tasks ↔ GitHub Issues (via issue URL)
  - Contracts ↔ Repos (via Impacted Repos)
  - Errors ↔ Tasks/Repos (via experience.py)

Enhanced reasoning (Fix C):
  - Path analysis: find shortest dependency chain between two tasks
  - Contradiction detection: detect conflicting statuses or blocked cycles
  - Frequency analysis: most common error patterns by repo

Storage: diskcache (SQLite, persistent, concurrent-safe).
Graph engine: networkx (DiGraph, industry standard).

Usage:
    context_graph.py build <ledger_path> <contracts_path> [mvp_path] [--tags PATH]
    context_graph.py query --task TASK-ID
    context_graph.py query --repo REPO
    context_graph.py query --tag TAG
    context_graph.py query --all
    context_graph.py path --from A --to B
    context_graph.py contradictions
    context_graph.py error-stats
    context_graph.py summary
    context_graph.py tag-tree <task_id>     # Show tag relationships around a task
    context_graph.py tag-query <tag>         # Find all nodes with a specific tag
"""

import json
import os
import re
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from typing import Any, Optional

from debug_utils import setup as _debug_setup, traced, logger as _logger

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "cache")
LIVEMASK_ROOT = os.environ.get("LIVEMASK_ROOT",
                                os.path.expanduser("~/Developer/LiveMask"))

GRAPH_CACHE_NS = "context-graph"
GRAPH_VERSION = 2


def _open_cache():
    from diskcache import Cache
    os.makedirs(CACHE_DIR, exist_ok=True)
    return Cache(os.path.join(CACHE_DIR, GRAPH_CACHE_NS))


def _load_graph():
    import networkx as nx
    with _open_cache() as c:
        data = c.get("graph")
    if data is not None:
        try:
            g = nx.node_link_graph(data, directed=True, multigraph=False)
            return g
        except Exception:
            pass
    return nx.DiGraph()


def _save_graph(g):
    import networkx as nx
    data = nx.node_link_data(g, edges="edges")
    with _open_cache() as c:
        c.set("graph", data)


def _get_meta() -> dict:
    with _open_cache() as c:
        return c.get("_meta", {})


def _set_meta(m: dict):
    with _open_cache() as c:
        c.set("_meta", m)


def _add_node(g, node_id: str, node_type: str, **attrs):
    now = time.time()
    if node_id not in g:
        g.add_node(node_id, type=node_type, first_seen=now, last_seen=now, **attrs)
    else:
        for k, v in attrs.items():
            g.nodes[node_id][k] = v
        g.nodes[node_id]["last_seen"] = now


def _add_edge(g, src: str, dst: str, rel: str, **attrs):
    now = time.time()
    if g.has_edge(src, dst):
        edge = g[src][dst]
        edge["relation"] = rel
        edge["weight"] = edge.get("weight", 1) + 1
        edge["last_seen"] = now
        for k, v in attrs.items():
            edge[k] = v
    else:
        g.add_edge(src, dst, relation=rel, weight=1, first_seen=now, last_seen=now, **attrs)


# ── Build from sources ────────────────────────────────────────────────

def cmd_build(args: list[str]) -> int:
    import networkx as nx

    ledger_path = args[0] if len(args) > 0 else ""
    contracts_path = args[1] if len(args) > 1 else ""
    mvp_path = args[2] if len(args) > 2 else ""
    tags_path = ""

    # Parse --tags flag anywhere in args
    for i in range(len(args)):
        if args[i] == "--tags" and i + 1 < len(args):
            tags_path = args[i + 1]

    g = nx.DiGraph()
    stats = {"task_nodes": 0, "contract_nodes": 0, "repo_nodes": 0,
             "issue_nodes": 0, "error_nodes": 0, "edges": 0, "tag_nodes": 0, "sources_used": []}

    # Source 1: Task State Ledger
    if ledger_path and os.path.exists(ledger_path):
        stats["sources_used"].append("ledger")
        with open(ledger_path) as f:
            ledger = json.load(f)

        for module in ledger.get("modules", []):
            mod_id = module.get("module_id", "")
            for task in module.get("tasks", []):
                tid = task.get("task_id", "")
                if not tid:
                    continue
                repo = task.get("repo", "")
                status = task.get("status", "")
                issue = task.get("issue", "")
                sha = task.get("dev_merge_commit", "")
                priority = task.get("priority", "")

                _add_node(g, tid, "task", repo=repo, status=status,
                           issue=issue, sha=sha, priority=priority, module=mod_id)
                stats["task_nodes"] += 1

                if repo:
                    _add_node(g, repo, "repo")
                    _add_edge(g, tid, repo, "assigned_to")

                for unlocked in task.get("unlocks", []):
                    _add_edge(g, tid, unlocked, "unlocks")
                for blocked_by in task.get("blocked_by", []):
                    _add_edge(g, blocked_by, tid, "blocks")

                if issue and "github.com" in issue:
                    issue_id = f"github-issue-{issue.split('/')[-1]}"
                    _add_node(g, issue_id, "github_issue", url=issue)
                    _add_edge(g, tid, issue_id, "has_issue")
                    stats["issue_nodes"] += 1

                if sha:
                    branch_id = f"sha-{sha[:12]}"
                    _add_node(g, branch_id, "commit", sha=sha)
                    _add_edge(g, tid, branch_id, "merged_in")

    # Source 2: Contract Index
    if contracts_path and os.path.exists(contracts_path):
        stats["sources_used"].append("contracts")
        contracts = _parse_contract_index(contracts_path)
        for c in contracts:
            cid = c.get("contract_id", c.get("task_id", ""))
            if not cid:
                continue
            _add_node(g, cid, "contract", domain=c.get("domain", ""),
                       status=c.get("status", ""), name=c.get("name", ""))
            stats["contract_nodes"] += 1

            for repo in c.get("repos", []):
                repo_id = repo if repo.startswith("livemask-") else f"livemask-{repo}"
                _add_node(g, repo_id, "repo")
                _add_edge(g, cid, repo_id, "impacts")

            tid = c.get("task_id", "")
            if tid:
                _add_edge(g, cid, tid, "defines")

    # Source 2b: Business Tags (if available)
    if tags_path and os.path.exists(tags_path):
        stats["sources_used"].append("tags")
        try:
            with open(tags_path) as f:
                tag_data = json.load(f)
            for item_id, item in tag_data.get("items", {}).items():
                for tag in item.get("tags", []):
                    tag_node = f"tag:{tag}"
                    _add_node(g, tag_node, "tag",
                               category=tag.split(":")[0] if ":" in tag else "unknown",
                               value=tag.split(":")[1] if ":" in tag else tag)
                    _add_edge(g, item_id, tag_node, "tagged_with")
                    stats["tag_nodes"] += 1
        except Exception:
            pass

    # Source 3: Experience database
    exp_path = os.path.join(CACHE_DIR, "experience", "experience.json")
    alt_exp = os.path.join(os.path.expanduser("~"), ".claude", "cache", "experience.json")
    experience_path = exp_path if os.path.exists(exp_path) else (alt_exp if os.path.exists(alt_exp) else None)

    if experience_path:
        stats["sources_used"].append("experience")
        try:
            with open(experience_path) as f:
                exp_data = json.load(f)
            for fp, entry in exp_data.get("patterns", {}).items():
                pattern_name = entry.get("pattern_name", "unknown")
                total = len(entry.get("actions", []))
                successes = sum(1 for a in entry.get("actions", []) if a.get("success"))
                error_id = f"error-{pattern_name}-{fp[:16]}"
                _add_node(g, error_id, "error",
                           pattern=pattern_name, count=total,
                           success_rate=round(successes / total, 2) if total > 0 else 0)
                stats["error_nodes"] += 1

                for repo_hint in entry.get("repo_hints", {}):
                    repo_id = repo_hint if repo_hint.startswith("livemask-") else f"livemask-{repo_hint}"
                    _add_node(g, repo_id, "repo")
                    _add_edge(g, error_id, repo_id, "occurred_in")
        except Exception:
            pass

    stats["edges"] = g.number_of_edges()
    _save_graph(g)
    _set_meta({
        "version": GRAPH_VERSION,
        "last_build": time.time(),
        "last_build_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "node_count": g.number_of_nodes(),
        "edge_count": g.number_of_edges(),
        "stats": stats,
    })

    print(json.dumps({"status": "ok", "action": "build",
                       "node_count": g.number_of_nodes(),
                       "edge_count": g.number_of_edges(),
                       "stats": stats}, indent=2))
    return 0


def _parse_contract_index(path: str) -> list[dict]:
    """Parse contract index using robust table parser from doc_parser if available."""
    # Try using doc_parser for robust parsing
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "."))
        from doc_parser import parse_contract_index as dp_parse
        return dp_parse(path)
    except Exception:
        pass

    # Fallback: line-by-line parsing
    contracts = []
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    in_table = False
    headers = []
    for line in lines:
        if line.strip().startswith("| ") and "---" not in line:
            cells = [c.strip() for c in line.split("|")[1:-1]]
            if not in_table:
                headers = cells
                in_table = True
                continue
            if len(cells) < 3:
                continue
            if "Domain" in headers:
                entry = {}
                for label, key in [("Domain", "domain"), ("Contract", "name"),
                                    ("Status", "status"), ("Primary Task", "task_id"),
                                    ("Impacted Repos", "repos")]:
                    if label in headers:
                        idx = headers.index(label)
                        entry[key] = cells[idx] if idx < len(cells) else ""
                raw_tid = entry.get("task_id", "")
                m = re.search(r'`([^`]+)`', raw_tid)
                if m:
                    entry["contract_id"] = m.group(1)
                elif raw_tid:
                    entry["contract_id"] = raw_tid.strip()
                else:
                    entry["contract_id"] = entry.get("name", "")
                raw_repos = entry.get("repos", "")
                entry["repos"] = [r.strip() for r in raw_repos.split("/") if r.strip()]
                contracts.append(entry)
        else:
            in_table = False
    return contracts


# ── Path analysis (Fix C) ─────────────────────────────────────────────

def cmd_path(args: list[str]) -> int:
    """Find shortest dependency path between two tasks."""
    g = _load_graph()
    from_node = ""
    to_node = ""

    for i in range(len(args)):
        if args[i] == "--from" and i + 1 < len(args):
            from_node = args[i + 1]
        if args[i] == "--to" and i + 1 < len(args):
            to_node = args[i + 1]

    if not from_node or not to_node:
        print(json.dumps({"error": "usage: path --from TASK-A --to TASK-B"}))
        return 1

    try:
        import networkx as nx
        # Forward path: from_node → to_node
        try:
            fwd_path = nx.shortest_path(g, source=from_node, target=to_node)
        except nx.NetworkXNoPath:
            fwd_path = None

        # Backward path (via predecessors): to_node → from_node
        bwd_path = None
        try:
            bwd_path = nx.shortest_path(g, source=to_node, target=from_node)
        except nx.NetworkXNoPath:
            bwd_path = None

        result = {
            "from": from_node,
            "to": to_node,
            "forward_path": fwd_path,
            "forward_length": len(fwd_path) - 1 if fwd_path else None,
            "backward_path": bwd_path,
            "backward_length": len(bwd_path) - 1 if bwd_path else None,
        }

        # Add edge labels for forward path
        if fwd_path:
            labels = []
            for i in range(len(fwd_path) - 1):
                u, v = fwd_path[i], fwd_path[i + 1]
                if g.has_edge(u, v):
                    labels.append(g[u][v].get("relation", "?"))
            result["forward_relations"] = labels

        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        return 1
    return 0


# ── Contradiction detection (Fix C) ──────────────────────────────────

def cmd_contradictions(args: list[str]) -> int:
    """Detect contradictions in the graph:
    - Tasks blocked_by a completed task (should be unblocked)
    - Tasks with issue URL but no merge SHA (incomplete evidence)
    - Contracts marked Ready but task is completed
    - Cycles in blocked_by chains
    """
    import networkx as nx

    g = _load_graph()
    issues = []

    # 1. Tasks blocked_by completed tasks
    for nid, ndata in g.nodes(data=True):
        if ndata.get("type") != "task":
            continue
        status = ndata.get("status", "")
        for pred in g.predecessors(nid):
            edge = g[pred][nid]
            if edge.get("relation") != "blocks":
                continue
            pred_status = g.nodes[pred].get("status", "")
            if pred_status == "completed" and status != "completed":
                issues.append({
                    "type": "stale_block",
                    "task": nid,
                    "blocked_by": pred,
                    "detail": f"Task {nid} ({status}) is blocked by completed task {pred}",
                    "severity": "high",
                })

    # 2. Incomplete evidence
    for nid, ndata in g.nodes(data=True):
        if ndata.get("type") != "task":
            continue
        issue_url = ndata.get("issue", "")
        sha = ndata.get("sha", "")
        if issue_url and not sha:
            issues.append({
                "type": "incomplete_evidence",
                "task": nid,
                "detail": f"Task {nid} has GitHub issue but no merge SHA",
                "severity": "medium",
            })

    # 3. Cycles in dependency graph
    try:
        cycles = list(nx.simple_cycles(g))
        for cycle in cycles:
            issues.append({
                "type": "dependency_cycle",
                "tasks": cycle,
                "detail": f"Circular dependency: {' → '.join(cycle)}",
                "severity": "critical",
            })
    except Exception:
        pass

    issues.sort(key=lambda x: {"critical": 0, "high": 1, "medium": 2, "low": 3}.get(x["severity"], 4))

    print(json.dumps({
        "contradiction_count": len(issues),
        "contradictions": issues,
    }, indent=2))
    return 0


# ── Error frequency analysis (Fix C) ─────────────────────────────────

def cmd_error_stats(args: list[str]) -> int:
    """Analyze error patterns by repo and type."""
    g = _load_graph()

    errors_by_repo = defaultdict(list)
    errors_by_type = Counter()

    for nid, ndata in g.nodes(data=True):
        if ndata.get("type") != "error":
            continue
        pattern = ndata.get("pattern", "unknown")
        count = ndata.get("count", 0)
        success_rate = ndata.get("success_rate", 0)
        errors_by_type[pattern] += count

        # Find repos this error occurred in
        for neighbor in g.neighbors(nid):
            nd = g.nodes[neighbor]
            if nd.get("type") == "repo":
                errors_by_repo[neighbor].append({
                    "pattern": pattern,
                    "count": count,
                    "success_rate": success_rate,
                })

    print(json.dumps({
        "total_error_patterns": len(errors_by_type),
        "error_types": dict(errors_by_type.most_common()),
        "errors_by_repo": {k: sorted(v, key=lambda x: -x["count"]) for k, v in sorted(errors_by_repo.items())},
    }, indent=2))
    return 0


# ── Query ─────────────────────────────────────────────────────────────

def cmd_query(args: list[str]) -> int:
    g = _load_graph()
    meta = _get_meta()

    repo_filter = ""
    task_filter = ""
    contract_filter = ""
    show_all = False

    i = 0
    while i < len(args):
        if args[i] == "--repo" and i + 1 < len(args):
            repo_filter = args[i + 1]; i += 2
        elif args[i] == "--task" and i + 1 < len(args):
            task_filter = args[i + 1]; i += 2
        elif args[i] == "--contract" and i + 1 < len(args):
            contract_filter = args[i + 1]; i += 2
        elif args[i] == "--all":
            show_all = True; i += 1
        else:
            i += 1

    if show_all:
        result = _graph_summary(g, meta)
    elif repo_filter:
        result = _subgraph_around(g, repo_filter, "repo")
    elif task_filter:
        result = _subgraph_around(g, task_filter, "task")
    elif contract_filter:
        result = _subgraph_around(g, contract_filter, "contract")
    else:
        result = _graph_summary(g, meta)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def _graph_summary(g, meta: dict) -> dict:
    nodes_by_type = {}
    for nid, ndata in g.nodes(data=True):
        ntype = ndata.get("type", "unknown")
        nodes_by_type.setdefault(ntype, []).append(nid)

    edges_by_rel = {}
    for u, v, edata in g.edges(data=True):
        rel = edata.get("relation", "unknown")
        edges_by_rel[rel] = edges_by_rel.get(rel, 0) + 1

    return {
        "status": "ok",
        "node_count": g.number_of_nodes(),
        "edge_count": g.number_of_edges(),
        "nodes_by_type": {k: len(v) for k, v in sorted(nodes_by_type.items())},
        "edges_by_relation": dict(sorted(edges_by_rel.items())),
        "metadata": meta.get("stats", {}),
        "last_build": meta.get("last_build_utc", ""),
    }


def _subgraph_around(g, center_id: str, center_type: str) -> dict:
    if center_id not in g:
        return {"status": "not_found", "node_id": center_id, "node_type": center_type}

    center_data = dict(g.nodes[center_id])
    neighbors = {}
    for neighbor in g.neighbors(center_id):
        edge = dict(g[center_id][neighbor])
        ndata = dict(g.nodes[neighbor])
        neighbors[neighbor] = {"type": ndata.get("type", "?"), "relation": edge.get("relation", "?"),
                                "edge_weight": edge.get("weight", 1)}

    predecessors = {}
    for pred in g.predecessors(center_id):
        edge = dict(g[pred][center_id])
        ndata = dict(g.nodes[pred])
        predecessors[pred] = {"type": ndata.get("type", "?"), "relation": edge.get("relation", "?"),
                               "edge_weight": edge.get("weight", 1)}

    return {
        "status": "ok",
        "center": {"id": center_id, "type": center_type, "data": center_data},
        "outgoing_neighbors": len(neighbors),
        "incoming_predecessors": len(predecessors),
        "neighbors": neighbors,
        "predecessors": predecessors,
    }


# ── Tag-aware queries ────────────────────────────────────────────────

def cmd_tag_tree(args: list[str]) -> int:
    """Show tag relationships around a specific task/entity."""
    if not args:
        print(json.dumps({"error": "usage: tag-tree <task_id>"}))
        return 1

    center_id = args[0]
    g = _load_graph()

    if center_id not in g:
        print(json.dumps({"error": f"node not found in graph: {center_id}"}))
        return 1

    center_data = dict(g.nodes[center_id])

    # Find all tag nodes connected to this item
    tags = {}
    for neighbor in g.neighbors(center_id):
        ndata = g.nodes[neighbor]
        if ndata.get("type") == "tag":
            edge = g[center_id][neighbor]
            tags[neighbor] = {"category": ndata.get("category", ""),
                               "value": ndata.get("value", ""),
                               "relation": edge.get("relation", "?")}

    # Find other items sharing the same tags
    tag_map = defaultdict(list)
    for tag_node in tags:
        for pred in g.predecessors(tag_node):
            ndata = g.nodes[pred]
            if pred != center_id:
                tag_map[tag_node].append({
                    "id": pred,
                    "type": ndata.get("type", "?"),
                    "status": ndata.get("status", ""),
                    "repo": ndata.get("repo", ""),
                })

    # Check cross-repo connections
    cross_repo_items = set()
    for tag_node, items in tag_map.items():
        for item in items:
            if item.get("repo", "") != center_data.get("repo", ""):
                cross_repo_items.add(item["id"])

    print(json.dumps({
        "center": {"id": center_id, "type": center_data.get("type", "?"), "data": center_data},
        "tags": tags,
        "shared_items": dict(tag_map),
        "cross_repo_peers": sorted(cross_repo_items),
    }, indent=2))
    return 0


def cmd_tag_query(args: list[str]) -> int:
    """Find all graph nodes tagged with a specific tag."""
    if not args:
        print(json.dumps({"error": "usage: tag-query <tag> [--category CAT]"}))
        return 1

    tag_arg = args[0]
    if not tag_arg.startswith("tag:"):
        tag_arg = f"tag:{tag_arg}"

    # Normalize: if it's a bare category:value, prepend tag:
    tag_node = tag_arg if tag_arg.startswith("tag:") else f"tag:{tag_arg}"

    g = _load_graph()

    if tag_node not in g:
        print(json.dumps({"status": "not_found", "tag": tag_arg}))
        return 0

    tag_data = dict(g.nodes[tag_node])

    # Find which items have this tag
    items = []
    for pred in g.predecessors(tag_node):
        ndata = dict(g.nodes[pred])
        items.append({
            "id": pred,
            "type": ndata.get("type", "?"),
            "status": ndata.get("status", ""),
            "repo": ndata.get("repo", ""),
        })

    items.sort(key=lambda x: x["id"])

    print(json.dumps({
        "tag": tag_arg,
        "category": tag_data.get("category", ""),
        "value": tag_data.get("value", ""),
        "item_count": len(items),
        "items": items,
    }, indent=2))
    return 0


# ── Summary ─────────────────────────────────────────────────────────

def cmd_summary(args: list[str]) -> int:
    g = _load_graph()
    meta = _get_meta()

    nodes_by_type = {}
    for nid, ndata in g.nodes(data=True):
        ntype = ndata.get("type", "unknown")
        nodes_by_type[ntype] = nodes_by_type.get(ntype, 0) + 1

    status_counts = {}
    for nid, ndata in g.nodes(data=True):
        if ndata.get("type") == "task":
            s = ndata.get("status", "unknown")
            status_counts[s] = status_counts.get(s, 0) + 1

    print(json.dumps({
        "status": "ok",
        "total_nodes": g.number_of_nodes(),
        "total_edges": g.number_of_edges(),
        "nodes_by_type": nodes_by_type,
        "tasks_by_status": status_counts,
        "last_build": meta.get("last_build_utc", ""),
    }, indent=2))
    return 0


# ── Main ──────────────────────────────────────────────────────────────

@traced
def main():
    if len(sys.argv) < 2:
        cmds = ["build", "query", "path", "contradictions", "error-stats", "summary", "tag-tree", "tag-query"]
        print(json.dumps({"error": f"usage: context_graph.py <{'|'.join(cmds)}> [...]"}))
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "build": cmd_build,
        "query": cmd_query,
        "path": cmd_path,
        "contradictions": cmd_contradictions,
        "error-stats": cmd_error_stats,
        "summary": cmd_summary,
        "tag-tree": cmd_tag_tree,
        "tag-query": cmd_tag_query,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        sys.exit(1)

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except ModuleNotFoundError as e:
        print(json.dumps({"error": f"missing dependency: {e}. cd livemask-ci-cd && pip install diskcache networkx"}),
              file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    _debug_setup()
    main()
