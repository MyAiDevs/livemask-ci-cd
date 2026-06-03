#!/usr/bin/env bash
# logging.sh — Structured logging + comprehensive debug/trace system.
#
# This library is a PURE SHELL library. It must NOT force set -euo pipefail
# on the sourcing script. It provides:
#
#   LOG LEVELS (via CLAUDE_DEBUG env var):
#     0 = normal (log_ok, log_warn, log_fail, log_info)
#     1 = debug  (+ log_debug, function entry/exit, ERR trap with stack trace)
#     2 = trace  (+ bash PS4 tracing with file:line:func for EVERY statement)
#
# Usage:
#   source scripts/lib/logging.sh
#   log_setup "claude-startup"           # Init logging
#   log_phase "1" "System Check"         # Phase header
#   log_ok "all good"                    # Green checkmark
#   log_warn "something unusual"         # Yellow warning (stderr)
#   log_fail "something broken"          # Red error (stderr)
#   log_debug "variable X = ${X}"        # Only when DEBUG>=1
#   log_trace "step Y completed"         # Only when DEBUG>=2 (to debug log)
#   log_summary "name" 0 "done"          # Write JSON summary
#
# ENV VARS:
#   CLAUDE_DEBUG=0  (default) - Normal mode
#   CLAUDE_DEBUG=1             - Debug mode: log_debug visible, ERR trap, call stacks
#   CLAUDE_DEBUG=2             - Trace mode: + bash PS4 per-statement tracing
#
# Output:
#   /tmp/claude/<name>-<timestamp>.log            — Full run log
#   /tmp/claude/latest-<name>.log                 — Symlink to latest
#   /tmp/claude/last-run-<name>.json              — Structured summary
#   /tmp/claude/debug-<name>-<timestamp>.log      — Debug trace log (only if DEBUG>=2)

# ── DO NOT set -euo pipefail here! This is a library, sourcing script controls this.

LOG_DIR="/tmp/claude"
LOG_MAX_FILES=30

# ── Colors (disable if no tty or NO_COLOR set) ──────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD='\033[1m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    BOLD=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; MAGENTA=''; BLUE=''; RESET=''
fi

# ── Debug level from env ────────────────────────────────────────────────
CLAUDE_DEBUG="${CLAUDE_DEBUG:-0}"

# ── Initialize logging directory + file ─────────────────────────────────
log_setup() {
    local name="${1:-unknown}"
    local ts
    ts=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo "00000000-000000")
    mkdir -p "${LOG_DIR}" 2>/dev/null || true

    LOG_NAME="${name}"
    LOG_FILE="${LOG_DIR}/${name}-${ts}.log"
    LOG_LATEST="${LOG_DIR}/latest-${name}.log"
    LOG_SUMMARY="${LOG_DIR}/last-run-${name}.json"
    LOG_START_EPOCH=$(date +%s 2>/dev/null || echo "0")

    # Debug log (for PS4 trace output when DEBUG >= 2)
    LOG_DEBUG_FILE=""
    if [ "${CLAUDE_DEBUG}" -ge 2 ]; then
        LOG_DEBUG_FILE="${LOG_DIR}/debug-${name}-${ts}.log"
        : > "${LOG_DEBUG_FILE}"  # create/truncate
        echo "[DEBUG] debug log started at $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'N/A')" >> "${LOG_DEBUG_FILE}"
    fi

    # Rotate old logs: use ls -t + tail (POSIX-safe, no BSD/GNU head -n -N issues)
    local count
    count=$( (find "${LOG_DIR}" -maxdepth 1 -name "${name}-*.log" 2>/dev/null | wc -l | tr -d ' ') || echo "0")
    if [ "${count}" -gt "${LOG_MAX_FILES}" ] && [ "${count}" -gt 0 ]; then
        # ls -t sorts newest first, tail -n +N skips first N-1 lines (oldest files to remove)
        (cd "${LOG_DIR}" && ls -t "${name}-"*.log 2>/dev/null \
            | tail -n +$((LOG_MAX_FILES + 1)) \
            | while IFS= read -r old_log; do rm -f "${LOG_DIR}/${old_log}" 2>/dev/null || true; done) || true
    fi

    # Redirect stdout+stderr through tee to log file
    # Use a simple fd-based approach instead of process substitution
    # to avoid set -e / pipefail issues
    exec 3>&1 4>&2
    exec 1> >(tee -a "${LOG_FILE}" >&3)
    # Redirect ALL output to log file only. No tee, no double output.

    # Create/update latest symlink
    ln -sf "$(basename "${LOG_FILE}")" "${LOG_LATEST}" 2>/dev/null || true

    # Enable debug/trace infrastructure
    _log_init_debug "${name}"

    # Print banner
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  LOG: ${name}"
    echo "  TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'N/A')"
    echo "  DEBUG LEVEL: ${CLAUDE_DEBUG}"
    if [ -n "${LOG_DEBUG_FILE}" ]; then
        echo "  DEBUG FILE: ${LOG_DEBUG_FILE}"
    fi
    echo "  FILE: ${LOG_FILE}"
    echo "  LATEST: ${LOG_LATEST}"
    echo "═══════════════════════════════════════════════"
    echo ""

    # Trap EXIT to write summary automatically
    trap '_auto_summary $?' EXIT

    # Trap ERR for debug info when DEBUG >= 1
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        trap '_log_err_trap $? $LINENO $BASH_COMMAND' ERR
    fi
}

