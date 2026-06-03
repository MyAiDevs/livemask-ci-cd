#!/usr/bin/env bash
# log-watch.sh — Background log watcher + auto-repair daemon for Claude dev loop.
#
# Monitors log files for error patterns. When detected, checks experience system
# first for proven fixes, then falls back to repair.py --apply.
#
# Compatibility: bash 3.2+ (macOS), no associative arrays.
#
# Usage:
#   bash log-watch.sh start              # Start daemon
#   bash log-watch.sh stop               # Stop daemon
#   bash log-watch.sh status             # Check status
#   bash log-watch.sh watch <logfile>    # Watch a specific log file

# No "set -euo pipefail" — daemon mode needs to be resilient
# Error handling is done per-function

PID_FILE="${HOME}/.claude/log-watch.pid"
WATCH_DIRS=("/tmp/claude")
POLL_SECONDS=5
MAX_FIXES_PER_MINUTE=10
DAEMON_LOG="/tmp/claude/log-watch-daemon.log"
LIVEMASK_ROOT="${LIVEMASK_ROOT:-${HOME}/Developer/LiveMask}"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
PY_DIR="${CI_CD_DIR}/scripts/lib/py"
LINE_COUNTS_FILE="${HOME}/.claude/log-watch-lines.json"
FIX_COUNTER_FILE="${HOME}/.claude/log-watch-fixes.json"

# ── Helpers ──────────────────────────────────────────────────────────────

log_watch_msg() {
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    echo "${ts} [log-watch] $*"
}

_exit_if_stale_pid() {
    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}" 2>/dev/null || echo "")
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            echo "log-watch daemon already running (PID ${pid})"
            exit 0
        fi
        echo "removing stale PID file (${pid})"
        rm -f "${PID_FILE}"
    fi
}

# ── State tracking — JSON-backed (compatible with bash 3.2 on macOS) ─────

_state_init() {
    if [ ! -f "${LINE_COUNTS_FILE}" ]; then
        echo '{}' > "${LINE_COUNTS_FILE}" 2>/dev/null || true
    fi
    if [ ! -f "${FIX_COUNTER_FILE}" ]; then
        echo '{"last_minute_window":0,"fixes_this_window":0,"total_fixes":0}' > "${FIX_COUNTER_FILE}" 2>/dev/null || true
    fi
}

_state_get_line() {
    python3 -c "
import json, sys
try:
    d = json.load(open('${LINE_COUNTS_FILE}'))
    print(d.get(sys.argv[1], 0))
except:
    print(0)
" "$1" 2>/dev/null || echo "0"
}

_state_set_line() {
    python3 -c "
import json, sys
path = sys.argv[1]; count = int(sys.argv[2])
try:
    d = json.load(open('${LINE_COUNTS_FILE}'))
except:
    d = {}
d[path] = count
json.dump(d, open('${LINE_COUNTS_FILE}', 'w'))
" "$1" "$2" 2>/dev/null || true
}

_fix_counter_check() {
    local now
    now=$(date +%s 2>/dev/null || echo "0")
    local last_minute
    last_minute=$(python3 -c "import json; d=json.load(open('${FIX_COUNTER_FILE}')); print(d.get('last_minute_window',0))" 2>/dev/null || echo "0")
    local fixes_in_window
    fixes_in_window=$(python3 -c "import json; d=json.load(open('${FIX_COUNTER_FILE}')); print(d.get('fixes_this_window',0))" 2>/dev/null || echo "0")

    [ -z "${last_minute}" ] && last_minute=0
    [ -z "${fixes_in_window}" ] && fixes_in_window=0

    if [ $((now - last_minute)) -gt 60 ]; then
        fixes_in_window=0
        last_minute="${now}"
    fi

    if [ "${fixes_in_window}" -ge "${MAX_FIXES_PER_MINUTE}" ]; then
        return 1
    fi

    fixes_in_window=$((fixes_in_window + 1))
    local total
    total=$(python3 -c "import json; d=json.load(open('${FIX_COUNTER_FILE}')); print(d.get('total_fixes',0)+1)" 2>/dev/null || echo "1")

    echo "{\"last_minute_window\":${last_minute},\"fixes_this_window\":${fixes_in_window},\"total_fixes\":${total}}" > "${FIX_COUNTER_FILE}"
    return 0
}

# ── Auto-repair with experience.suggest + repair.py ────────────────────

