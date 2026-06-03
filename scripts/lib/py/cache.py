#!/usr/bin/env python3
"""
cache.py — Persistent KV cache with diskcache backend.

Replaces the old JSON-file-based cache with SQLite-backed diskcache:
  - Transaction-safe concurrent writes
  - Native TTL expiration
  - LRU eviction (size-limited)
  - Thread/process safe

Compatible CLI interface with the old cache.py.

Pure Python. Dependencies: diskcache (stdlib + zero C extensions).

Usage:
    cache.py set <namespace> <key> <value> [--ttl N]
    cache.py get <namespace> <key>
    cache.py list <namespace> [--prefix P]
    cache.py del <namespace> <key>
    cache.py incr <namespace> <key> [--delta N]
    cache.py stats

Output: JSON to stdout, exit code 0=ok 1=not_found/error
"""

import json
import os
import sys
import time
from contextlib import contextmanager

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "cache")

# ── diskcache-backed namespaces ─────────────────────────────────────────
# Each namespace becomes a separate diskcache Cache in CACHE_DIR.
# diskcache handles TTL, LRU, and concurrent access automatically.

def _open_ns(namespace: str):
    """Return a diskcache Cache for the given namespace."""
    from diskcache import Cache
    safe = namespace.replace("/", "_").replace("..", "_").replace("~", "_")
    path = os.path.join(CACHE_DIR, safe)
    return Cache(path)


# ── CLI Commands ────────────────────────────────────────────────────────

def cmd_set(args: list[str]) -> int:
    if len(args) < 3:
        print(json.dumps({"error": "usage: set <namespace> <key> <value> [--ttl N]"}))
        return 1
    namespace, key, value = args[0], args[1], args[2]
    ttl = None
    i = 3
    while i < len(args):
        if args[i] == "--ttl" and i + 1 < len(args):
            try:
                ttl = int(args[i + 1])
            except ValueError:
                ttl = None
            i += 2
        else:
            i += 1

    with _open_ns(namespace) as cache:
        cache.set(key, value, expire=ttl)

    print(json.dumps({"status": "ok", "namespace": namespace, "key": key,
                       "ttl": ttl, "value_truncated": str(value)[:100] if len(str(value)) > 100 else str(value)}))
    return 0


def cmd_get(args: list[str]) -> int:
    if len(args) < 2:
        print(json.dumps({"error": "usage: get <namespace> <key>"}))
        return 1
    namespace, key = args[0], args[1]

    with _open_ns(namespace) as cache:
        value = cache.get(key)

    if value is None:
        print(json.dumps({"status": "not_found", "namespace": namespace, "key": key}))
        return 1

    print(json.dumps({"status": "ok", "namespace": namespace, "key": key,
                       "value": str(value)}))
    return 0


def cmd_list(args: list[str]) -> int:
    if not args:
        print(json.dumps({"error": "usage: list <namespace> [--prefix P]"}))
        return 1

    namespace = args[0]
    prefix = ""
    for i in range(1, len(args)):
        if args[i] == "--prefix" and i + 1 < len(args):
            prefix = args[i + 1]

    keys = []
    with _open_ns(namespace) as cache:
        for key in cache.iterkeys():
            if prefix and not key.startswith(prefix):
                continue
            raw = cache.get(key, default=None, retry=True)
            if raw is not None:
                expire = cache.expire_time(key)
                keys.append({
                    "key": key,
                    "value_truncated": str(raw)[:80],
                    "expire_at": expire,
                    "expired": expire is not None and time.time() > expire,
                })

    print(json.dumps({"namespace": namespace, "key_count": len(keys),
                       "keys": keys}, indent=2, ensure_ascii=False))
    return 0


def cmd_del(args: list[str]) -> int:
    if len(args) < 2:
        print(json.dumps({"error": "usage: del <namespace> <key>"}))
        return 1
    namespace, key = args[0], args[1]

    with _open_ns(namespace) as cache:
        if key in cache:
            del cache[key]
            print(json.dumps({"status": "ok", "namespace": namespace, "key": key, "action": "deleted"}))
        else:
            print(json.dumps({"status": "not_found", "namespace": namespace, "key": key}))
            return 1
    return 0


def cmd_incr(args: list[str]) -> int:
    if len(args) < 2:
        print(json.dumps({"error": "usage: incr <namespace> <key> [--delta N]"}))
        return 1
    namespace, key = args[0], args[1]
    delta = 1
    for i in range(2, len(args)):
        if args[i] == "--delta" and i + 1 < len(args):
            try:
                delta = int(args[i + 1])
            except ValueError:
                delta = 1

    with _open_ns(namespace) as cache:
        try:
            val = cache.get(key, default=0)
            new_val = int(val) + delta
        except (ValueError, TypeError):
            new_val = delta
        cache.set(key, str(new_val))

    print(json.dumps({"status": "ok", "namespace": namespace, "key": key,
                       "value": str(new_val), "delta": delta}))
    return 0


def cmd_stats(args: list[str]) -> int:
    os.makedirs(CACHE_DIR, exist_ok=True)
    namespaces = []
    total_keys = 0

    for entry in sorted(os.listdir(CACHE_DIR)):
        path = os.path.join(CACHE_DIR, entry)
        if not os.path.isdir(path):
            continue
        try:
            from diskcache import Cache
            c = Cache(path)
            kc = len(c)
            c.close()
            namespaces.append({"namespace": entry, "keys": kc, "size_bytes": _dir_size(path)})
            total_keys += kc
        except Exception:
            pass

    print(json.dumps({
        "namespaces": namespaces,
        "total_namespaces": len(namespaces),
        "total_keys": total_keys,
        "backend": "diskcache (SQLite)",
    }, indent=2, ensure_ascii=False))
    return 0


def _dir_size(path: str) -> int:
    total = 0
    try:
        for root, dirs, files in os.walk(path):
            for f in files:
                fp = os.path.join(root, f)
                try:
                    total += os.path.getsize(fp)
                except OSError:
                    pass
    except OSError:
        pass
    return total


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: cache.py <set|get|list|del|incr|stats> [...]"}))
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "set": cmd_set,
        "get": cmd_get,
        "list": cmd_list,
        "del": cmd_del,
        "incr": cmd_incr,
        "stats": cmd_stats,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        sys.exit(1)

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except ModuleNotFoundError as e:
        print(json.dumps({"error": f"missing dependency: {e}. Run: pip install diskcache"}),
              file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