# ── Initialize debug/trace infrastructure ────────────────────────────────
_log_init_debug() {
    local name="${1:-unknown}"

    if [ "${CLAUDE_DEBUG}" -ge 2 ]; then
        # TRACE MODE: PS4 with file:line:function prefix
        # Redirect PS4 trace output to debug log file
        if [ -n "${LOG_DEBUG_FILE}" ]; then
            export BASH_XTRACEFD=9
            exec 9>>"${LOG_DEBUG_FILE}"
        fi
        # PS4 shows: [timestamp] source_file:lineno:func_name: command
        PS4='+ [$(date -u +%H:%M:%S 2>/dev/null || echo "?")] ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-MAIN}: '
        set -x
    elif [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        # DEBUG MODE: no per-statement trace, just function markers
        # ERR trap and log_debug/log_fn_enter/log_fn_exit are sufficient
        :
    fi
}

# ── ERR trap handler: print stack trace ────────────────────────────────
_log_err_trap() {
    local exit_code=$1 lineno=$2 command=$3
    echo -e "  ${RED}❌${RESET} [ERR_TRAP] exit=${exit_code} at ${BASH_SOURCE[1]:-?}:${lineno}: ${command}" >&2
    # Print call stack
    local frame=1
    while caller $frame >/dev/null 2>&1; do
        local line func file
        IFS=' ' read -r line func file <<< "$(caller $frame 2>/dev/null || echo '')"
        echo -e "  ${YELLOW}  ↳${RESET} ${file}:${line} → ${func}" >&2
        frame=$((frame + 1))
    done
    if [ -n "${LOG_DEBUG_FILE:-}" ]; then
        {
            echo "[ERR] exit=${exit_code} at ${BASH_SOURCE[1]:-?}:${lineno}: ${command}"
            local f2=1
            while caller $f2 >/dev/null 2>&1; do
                local l2 fn2 fl2
                IFS=' ' read -r l2 fn2 fl2 <<< "$(caller $f2 2>/dev/null || echo '')"
                echo "[ERR]   ↳ ${fl2}:${l2} → ${fn2}"
                f2=$((f2 + 1))
            done
        } >> "${LOG_DEBUG_FILE}" 2>/dev/null || true
    fi
}

# ── Auto-summary on EXIT ────────────────────────────────────────────────
_auto_summary() {
    local exit_code=$1
    if [ -n "${LOG_NAME:-}" ]; then
        log_summary "${LOG_NAME}" "${exit_code}" "auto" 2>/dev/null || true
    fi
    # Restore original stdout/stderr
    exec 1>&3 2>&4 3>&- 4>&- 2>/dev/null || true
}

# ── Phase logging ───────────────────────────────────────────────────────
log_phase() {
    local num="${1:-}" label="${2:-}"
    echo ""
    echo "========================================="
    echo "  Phase ${num}: ${label}"
    echo "  $(date -u +%H:%M:%S 2>/dev/null || echo '')"
    echo "========================================="
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        echo -e "  ${BLUE}⚙${RESET}  [DEBUG] entering phase ${num} (${label})"
    fi
}

# ── Status helpers ──────────────────────────────────────────────────────
log_ok()    { echo -e "  ${GREEN}✅${RESET} $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠️${RESET}  $1"; }  # No stderr redirect — avoids tee issues
log_fail()  { echo -e "  ${RED}❌${RESET} $1"; }
log_info()  { echo -e "  ${CYAN}ℹ️${RESET}  $1"; }

# ── Debug message (only when CLAUDE_DEBUG >= 1) ─────────────────────────
log_debug() {
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        echo -e "  ${MAGENTA}🔍${RESET} [DEBUG] $1"
        if [ -n "${LOG_DEBUG_FILE:-}" ]; then
            echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '?')] [DEBUG] $1" >> "${LOG_DEBUG_FILE}" 2>/dev/null || true
        fi
    fi
}

