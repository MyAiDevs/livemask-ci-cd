#!/usr/bin/env bash
# claude-startup.sh — Launch sequence for Claude dev loop.
#
# Checks: Docker, Git, Python tools (venv), cache health, experience db,
# log-watch daemon, and session restore.
#
# Debug:
#   CLAUDE_DEBUG=1 → verbose checks
#   CLAUDE_DEBUG=2 → set -x bash trace

# set -euo pipefail  # REMOVED: was killing dev-loop on any non-zero return

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
PY_DIR="${CI_CD_DIR}/scripts/lib/py"
source "${CI_CD_DIR}/scripts/lib/helpers.sh"

log_setup "claude-startup"

CLAUDE_DEBUG="${CLAUDE_DEBUG:-0}"
export CLAUDE_DEBUG  # Propagate to all child shell scripts AND Python subprocesses
DEBUG_LEVEL="${CLAUDE_DEBUG}"

log_section "Startup Health Check"

# ── 1. Python venv ─────────────────────────────────────────────────────
log_info "checking Python venv..."
if [ -f "${CI_CD_DIR}/scripts/lib/venv.sh" ]; then
    if bash "${CI_CD_DIR}/scripts/lib/venv.sh" check 2>&1 | tail -3; then
        log_ok "venv healthy"
    else
        log_warn "venv needs setup — running setup..."
        bash "${CI_CD_DIR}/scripts/lib/venv.sh" setup 2>&1 | tail -3
        log_ok "venv setup completed"
    fi
else
    log_warn "venv.sh not found — skipping venv check"
fi

# ── 2. Core Python tools syntax check ──────────────────────────────────
log_info "checking Python tool syntax..."
PY_TOOLS=(
    "${PY_DIR}/planner.py"
    "${PY_DIR}/cache.py"
    "${PY_DIR}/experience.py"
    "${PY_DIR}/context_graph.py"
    "${PY_DIR}/doc_parser.py"
    "${PY_DIR}/repair.py"
    "${PY_DIR}/lark_send.py"
    "${PY_DIR}/session.py"
    "${PY_DIR}/ledger.py"
    "${PY_DIR}/gates.py"
    "${PY_DIR}/self_review.py"
    "${PY_DIR}/context.py"
    "${PY_DIR}/dispatch.py"
    "${PY_DIR}/task_intake.py"
    "${PY_DIR}/shared_knowledge.py"
    "${PY_DIR}/lock.py"
    "${PY_DIR}/tags.py"
    "${PY_DIR}/dev_intel.py"
    "${PY_DIR}/knowledge_base.py"
    "${PY_DIR}/log_watch_daemon.py"
    "${PY_DIR}/webhook_consumer.py"
    "${PY_DIR}/auto_evidence.py"
    "${PY_DIR}/auto_implement.py"
    "${PY_DIR}/self_heal.py"
    "${PY_DIR}/debug_utils.py"
)

PY_ERRORS=0
for py_tool in "${PY_TOOLS[@]}"; do
    if [ -f "${py_tool}" ]; then
        if python3 -c "compile(open('${py_tool}').read(), '${py_tool}', 'exec')" 2>/dev/null; then
            log_debug "  ✓ ${py_tool##*/}"
        else
            log_warn "  ✗ ${py_tool##*/} has syntax errors"
            PY_ERRORS=$((PY_ERRORS + 1))
        fi
    else
        log_debug "  - ${py_tool##*/} not found"
    fi
done

if [ "${PY_ERRORS}" -gt 0 ]; then
    log_warn "${PY_ERRORS} Python tool(s) have syntax errors"
else
    log_ok "all Python tools have valid syntax"
fi

# ── 3. Shell script syntax ────────────────────────────────────────────
log_info "checking shell script syntax..."
SH_ERRORS=0
for sh_file in "${SCRIPT_DIR}/"*.sh "${SCRIPT_DIR}/lib/"*.sh; do
    if [ -f "${sh_file}" ]; then
        if bash -n "${sh_file}" 2>/dev/null; then
            log_debug "  ✓ ${sh_file##*/}"
        else
            log_warn "  ✗ ${sh_file##*/} has syntax errors"
            SH_ERRORS=$((SH_ERRORS + 1))
        fi
    fi
done

if [ "${SH_ERRORS}" -gt 0 ]; then
    log_warn "${SH_ERRORS} shell script(s) have syntax errors"
else
    log_ok "all shell scripts have valid syntax"
fi

# ── 4. Docker containers ───────────────────────────────────────────────
log_info "checking Docker containers..."
if command -v docker &>/dev/null; then
    CONTAINER_COUNT=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ "${CONTAINER_COUNT}" -gt 0 ]; then
        log_ok "${CONTAINER_COUNT} container(s) running"
    else
        log_warn "no Docker containers running"
    fi

    # Check specific containers
    for container in livemask-local-postgres-1 livemask-local-redis-1; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "${container}"; then
            log_debug "  ✓ ${container} running"
        else
            log_debug "  - ${container} not running"
        fi
    done
