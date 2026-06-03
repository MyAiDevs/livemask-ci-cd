#!/usr/bin/env bash
# gh-issue-watch.sh — GitHub issue watcher for LiveMask task intake
#
# Polls all 8 repositories for NEW open issues that aren't tracked yet,
# auto-intakes them as tasks in the system.
#
# Usage:
#   ./gh-issue-watch.sh                # Scan ALL repos for new issues → intake
#   ./gh-issue-watch.sh --repo backend  # Single repo scan
#   ./gh-issue-watch.sh --loop         # Daemon mode: scan every 5 minutes
#   ./gh-issue-watch.sh --once         # Single scan, exit
#   ./gh-issue-watch.sh --dry-run      # Classify only, don't create artifacts
#
# Integration:
#   - Called by claude-dev-loop.sh Phase 1 (startup)
#   - Can run as standalone daemon via --loop
#   - Any found issues are auto-intaked via task_intake.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_DIR="${SCRIPT_DIR}/lib/py"

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
LOG_FILE="${LOG_DIR:-/tmp}/gh-issue-watch.log"

SINGLE_SHOT=false
DAEMON_MODE=false
DRY_RUN=false
TARGET_REPO=""

# ── Argument parser ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)     TARGET_REPO="$2"; shift 2 ;;
        --loop)     DAEMON_MODE=true; shift ;;
        --once)     SINGLE_SHOT=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help)     echo "Usage: $0 [--repo R] [--loop] [--once] [--dry-run]"; exit 0 ;;
        *)          echo "unknown: $1"; exit 1 ;;
    esac
done

# ── Scan function ──────────────────────────────────────────────────────────
scan_and_intake() {
    local repo_arg=""
    if [ -n "${TARGET_REPO}" ]; then
        repo_arg="--repo ${TARGET_REPO}"
    fi

    local dry_arg=""
    if [ "${DRY_RUN}" = true ]; then
        dry_arg="--dry-run"
    fi

    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Scanning GitHub issues for new tasks..."

    local output
    output=$(python3 "${PY_DIR}/task_intake.py" scan-github ${repo_arg} ${dry_arg} 2>/dev/null || echo '{"status":"error"}')

    local status
    status=$(echo "${output}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null || echo "error")

    if [ "${status}" = "ok" ]; then
        local count
        count=$(echo "${output}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('new_issues_processed',0))" 2>/dev/null || echo "0")
        local tracked
        tracked=$(echo "${output}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_tracked',0))" 2>/dev/null || echo "0")

        echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] GitHub scan: ${count} new, ${tracked} total tracked"

        if [ "${count}" -gt 0 ]; then
            echo "${output}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for s in d.get('scanned', []):
        tid = s.get('task_id', '?')
        repo = s.get('repo', '?')
        num = s.get('number', '?')
        dups = s.get('duplicates', [])
        dup_info = f' (DUPLICATE: {dups[0][\"task_id\"]})' if dups else ''
        print(f'  → [{repo}#{num}] → {tid}{dup_info}')
except: pass
" 2>/dev/null || true
        fi
    else
        local error
        error=$(echo "${output}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown error'))" 2>/dev/null || echo "parse error")
        echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ⚠️  GitHub scan error: ${error}"
    fi

    echo "${output}" >> "${LOG_FILE}"
}

# ── Main ───────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

if [ "${DAEMON_MODE}" = true ]; then
    echo "[gh-issue-watch] Starting daemon mode (interval: 5 minutes)"
    while true; do
        scan_and_intake
        echo "[gh-issue-watch] Sleeping 300s..."
        sleep 300
    done
elif [ "${SINGLE_SHOT}" = true ]; then
    scan_and_intake
else
    # Default: scan once, then loop
    while true; do
        scan_and_intake
        echo "[gh-issue-watch] Sleeping 300s..."
        sleep 300
    done
fi
