#!/usr/bin/env python3
"""gh_cache.py — GitHub API caching + incremental sync layer.

File-based JSON cache that wraps gh CLI calls. Reduces API calls by caching
results with configurable TTL. Supports incremental sync via updatedAt tracking.

Usage:
  python3 gh_cache.py list <repo> [--state open] [--ttl 120]
  python3 gh_cache.py view <repo> <issue-num> [--ttl 60]
  python3 gh_cache.py search <query> [--ttl 300]
  python3 gh_cache.py invalidate <repo> [--issue <num>]
  python3 gh_cache.py clear [--older-than 3600]
"""

import json, os, subprocess, sys, time, hashlib
from pathlib import Path
from debug_utils import setup as _debug_setup, traced, logger as _logger

CACHE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "gh-cache")
DEFAULT_TTL = 120
VIEW_TTL = 60
SEARCH_TTL = 300
RATELIMIT_FILE = os.path.join(CACHE_DIR, "_ratelimit.json")
_MAX_CALLS_PER_MINUTE = 10


def _ensure_dir():
    os.makedirs(CACHE_DIR, exist_ok=True)


def _cache_key(ctype, repo, params=None):
    parts = [ctype, repo]
    if params:
        for k in sorted(params.keys()):
            v = params[k]
            if isinstance(v, list):
                v = ",".join(sorted(v))
            parts.append(f"{k}={v}")
    raw = "/".join(parts)
    return hashlib.sha256(raw.encode()).hexdigest()[:24]


def _cache_path(key):
    return os.path.join(CACHE_DIR, f"{key}.json")


def _meta_path(key):
    return os.path.join(CACHE_DIR, f"{key}.meta.json")


def _is_fresh(key, ttl):
    mf = _meta_path(key)
    if not os.path.exists(mf):
        return False
    try:
        with open(mf) as f:
            m = json.load(f)
        return time.time() - m.get("cached_at", 0) < ttl
    except Exception:
        return False


