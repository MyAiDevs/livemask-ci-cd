#!/usr/bin/env bash
# logging.sh — Structured logging for Claude dev loop.
#
# Pure Shell. No embedded Python.
#
# Debug modes (via CLAUDE_DEBUG env var or --debug flag):
#   CLAUDE_DEBUG=1  → log_debug messages visible, writes debug log
#   CLAUDE_DEBUG=2  → + bash set -x tracing
#
# Usage:
#   source scripts/lib/logging.sh
#   log_setup "claude-startup"
#   log_phase "1" "System Check"
#   log_ok "all good"
#   log_warn "something unusual"
#   log_fail "something broken"
#   log_debug "variable X = ${X}"    # only shown when DEBUG>=1
#   log_summary "name" 0 "done"
#
# Output:
#   /tmp/claude/<name>-<timestamp>.log      — Full run log
#   /tmp/claude/latest-<name>.log           — Symlink to latest run
#   /tmp/claude/last-run-<name>.json        — Structured summary
#   /tmp/claude/debug-<name>-<timestamp>.log — Debug log (only if DEBUG>=1)

set -euo pipefail

LOG_DIR="/tmp/claude"
LOG_MAX_FILES=30

# ── Colors ──────────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

# ── Debug level from env ────────────────────────────────────────────────
CLAUDE_DEBUG="${CLAUDE_DEBUG:-0}"

# ── Initialize logging directory + file ─────────────────────────────────
log_setup() {
    local name="${1:-unknown}"
    local ts
    ts=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo "00000000-000000")
    mkdir -p "${LOG_DIR}"

    LOG_NAME="${name}"
    LOG_FILE="${LOG_DIR}/${name}-${ts}.log"
    LOG_LATEST="${LOG_DIR}/latest-${name}.log"
    LOG_SUMMARY="${LOG_DIR}/last-run-${name}.json"
    LOG_START_EPOCH=$(date +%s 2>/dev/null || echo "0")

    # Debug log (only if DEBUG >= 1)
    LOG_DEBUG_FILE=""
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        LOG_DEBUG_FILE="${LOG_DIR}/debug-${name}-${ts}.log"
        echo "[DEBUG] debug log started at $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'N/A')" > "${LOG_DEBUG_FILE}"
    fi

    # Rotate old logs: keep only newest LOG_MAX_FILES
    local count
    count=$(find "${LOG_DIR}" -maxdepth 1 -name "${name}-*.log" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ "${count}" -gt "${LOG_MAX_FILES}" ]; then
        find "${LOG_DIR}" -maxdepth 1 -name "${name}-*.log" -type f | sort | head -n -"${LOG_MAX_FILES}" | xargs rm -f 2>/dev/null || true
    fi

    # Tee stdout+stderr to log file
    exec > >(tee -a "${LOG_FILE}") 2>&1

    # Create/update latest symlink
    ln -sf "$(basename "${LOG_FILE}")" "${LOG_LATEST}" 2>/dev/null || true

    # Print banner
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  LOG: ${name}"
    echo "  TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'N/A')"
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        echo "  DEBUG: enabled (level ${CLAUDE_DEBUG})"
        echo "  DEBUG FILE: ${LOG_DEBUG_FILE}"
    fi
    echo "  FILE: ${LOG_FILE}"
    echo "  LATEST: ${LOG_LATEST}"
    echo "═══════════════════════════════════════════════"
    echo ""

    # Trap EXIT to write summary automatically
    trap '_auto_summary $?' EXIT
}

# ── Auto-summary on EXIT ────────────────────────────────────────────────
_auto_summary() {
    local exit_code=$1
    if [ -n "${LOG_NAME:-}" ]; then
        log_summary "${LOG_NAME}" "${exit_code}" "auto"
    fi
}

# ── Phase logging ───────────────────────────────────────────────────────
log_phase() {
    local num="${1:-}" label="${2:-}"
    echo ""
    echo "========================================="
    echo "  Phase ${num}: ${label}"
    echo "  $(date -u +%H:%M:%S 2>/dev/null || echo '')"
    echo "========================================="
}

# ── Status helpers ──────────────────────────────────────────────────────
log_ok()    { echo -e "  ${GREEN}✅${RESET} $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠️${RESET}  $1" >&2; }
log_fail()  { echo -e "  ${RED}❌${RESET} $1" >&2; }
log_info()  { echo -e "  ${CYAN}ℹ️${RESET}  $1"; }

# ── Debug message (only shown when CLAUDE_DEBUG >= 1) ──────────────────
log_debug() {
    if [ "${CLAUDE_DEBUG}" -ge 1 ]; then
        echo -e "  ${MAGENTA}🔍${RESET} [DEBUG] $1"
        if [ -n "${LOG_DEBUG_FILE:-}" ]; then
            echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '?')] [DEBUG] $1" >> "${LOG_DEBUG_FILE}" 2>/dev/null || true
        fi
    fi
}

# ── Trace (shown only on CLAUDE_DEBUG >= 2, writes to debug log) ──────
log_trace() {
    if [ "${CLAUDE_DEBUG}" -ge 2 ]; then
        if [ -n "${LOG_DEBUG_FILE:-}" ]; then
            echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '?')] [TRACE] $1" >> "${LOG_DEBUG_FILE}" 2>/dev/null || true
        fi
    fi
}

# ── Cycle header (for dev loop) ─────────────────────────────────────────
log_cycle() {
    local cycle_num="${1:-0}"
    echo ""
    echo "#########################################"
    echo "  Cycle #${cycle_num}"
    echo "  $(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
    echo "#########################################"
    echo ""
}

# ── Section header ──────────────────────────────────────────────────────
log_section() {
    local title="${1:-}"
    echo ""
    echo "--- ${title} ---"
}

# ── Structured summary (JSON, written via printf, no Python) ─────────────
log_summary() {
    local name="${1:-unknown}" exit_code="${2:-0}" extra="${3:-}"
    local elapsed=0
    if [ -n "${LOG_START_EPOCH:-}" ] && [ "${LOG_START_EPOCH}" -gt 0 ] 2>/dev/null; then
        local now
        now=$(date +%s 2>/dev/null || echo "0")
        elapsed=$((now - LOG_START_EPOCH))
    fi

    # Write JSON via printf (no Python heredoc)
    {
        printf '{\n'
        printf '  "script": "%s",\n' "${name}"
        printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'N/A')"
        printf '  "elapsed_sec": %d,\n' "${elapsed}"
        printf '  "exit_code": %d,\n' "${exit_code}"
        printf '  "log_file": "%s",\n' "${LOG_FILE:-}"
        printf '  "debug_level": %d,\n' "${CLAUDE_DEBUG}"
        printf '  "extra": "%s"\n' "${extra}"
        printf '}\n'
    } > "${LOG_SUMMARY}" 2>/dev/null || true

    echo "  [summary] ${LOG_SUMMARY}"
}

# ── Debug: print where to find logs ─────────────────────────────────────
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