else
    log_warn "Docker not available"
fi

# ── 5. Git repositories ───────────────────────────────────────────────
log_info "checking git repositories..."
REPOS=(
    "livemask-ci-cd"
    "livemask-docs"
    "livemask-backend"
    "livemask-admin"
    "livemask-app"
    "livemask-nodeagent"
    "livemask-job-service"
    "livemask-website"
)

GIT_ERRORS=0
for repo in "${REPOS[@]}"; do
    repo_path="${LIVEMASK_ROOT}/${repo}"
    if [ -d "${repo_path}" ]; then
        cd "${repo_path}"
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            log_debug "  ${repo}: ${branch} (uncommitted)"
        else
            log_debug "  ${repo}: ${branch} (clean)"
        fi
    else
        log_debug "  ${repo}: not found"
    fi
done

# ── 6. GitHub CLI ─────────────────────────────────────────────────────
log_info "checking GitHub CLI..."
if gh_available; then
    log_ok "GitHub CLI authenticated"
else
    log_warn "GitHub CLI not available or not authenticated"
fi

# ── 7. Cache initialization ────────────────────────────────────────────
log_info "initializing cache namespaces..."
if [ -f "${PY_DIR}/cache.py" ]; then
    for ns in "ledger-lookup" "context-graph" "experience" "session-state"; do
        python3 "${PY_DIR}/cache.py" stats 2>/dev/null > /dev/null || {
            log_debug "  cold start: ${ns}"
        }
    done
    log_ok "cache initialized"
fi

# ── 8. Experience database health ───────────────────────────────────────
log_info "checking experience database..."
if [ -f "${PY_DIR}/experience.py" ]; then
    EXP_STATS=$(python3 "${PY_DIR}/experience.py" stats 2>/dev/null || true)
    EXP_COUNT=$(echo "${EXP_STATS}" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('total_experiences', 0))
except: print('0')
" 2>/dev/null || echo "0")
    if [ "${EXP_COUNT}" -gt 0 ]; then
        log_ok "experience database: ${EXP_COUNT} records"
    else
        log_info "experience database: empty (new system)"
    fi
fi

# ── 9. Clean stale evidence ────────────────────────────────────────────
log_info "cleaning stale session evidence..."
EVIDENCE_DIR="${HOME}/.claude/role-cache/evidence"
if [ -d "${EVIDENCE_DIR}" ]; then
    find "${EVIDENCE_DIR}" -name "*.json" -mtime +7 -delete 2>/dev/null || true
    STALE_COUNT=$(find "${EVIDENCE_DIR}" -name "*.json" -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    if [ "${STALE_COUNT}" -gt 0 ]; then
        log_info "cleaned ${STALE_COUNT} stale evidence files"
    fi
fi

# ── 10. Ledger cache refresh ───────────────────────────────────────────
log_info "refreshing ledger cache..."
if [ -f "${DOCS_DIR}/docs/development/task-state-ledger.json" ]; then
    ledger_refresh "${DOCS_DIR}/docs/development/task-state-ledger.json" 2>/dev/null || true
    log_ok "ledger cache refreshed"
fi

# ── 11. Start log-watch daemon ──────────────────────────────────────────
log_info "starting log-watch daemon..."
if [ -f "${PY_DIR}/log_watch_daemon.py" ]; then
    if bash "${CI_CD_DIR}/scripts/lib/log-watch.sh" status 2>/dev/null; then
        log_debug "log-watch already running"
    else
        # Start daemon — critical: redirect all std fds away from tee pipe
        # so daemon won't get SIGPIPE when startup script exits.
        nohup python3 "${PY_DIR}/log_watch_daemon.py" daemon \
            >> "${LOG_DIR}/log-watch-daemon.log" 2>&1 < /dev/null &
        dpid=$!
        sleep 2
        if kill -0 "${dpid}" 2>/dev/null; then
            log_ok "log-watch daemon started (PID ${dpid})"
            echo "${dpid}" > "${HOME}/.claude/log-watch.pid"
        else
            log_warn "log-watch daemon failed to start"
        fi
    fi
else
    log_warn "log_watch_daemon.py not found — skipping"
fi

# ── Session restore ────────────────────────────────────────────────────
if [ -n "${CLAUDE_RESUME:-}" ] && [ "${CLAUDE_RESUME}" = "true" ]; then
    log_section "Session Restore"
    resume_task="${CLAUDE_TASK_ID:-}"
    resume_phase="${CLAUDE_PREVIOUS_PHASE:-}"

    if [ -n "${resume_task}" ] && [ -n "${resume_phase}" ]; then
        log_info "resuming task ${resume_task} from phase ${resume_phase}"
    else
        log_info "resume requested but no previous task found"
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
log_ok "startup checks completed"
log_debug_info

exit 0