def _write_cache(key, data, ttl):
    cf = _cache_path(key)
    mf = _meta_path(key)
    now = time.time()
    with open(cf, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    with open(mf, "w") as f:
        json.dump({"cached_at": now, "expires_at": now + ttl, "ttl": ttl}, f)


def _read_cache(key):
    cf = _cache_path(key)
    try:
        with open(cf) as f:
            return json.load(f)
    except Exception:
        return None


def _check_ratelimit():
    _ensure_dir()
    now = time.time()
    rl = {"calls": [], "window_start": now}
    try:
        with open(RATELIMIT_FILE) as f:
            rl = json.load(f)
    except Exception:
        pass
    ws = rl.get("window_start", now)
    if now - ws > 60:
        rl["calls"] = []
        rl["window_start"] = now
    active = [t for t in rl.get("calls", []) if now - t < 60]
    if len(active) >= _MAX_CALLS_PER_MINUTE:
        return False
    active.append(now)
    rl["calls"] = active
    with open(RATELIMIT_FILE, "w") as f:
        json.dump(rl, f)
    return True


def _run_gh(args):
    if not _check_ratelimit():
        return -1, "", "RATE_LIMITED"
    try:
        r = subprocess.run(
            ["gh"] + args,
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "GH_PAGER": "", "CLICOLOR": "0"},
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except FileNotFoundError:
        return -1, "", "gh not found"
    except Exception as e:
        return -1, "", str(e)


@traced
def cmd_list(repo, state="open", label="", limit=50, ttl=None):
    if ttl is None:
        ttl = DEFAULT_TTL
    params = {"state": state, "limit": str(limit)}
    if label:
        params["label"] = label
    key = _cache_key("list", repo, params)
    if _is_fresh(key, ttl):
        c = _read_cache(key)
        if c is not None:
            return json.dumps(c)
    args = ["issue", "list", "--repo", repo, "--state", state, "--limit", str(limit),
            "--json", "number,title,state,url,labels,updatedAt,body,createdAt,comments"]
    if label:
        args.extend(["--label", label])
    rc, stdout, stderr = _run_gh(args)
    if rc != 0:
        c = _read_cache(key)
        if c is not None:
            return json.dumps(c)
        return json.dumps({"error": stderr.strip(), "status": "error"})
    try:
        data = json.loads(stdout)
        _write_cache(key, data, ttl)
        return stdout
    except json.JSONDecodeError:
        return json.dumps({"error": "parse error", "status": "error"})


@traced
def cmd_view(repo, issue_num, ttl=None):
    if ttl is None:
        ttl = VIEW_TTL
    key = _cache_key("view", repo, {"issue": issue_num})
    if _is_fresh(key, ttl):
        c = _read_cache(key)
        if c is not None:
            return json.dumps(c)
    args = ["issue", "view", issue_num, "--repo", repo,
            "--json", "number,title,state,url,labels,body,updatedAt,closedAt,comments"]
    rc, stdout, stderr = _run_gh(args)
    if rc != 0:
        c = _read_cache(key)
        if c is not None:
            return json.dumps(c)
        return json.dumps({"error": stderr.strip(), "status": "error"})
    try:
        data = json.loads(stdout)
        _write_cache(key, data, ttl)
        return stdout
    except json.JSONDecodeError:
        return json.dumps({"error": "parse error", "status": "error"})


@traced
def cmd_search(query, ttl=None):
    if ttl is None:
        ttl = SEARCH_TTL
    key = _cache_key("search", "", {"q": query})
    if _is_fresh(key, ttl):
        c = _read_cache(key)
        if c is not None:
            return json.dumps(c)
    args = ["issue", "list", "--search", query, "--limit", "100",
            "--json", "number,title,state,url,labels,updatedAt,repo"]
    rc, stdout, stderr = _run_gh(args)
    if rc != 0:
        c = _read_cache(key)
        if c is not None:
            return json.dumps(c)
        return json.dumps({"error": stderr.strip(), "status": "error"})
    try:
        data = json.loads(stdout)
        _write_cache(key, data, ttl)
        return stdout
    except json.JSONDecodeError:
        return json.dumps({"error": "parse error", "status": "error"})


@traced
def cmd_invalidate(repo, issue_num=""):
    cleared = 0
    if not os.path.isdir(CACHE_DIR):
        return json.dumps({"status": "ok", "cleared": 0})
    for fname in os.listdir(CACHE_DIR):
        if not fname.endswith(".json") or fname.startswith("_"):
            continue
        fpath = os.path.join(CACHE_DIR, fname)
        try:
            with open(fpath) as f:
                data = json.load(f)
            if isinstance(data, list):
                for item in data:
                    url = item.get("url", "")
                    if repo in url or repo in item.get("repository_url", ""):
                        os.unlink(fpath)
                        mf = fpath.replace(".json", ".meta.json")
                        if os.path.exists(mf):
                            os.unlink(mf)
                        cleared += 1
                        break
            elif isinstance(data, dict):
                if repo in data.get("url", ""):
                    os.unlink(fpath)
                    mf = fpath.replace(".json", ".meta.json")
                    if os.path.exists(mf):
                        os.unlink(mf)
                    cleared += 1
        except Exception:
            try:
                os.unlink(fpath)
                cleared += 1
            except Exception:
                pass
    return json.dumps({"status": "ok", "cleared": cleared})


@traced
def cmd_clear(older_than=3600):
    if not os.path.isdir(CACHE_DIR):
        return json.dumps({"status": "ok", "cleared": 0})
    now = time.time()
    cleared = 0
    for fname in os.listdir(CACHE_DIR):
        if not fname.endswith(".meta.json"):
            continue
        fpath = os.path.join(CACHE_DIR, fname)
        try:
            with open(fpath) as f:
                meta = json.load(f)
            if now - meta.get("cached_at", 0) > older_than:
                base = fname.replace(".meta.json", "")
                for ext in (".json", ".meta.json"):
                    p = os.path.join(CACHE_DIR, f"{base}{ext}")
                    if os.path.exists(p):
                        os.unlink(p)
                        cleared += 1
        except Exception:
            try:
                os.unlink(fpath)
                cleared += 1
            except Exception:
                pass
    if os.path.exists(RATELIMIT_FILE):
        try:
            os.unlink(RATELIMIT_FILE)
        except Exception:
            pass
    return json.dumps({"status": "ok", "cleared": cleared})


def cmd_status():
    _ensure_dir()
    total = 0
    fresh = 0
    stale = 0
    now = time.time()
    for fname in os.listdir(CACHE_DIR):
        if not fname.endswith(".meta.json"):
            continue
        total += 1
        try:
            with open(os.path.join(CACHE_DIR, fname)) as f:
                meta = json.load(f)
            if now - meta.get("cached_at", 0) < meta.get("ttl", DEFAULT_TTL):
                fresh += 1
            else:
                stale += 1
        except Exception:
            stale += 1
    return json.dumps({
        "status": "ok", "total_entries": total, "fresh": fresh,
        "stale": stale, "cache_dir": CACHE_DIR,
        "rate_limit_per_minute": _MAX_CALLS_PER_MINUTE,
    })


_HELP = """Commands:
  list <repo> [--state open] [--label l] [--limit N] [--ttl N]
  view <repo> <issue-num> [--ttl N]
  search <query> [--ttl N]
  invalidate <repo> [--issue <num>]
  clear [--older-than SECONDS]
  status
"""


def _kv(rest, key, default=None):
    r2 = []
    val = default
    i = 0
    while i < len(rest):
        if rest[i] == f"--{key}" and i + 1 < len(rest):
            val = rest[i + 1]
            i += 2
        else:
            r2.append(rest[i])
            i += 1
    return r2, val


def main():
    _debug_setup()
    _ensure_dir()
    if len(sys.argv) < 2:
        print(_HELP); return 0
    c = sys.argv[1]
    rest = sys.argv[2:]
    if c == "list":
        if not rest: print("Usage: gh_cache.py list <repo>"); return 1
        repo = rest[0]
        rest, s = _kv(rest[1:], "state", "open")
        rest, l = _kv(rest, "label", "")
        rest, lm = _kv(rest, "limit", "50")
        rest, ttl_s = _kv(rest, "ttl", None)
        print(cmd_list(repo, state=s, label=l, limit=int(lm),
                       ttl=int(ttl_s) if ttl_s else None))
    elif c == "view":
        if len(rest) < 2: print("Usage: gh_cache.py view <repo> <num>"); return 1
        repo, num = rest[0], rest[1]
        rest, ttl_s = _kv(rest[2:], "ttl", None)
        print(cmd_view(repo, num, ttl=int(ttl_s) if ttl_s else None))
    elif c == "search":
        if not rest: print("Usage: gh_cache.py search <query>"); return 1
        print(cmd_search(" ".join(rest)))
    elif c == "invalidate":
        if not rest: print("Usage: gh_cache.py invalidate <repo>"); return 1
        repo = rest[0]
        rest, num = _kv(rest[1:], "issue", "")
        print(cmd_invalidate(repo, num))
    elif c == "clear":
        rest, ot = _kv(rest, "older-than", None)
        print(cmd_clear(older_than=int(ot) if ot else 3600))
    elif c == "status":
        print(cmd_status())
    else:
        print(f"Unknown: {c}"); print(_HELP); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