# ── Trace (only when CLAUDE_DEBUG >= 2, writes to debug log) ──────────
log_trace() {
    if [ "${CLAUDE_DEBUG}" -ge 2 ]; then
        local caller_info=""
        caller 0 >/dev/null 2>&1 && caller_info=$(caller 0 2>/dev/null || echo "")
        if [ -n "${LOG_DEBUG_FILE:-}" ]; then
            echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '?')] [TRACE] ${caller_info} $1" >> "${LOG_DEBUG_FILE}" 2>/dev/null || true
        fi
    fi
}

# ── Function entry/exit trace (only when DEBUG >= 1) ────────────────────
log_fn_enter() {
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        local func="${FUNCNAME[1]:-?}"
        local args="${1:-}"
        echo -e "  ${BLUE}▸${RESET} [${func}] enter${args:+ args=${args}}"
        if [ -n "${LOG_DEBUG_FILE:-}" ]; then
            echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '?')] [ENTER] ${func}${args:+ args=${args}}" >> "${LOG_DEBUG_FILE}" 2>/dev/null || true
        fi
    fi
}

log_fn_exit() {
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        local func="${FUNCNAME[1]:-?}"
        local result="${1:-}"
        echo -e "  ${BLUE}◂${RESET} [${func}] exit${result:+ → ${result}}"
        if [ -n "${LOG_DEBUG_FILE:-}" ]; then
            echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '?')] [EXIT] ${func}${result:+ → ${result}}" >> "${LOG_DEBUG_FILE}" 2>/dev/null || true
        fi
    fi
}

# ── Cycle header ────────────────────────────────────────────────────────
log_cycle() {
    local cycle_num="${1:-0}"
    echo ""
    echo "#########################################"
    echo "  Cycle #${cycle_num}"
    echo "  $(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
    echo "#########################################"
    echo ""
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        echo -e "  ${BLUE}⚙${RESET}  [DEBUG] starting cycle ${cycle_num}"
    fi
}

# ── Section header ──────────────────────────────────────────────────────
log_section() {
    local title="${1:-}"
    echo ""
    echo "--- ${title} ---"
}

# ── Structured summary JSON ─────────────────────────────────────────────
log_summary() {
    local name="${1:-unknown}" exit_code="${2:-0}" extra="${3:-}"
    local elapsed=0
    if [ -n "${LOG_START_EPOCH:-}" ] && [ "${LOG_START_EPOCH}" -gt 0 ] 2>/dev/null; then
        local now
        now=$(date +%s 2>/dev/null || echo "0")
        elapsed=$((now - LOG_START_EPOCH))
    fi

    # Write JSON summary (use cat + heredoc for safety)
    cat > "${LOG_SUMMARY}" 2>/dev/null <<- SUMMARYEOF || true
{
  "script": "${name}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'N/A')",
  "elapsed_sec": ${elapsed},
  "exit_code": ${exit_code},
  "log_file": "${LOG_FILE:-}",
  "debug_level": ${CLAUDE_DEBUG},
  "extra": "${extra}"
}
SUMMARYEOF

    echo "  [summary] ${LOG_SUMMARY}"
}

# ── Debug info panel ────────────────────────────────────────────────────
log_debug_info() {
    echo ""
    echo "── Debug Info ──────────────────────────────"
    echo "  Latest logs:"
    for lf in "${LOG_DIR}"/latest-*.log; do
        [ -f "${lf}" ] && echo "    tail -50 ${lf}"
    done
    if [ -n "${LOG_DEBUG_FILE:-}" ] && [ -f "${LOG_DEBUG_FILE}" ]; then
        echo "  Debug log: tail -50 ${LOG_DEBUG_FILE}"
    fi
    echo "  All logs:    ls -lt ${LOG_DIR}/"
    echo "  Summaries:   cat ${LOG_DIR}/last-run-*.json"
}
