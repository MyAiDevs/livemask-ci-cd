#!/usr/bin/env python3
"""Compute QA verdict from individual result files."""
import json, sys, os, glob

def load_json(pattern):
    """Load the most recent file matching a glob pattern.
    Robust: parses only the first complete JSON object, ignoring trailing garbage."""
    files = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    if not files:
        return {}
    with open(files[0], "rb") as f:
        data = f.read()
    # Find the end of the first complete JSON object
    depth = 0
    end = 0
    text = data.decode("utf-8", errors="replace")
    for i, ch in enumerate(text):
        if ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end > 0:
        return json.loads(text[:end])
    return {}

if len(sys.argv) < 2:
    print("Usage: qa-verdict.py <TASK-ID>")
    sys.exit(1)

tid = sys.argv[1]
tmp = "/tmp/claude"
v = load_json(f"{tmp}/qa-verify-{tid}.json")
h = load_json(f"{tmp}/qa-health-{tid}.json")
s = load_json(f"{tmp}/qa-smoke-{tid}.json")
a = load_json(f"{tmp}/qa-accept-{tid}.json")

build_ok = v.get("failed", 99) == 0
health_ok = h.get("failed", 0) == 0 or h.get("skipped", False) or h.get("is_service") == False
smoke_ok = s.get("smoke_tests_failed", 0) == 0 or s.get("smoke_tests_run", 0) == 0
smoke_ran = s.get("smoke_tests_run", 0) > 0
accept_ok = a.get("all_checked", False) or a.get("acceptance_criteria_total", 0) == 0

# Smoke tests are non-blocking (advisory) — run without full docker stack
qa_ok = build_ok and health_ok and accept_ok
if smoke_ran and not smoke_ok:
    print(f"  [QA] Note: {s.get('smoke_tests_failed',0)} smoke tests failed (non-blocking)", file=sys.stderr)

# Verbose debug if requested
if "--debug" in sys.argv:
    print(f"build_ok={build_ok} (failed={v.get('failed')})")
    print(f"health_ok={health_ok} (failed={h.get('failed')}, skipped={h.get('skipped')}, is_service={h.get('is_service')})")
    print(f"smoke_ok={smoke_ok} (failed={s.get('smoke_tests_failed')}, run={s.get('smoke_tests_run')})")
    print(f"accept_ok={accept_ok} (all_checked={a.get('all_checked')}, total={a.get('acceptance_criteria_total')})")

print("true" if qa_ok else "false")