_auto_repair() {
    local log_file="$1"
    local new_lines="$2"

    local has_error=false
    if echo "${new_lines}" | grep -qiE '(error|fail|panic|exit status|not found|declared and not used)' 2>/dev/null; then
        has_error=true
    fi

    [ "${has_error}" = false ] && return 0

    if ! _fix_counter_check; then
        log_watch_msg "rate limited — too many fixes per minute"
        return 0
    fi

    # Try experience system first
    local suggest_file="/tmp/log-watch-suggest-$$.json"
    python3 "${PY_DIR}/experience.py" suggest "${log_file}" > "${suggest_file}" 2>/dev/null || true

    local exp_status
    exp_status=$(python3 -c "
import json
try: d = json.load(open('${suggest_file}')); print(d.get('status', 'no_experience'))
except: print('no_experience')
" 2>/dev/null || echo "no_experience")

    if [ "${exp_status}" = "ok" ]; then
        log_watch_msg "experience system has suggestions — applying..."
        python3 "${PY_DIR}/experience.py" _apply "${suggest_file}" 2>/dev/null || true
        local healed_status
        healed_status=$(python3 -c "
import json
try: d = json.load(open('${suggest_file}')); print('yes' if any(s.get('confidence',0) >= 70 for s in d.get('suggestions',[])) else 'no')
except: print('no')
" 2>/dev/null || echo "no")
        if [ "${healed_status}" = "yes" ]; then
            log_watch_msg "experience heal applied for ${log_file}"
            rm -f "${suggest_file}" 2>/dev/null || true
            return 0
        fi
    fi
    rm -f "${suggest_file}" 2>/dev/null || true

    # Fall back to repair.py --apply
    local repair_output
    repair_output=$(python3 "${PY_DIR}/repair.py" build "${log_file}" --apply 2>/dev/null || echo '{"status":"error"}')

    local status
    status=$(echo "${repair_output}" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('status', 'error'))
except: print('error')
" 2>/dev/null || echo "error")

    if [ "${status}" = "fixed" ]; then
        log_watch_msg "auto-repaired via ${log_file}"
    elif [ "${status}" = "retry" ]; then
        log_watch_msg "found fixable errors in ${log_file} — will retry"
    else
        log_watch_msg "unrecognized errors in ${log_file} (status=${status})"
    fi
}

# ── Poll loop ──────────────────────────────────────────────────────────

_poll_loop() {
    # Delegate to Python daemon for reliable background operation
    exec python3 "${PY_DIR}/log_watch_daemon.py" daemon
}

# ── Commands ───────────────────────────────────────────────────────────

cmd_start() {
    _exit_if_stale_pid
    mkdir -p "${HOME}/.claude" /tmp/claude 2>/dev/null || true

    # Python daemon writes its own PID file
    nohup python3 "${PY_DIR}/log_watch_daemon.py" daemon > "${DAEMON_LOG}" 2>&1 &

    sleep 3
    local pid
    pid=$(cat "${PID_FILE}" 2>/dev/null || echo "")
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        echo "log-watch daemon started (PID ${pid})"
        echo "  log: ${DAEMON_LOG}"
    else
        echo "WARN: PID check failed — trying direct check..."
        local found_pid
        found_pid=$(pgrep -f "log_watch_daemon.py" 2>/dev/null | head -1 || echo "")
        if [ -n "${found_pid}" ]; then
            echo "${found_pid}" > "${PID_FILE}"
            echo "log-watch daemon started (PID ${found_pid})"
            echo "  log: ${DAEMON_LOG}"
        else
            echo "ERROR: daemon failed to start — check ${DAEMON_LOG}"
            rm -f "${PID_FILE}"
            exit 1
        fi
    fi
}

cmd_stop() {
    if [ ! -f "${PID_FILE}" ]; then
        echo "daemon not running (no PID file)"
        return 0
    fi
    local pid
    pid=$(cat "${PID_FILE}" 2>/dev/null || echo "")
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
        sleep 1
        if kill -0 "${pid}" 2>/dev/null; then
            kill -9 "${pid}" 2>/dev/null || true
        fi
        echo "daemon stopped (PID ${pid})"
    else
        echo "daemon not running (stale PID ${pid})"
    fi
    rm -f "${PID_FILE}"
}

cmd_status() {
    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}" 2>/dev/null || echo "")
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            echo "log-watch daemon is RUNNING (PID ${pid})"
            echo "  log: ${DAEMON_LOG}"
        else
            echo "daemon NOT running (stale PID ${pid})"
            rm -f "${PID_FILE}"
            exit 1
        fi
    else
        echo "daemon NOT running"
        exit 1
    fi
}

# ── Main ───────────────────────────────────────────────────────────────

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    watch)
        if [ -n "${2:-}" ] && [ -f "${2}" ]; then
            local abs_path
            abs_path=$(cd "$(dirname "${2}")" && pwd)/$(basename "${2}")
            local line_count
            line_count=$(wc -l < "${abs_path}" 2>/dev/null || echo "0")
            _state_set_line "${abs_path}" "${line_count}"
            echo "watching: ${abs_path} (${line_count} existing lines)"
        else
            echo "usage: $0 watch <logfile>"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status|watch <logfile>}"
        exit 1
        ;;
esac
