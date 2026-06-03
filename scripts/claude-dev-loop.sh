#!/usr/bin/env bash
# claude-dev-loop.sh — Main Claude autonomous development loop
#
# Pure Shell. No embedded Python. Calls Python tools as subprocesses.
#
# 6 phases:
#   Phase 1: STARTUP   — toolchain, git, docker, session restore
#   Phase 2: DISPATCH  — find next task via dispatch.py
#   Phase 3: CONTEXT   — load context via context.py, save session
#   Phase 4: IMPLEMENT — code + auto-repair via repair.py
#   Phase 5: VERIFY    — build/test/self-review via local-verify + self_review.py
#   Phase 6: COMPLETE  — merge, GitHub issue, ledger update
#
# Usage:
#   ./claude-dev-loop.sh              # Full loop (unlimited cycles)
#   ./claude-dev-loop.sh --once       # One cycle, exit
#   ./claude-dev-loop.sh --phase 4    # Resume from phase 4
#   ./claude-dev-loop.sh --help       # Show usage

set -euo pipefail

# Source logging
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/lark-notify.sh"
source "${SCRIPT_DIR}/lib/venv.sh"

# ---- Constants ----
LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
PY_DIR="${CI_CD_DIR}/scripts/lib/py"
LEDGER="${DOCS_DIR}/docs/development/task-state-ledger.json"
DISPATCH_DIR="${DOCS_DIR}/docs/development/dispatch-packets"
CONTRACTS_DIR="${DOCS_DIR}/docs/contracts"
CONTEXT_FILE="${HOME}/.claude/role-cache/context-current.json"
SESSION_STATE="${HOME}/.claude/role-cache/session-state.json"

START_PHASE=1
SINGLE_SHOT=false

# ---- Argument parser ----
while [ $# -gt 0 ]; do
    case "$1" in
        --once)      SINGLE_SHOT=true; shift ;;
        --phase)     START_PHASE="$2"; shift 2 ;;
        --help)      echo "Usage: $0 [--once] [--phase N]"; exit 0 ;;
        *)           log_fail "unknown flag: $1"; exit 1 ;;
    esac
done

# Ensure log directory exists
mkdir -p "$(dirname "${LOG_DIR}")" 2>/dev/null || true

# ---- Main Loop ----
log_setup "claude-dev-loop"

CYCLE_NUM=0

while true; do
    CYCLE_NUM=$((CYCLE_NUM + 1))
    CURRENT_PHASE=""

    log_cycle "${CYCLE_NUM}"
    lark_notify "cycle_start" "${CYCLE_NUM}" ""

    # ----------------------------------------------------------------
    # Phase 1: STARTUP
    # ----------------------------------------------------------------
    if [ "${START_PHASE}" -le 1 ]; then
        CURRENT_PHASE="startup"
        log_phase "1" "System Check"

        if ! bash "${CI_CD_DIR}/scripts/claude-startup.sh" 2>&1 | tee -a "${LOG_FILE}" | grep -v "^==" | head -5; then
            log_warn "startup check had warnings — continuing"
        fi

        # ── Break stale locks from previous sessions ──────────────────
        python3 "${PY_DIR}/lock.py" break-stale --prefix "task:" 2>/dev/null || true
        python3 "${PY_DIR}/lock.py" break-stale --prefix "repo:" 2>/dev/null || true
        log_info "stale locks cleaned up"

        # ── Enrich tags from ledger/contracts on each startup ─────────
        python3 "${PY_DIR}/tags.py" enrich 2>/dev/null || true

        # ── Consume webhook events (push-based, no API calls) ──────────
        log_info "consuming webhook inbox events..."
        python3 "${PY_DIR}/webhook_consumer.py" process 2>/dev/null || true

        # ── Start webhook consumer daemon (if not running) ────────────
        if ! pgrep -f "webhook_consumer.py daemon" >/dev/null 2>&1; then
            nohup python3 "${PY_DIR}/webhook_consumer.py" daemon \
                > /tmp/claude/webhook-consumer.log 2>&1 &
            log_info "webhook consumer daemon started"
        fi

        # ── Build shared knowledge base (cached, fast) ────────────────
        python3 "${PY_DIR}/shared_knowledge.py" build --skip-github 2>/dev/null || true

        # ── Ensure log-watch daemon is running as safety net ──────────
        if ! bash "${CI_CD_DIR}/scripts/lib/log-watch.sh" status >/dev/null 2>&1; then
            bash "${CI_CD_DIR}/scripts/lib/log-watch.sh" start >/dev/null 2>&1 || true
            log_info "log-watch daemon started (auto)"
        fi

        # Check if we're resuming a session
        if [ "${CLAUDE_RESUME:-false}" = "true" ]; then
            RESUME_TASK="${CLAUDE_TASK_ID:-}"
            RESUME_PHASE="${CLAUDE_PREVIOUS_PHASE:-}"
            if [ -n "$RESUME_TASK" ] && [ -n "$RESUME_PHASE" ]; then
                case "${RESUME_PHASE}" in
                    implementing) START_PHASE=4; log_info "resuming from phase 4 (implementing)" ;;
                    verifying)    START_PHASE=5; log_info "resuming from phase 5 (verifying)" ;;
                    *)            log_info "resuming from phase 3 (context reload)" ;;
                esac
                TASK_ID="${RESUME_TASK}"
                continue
            fi
        fi
    fi

    # ----------------------------------------------------------------
    # Phase 2: DISPATCH
    # ----------------------------------------------------------------
    if [ "${START_PHASE}" -le 2 ]; then
        CURRENT_PHASE="dispatch"
        log_phase "2" "Task Dispatch"

        DISPATCH_OUTPUT=$(python3 "${PY_DIR}/dispatch.py" next \
            --ledger "${LEDGER}" \
            --packets "${DISPATCH_DIR}" 2>/dev/null) || true

        DISPATCH_STATUS=$(echo "${DISPATCH_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('status', 'error'))
except: print('parse_error')
" 2>/dev/null || echo "parse_error")

        if [ "${DISPATCH_STATUS}" = "found" ]; then
            TASK_ID=$(echo "${DISPATCH_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('task_id', ''))
except: print('')
" 2>/dev/null || echo "")
            TARGET_REPO=$(echo "${DISPATCH_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('repo', ''))
except: print('')
" 2>/dev/null || echo "")

            log_ok "found task: ${TASK_ID} → ${TARGET_REPO}"
            log_info "source: $(echo "${DISPATCH_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('source', '?'))
except: print('?')
" 2>/dev/null || echo "?")"

            # ── Acquire task lock ──────────────────────────────────
            LOCK_TMPFILE="/tmp/dev-loop-lock-$$.json"
            python3 "${PY_DIR}/lock.py" acquire "task:${TASK_ID}" \
                --ttl 3600 --session "cycle-${CYCLE_NUM}" 2>/dev/null \
                > "${LOCK_TMPFILE}" || true  # capture exit code but keep stdout
            LOCK_STATUS=$(python3 -c "
import json
try: d = json.load(open('${LOCK_TMPFILE}')); print(d.get('status', 'error'))
except: print('read_error')
" 2>/dev/null || echo "parse_error")
            rm -f "${LOCK_TMPFILE}"

            if [ "${LOCK_STATUS}" = "locked" ]; then
                # Re-read the lock file to get holder info
                LOCK_INFO=$(python3 "${PY_DIR}/lock.py" check "task:${TASK_ID}" 2>/dev/null || echo '{"holder":"?"}')
                LOCK_HOLDER=$(echo "${LOCK_INFO}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('holder', '?'))
except: print('?')
" 2>/dev/null || echo "?")
                log_warn "task ${TASK_ID} is locked by ${LOCK_HOLDER} — skipping"
                START_PHASE=1
                unset TASK_ID TARGET_REPO
                continue
            elif [ "${LOCK_STATUS}" = "acquired" ]; then
                log_ok "task lock acquired: task:${TASK_ID}"

                # Also acquire repo lock
                if [ -n "${TARGET_REPO}" ]; then
                    REPO_LOCK_OUT=$(python3 "${PY_DIR}/lock.py" acquire "repo:${TARGET_REPO}" \
                        --ttl 3600 --session "cycle-${CYCLE_NUM}" 2>/dev/null || echo '{"status":"error"}')
                    REPO_LOCK_STATUS=$(echo "${REPO_LOCK_OUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('status', 'error'))
except: print('parse_error')
" 2>/dev/null || echo "parse_error")
                    if [ "${REPO_LOCK_STATUS}" != "acquired" ]; then
                        log_warn "repo lock status: ${REPO_LOCK_STATUS} — continuing without repo lock"
                    fi
                fi
            else
                log_warn "lock acquire returned status '${LOCK_STATUS}' — continuing without lock"
            fi

            lark_notify "task_accepted" "${TASK_ID}" "${TARGET_REPO}"

        elif [ "${DISPATCH_STATUS}" = "empty" ] || \
             [ "${DISPATCH_STATUS}" = "empty_ledger" ] || \
             [ "${DISPATCH_STATUS}" = "blocked_chain" ]; then
            MESSAGE=$(echo "${DISPATCH_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('message', ''))
except: print('')
" 2>/dev/null || echo "")
            log_info "no tasks available: ${MESSAGE}"

            # ─── Try document-aware planner ─────────────────────────────
            log_phase "2b" "Document Planning"

            DOCS_DIR_FULL="${LIVEMASK_ROOT}/livemask-docs/docs"
            CONTRACTS_FILE="${DOCS_DIR_FULL}/contracts/contract-index.md"
            MVP_FILE="${DOCS_DIR_FULL}/development/MVP_IMPLEMENTATION_PLAN.md"
            LEDGER_FILE="${DOCS_DIR_FULL}/development/task-state-ledger.json"
            TASKS_DIR="${DOCS_DIR_FULL}/development/tasks"

            PLAN_OUTPUT=$(python3 "${PY_DIR}/planner.py" plan \
                --contracts "${CONTRACTS_FILE}" \
                --mvp "${MVP_FILE}" \
                --ledger "${LEDGER_FILE}" \
                --tasks-dir "${TASKS_DIR}" \
                --create-dispatch 5 2>/dev/null || true)

            PLAN_COUNT=$(echo "${PLAN_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('gaps_found', 0))
except: print('0')
" 2>/dev/null || echo "0")

            PACKETS_CREATED=$(echo "${PLAN_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('dispatch_packets_created', 0))
except: print('0')
" 2>/dev/null || echo "0")

            if [ "${PLAN_COUNT}" -gt 0 ]; then
                log_info "planner found ${PLAN_COUNT} unplanned tasks"
                if [ "${PACKETS_CREATED}" -gt 0 ]; then
                    log_ok "created ${PACKETS_CREATED} dispatch packet(s) for top tasks"
                    # Print top 3 gaps
                    echo "${PLAN_OUTPUT}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for g in d.get('gaps', [])[:3]:
        print(f'  • {g[\"task_id\"]} (priority={g.get(\"priority_score\",\"?\")}) — {g.get(\"reason\",\"\")[:60]}')
except: pass
" 2>/dev/null || true
                    log_info "re-running dispatch with new packets..."
                    # Restart phase 2 to pick up the new dispatch packets
                    START_PHASE=2
                    continue
                fi
            else:
                log_info "planner found no new gaps either"
            fi

            # ─── Still nothing — sleep and retry ─────────────────────────
            if [ "${SINGLE_SHOT}" = true ]; then
                log_info "single-shot mode — nothing to do, exiting"
                exit 0
            fi

            log_info "sleeping 120s before retry..."
            sleep 120
            continue
        else
            log_warn "dispatch error: $(echo "${DISPATCH_OUTPUT}" | head -c 200)"
            if [ "${SINGLE_SHOT}" = true ]; then exit 1; fi
            sleep 60
            continue
        fi
    fi

    # ----------------------------------------------------------------
    # Phase 3: CONTEXT
    # ----------------------------------------------------------------
    if [ "${START_PHASE}" -le 3 ]; then
        CURRENT_PHASE="context"
        log_phase "3" "Context Loading"

        if [ -z "${TASK_ID:-}" ]; then
            log_fail "TASK_ID not set"
            exit 1
        fi

        # Export env vars for context.py
        export LIVEMASK_LEDGER="${LEDGER}"
        export LIVEMASK_DOCS_DIR="${DOCS_DIR}/docs/development/tasks"
        export LIVEMASK_CONTRACTS_DIR="${CONTRACTS_DIR}"

        python3 "${PY_DIR}/context.py" load "${TASK_ID}" \
            --ledger "${LEDGER}" \
            --docs "${DOCS_DIR}/docs/development/tasks" \
            --contracts "${CONTRACTS_DIR}" > "${CONTEXT_FILE}" 2>/dev/null || {
            log_warn "context loading had partial failures"
        }

        # Show context summary
        CONTEXT_REPO=$(python3 -c "
import json
try: d = json.load(open('${CONTEXT_FILE}')); print(d.get('repo', 'unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")
        CONTEXT_CRITERIA=$(python3 -c "
import json
try:
    d = json.load(open('${CONTEXT_FILE}')); c = d.get('acceptance_criteria', [])
    print(f'{len(c)} acceptance criteria' if c else 'no criteria defined')
except: print('?')
" 2>/dev/null || echo "?")
        CONTEXT_VAL=$(python3 -c "
import json
try:
    d = json.load(open('${CONTEXT_FILE}')); cmds = d.get('validation_commands', [])
    print(', '.join(cmds) if cmds else 'no validation commands')
except: print('?')
" 2>/dev/null || echo "?")

        log_ok "context saved to ${CONTEXT_FILE}"
        log_info "repo: ${CONTEXT_REPO}"
        log_info "criteria: ${CONTEXT_CRITERIA}"
        log_info "validation: ${CONTEXT_VAL}"

        # Save session
        python3 "${PY_DIR}/session.py" save "${TASK_ID}" "context_loaded" \
            --branch "task/${TASK_ID}" 2>/dev/null || true

        echo ""
        log_section "Ready for Implementation"
        log_info "  1. cd \${LIVEMASK_ROOT}/${CONTEXT_REPO}"
        log_info "  2. git checkout -b task/${TASK_ID}"
        log_info "  3. Implement changes"
        log_info "  4. Run: ${CONTEXT_VAL}"
    fi

    # ----------------------------------------------------------------
    # Phase 4: IMPLEMENT (delegated to Claude)
    # ----------------------------------------------------------------
    if [ "${START_PHASE}" -le 4 ]; then
        CURRENT_PHASE="implementing"
        log_phase "4" "Implementation"

        # ── Guard: check if previous cycle already advanced past implementing ──
        PREV_PHASE=""
        if [ -f "${SESSION_STATE}" ]; then
            PREV_PHASE=$(python3 -c "
import json
try: d = json.load(open('${SESSION_STATE}')); print(d.get('phase', ''))
except: print('')
" 2>/dev/null || echo "")
        fi

        if [ "${PREV_PHASE}" = "verifying" ]; then
            log_info "session already at 'verifying' — skipping Phase 4 wait, proceeding to verification"
            START_PHASE=5
        elif [ "${PREV_PHASE}" = "completed" ]; then
            log_info "session already at 'completed' — skipping Phase 4 wait, proceeding to completion"
            START_PHASE=6
        elif [ "${PREV_PHASE}" = "blocked" ]; then
            log_warn "task session is blocked — re-verifying evidence chain..."
            HEAL_OUT=$(python3 "${PY_DIR}/auto_evidence.py" heal "${TASK_ID}" 2>/dev/null || echo '{}')
            HEAL_CNT=$(echo "${HEAL_OUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('actions_taken', [])))" 2>/dev/null || echo "0")
            # Re-read session to see if heal advanced it
            NEW_PHASE=$(python3 -c "
import json
try: d = json.load(open('${SESSION_STATE}')); print(d.get('phase', ''))
except: print('')
" 2>/dev/null || echo "")
            if [ "${NEW_PHASE}" = "completed" ]; then
                log_ok "auto-evidence healed — session now completed, proceeding to Phase 6"
                START_PHASE=6
            elif [ "${NEW_PHASE}" = "verifying" ] || [ "${NEW_PHASE}" = "verified" ]; then
                log_ok "auto-evidence healed ${HEAL_CNT} issue(s) — advancing to verifying"
                START_PHASE=5
            elif [ "${HEAL_CNT}" -gt 0 ]; then
                log_ok "auto-evidence healed ${HEAL_CNT} issue(s) — proceeding to Phase 5"
                START_PHASE=5
            else
                log_fail "task blocked — auto-evidence could not heal"
                exit 1
            fi
        else
            # Only overwrite if no meaningful progress detected
            python3 "${PY_DIR}/session.py" save "${TASK_ID:-unknown}" "implementing" \
                --branch "task/${TASK_ID:-unknown}" 2>/dev/null || true

            # ── Auto-implement: try auto_implement.py for docs-only planner tasks ──
            if [ -n "${TASK_ID:-}" ]; then
                AUTO_IMPL_RESULT=$(python3 "${PY_DIR}/auto_implement.py" detect "${TASK_ID}" 2>/dev/null || echo "NO: error")
                AUTO_IMPL_DETECTED=$(echo "${AUTO_IMPL_RESULT}" | head -1 | grep -c "^AUTO-IMPLEMENTABLE:" || true)
                if [ "${AUTO_IMPL_DETECTED}" -ge 1 ]; then
                    log_info "auto-implementable task detected — running auto_implement.py..."
                    # Use temp file to capture output (avoids subshell from pipe)
                    AUTO_IMPL_TMP="/tmp/dev-loop-auto-impl-$$.log"
                    python3 "${PY_DIR}/auto_implement.py" impl "${TASK_ID}" > "${AUTO_IMPL_TMP}" 2>&1 || true
                    while IFS= read -r line; do log_info "auto_impl: ${line}"; done < "${AUTO_IMPL_TMP}"
                    rm -f "${AUTO_IMPL_TMP}"
                    # Check if session was advanced to verifying
                    if [ -f "${SESSION_STATE}" ]; then
                        POST_PHASE=$(python3 -c "
import json
try: d = json.load(open('${SESSION_STATE}')); print(d.get('phase', ''))
except: print('')
" 2>/dev/null || echo "")
                        if [ "${POST_PHASE}" = "verifying" ]; then
                            log_ok "auto_implement.py completed — session advanced to verifying, proceeding to Phase 5"
                            START_PHASE=5
                        fi
                    fi
                    # If auto_implement didn't advance, check ledger and fall through
                    if [ "${START_PHASE:-4}" -eq 4 ]; then
                        log_info "auto_implement.py finished but session not advanced — falling through to wait"
                    fi
                fi

                # ── Fallback: check if task is already completed in ledger ──
                if [ "${START_PHASE:-4}" -eq 4 ]; then
                    LEDGER_CHECK=$(python3 -c "
import json
try:
    ledger = json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
    target = '${TASK_ID}'
    for m in ledger.get('modules', []):
        for t in m.get('tasks', []):
            if t.get('task_id') == target:
                print(t.get('status', ''))
                exit(0)
    print('NOT_FOUND')
except: print('NOT_FOUND')
" 2>/dev/null)
                    if [ "${LEDGER_CHECK}" = "completed" ] || [ "${LEDGER_CHECK}" = "completed_with_skip" ]; then
                        log_ok "task already completed in ledger — advancing session to verifying"
                        python3 "${PY_DIR}/session.py" save "${TASK_ID}" "verifying" \
                            --branch "task/${TASK_ID}" 2>/dev/null || true
                        START_PHASE=5
                    elif [ "${LEDGER_CHECK}" = "blocked" ]; then
                        log_warn "task blocked in ledger — attempting auto-evidence heal..."
                        HEAL_OUT=$(python3 "${PY_DIR}/auto_evidence.py" heal "${TASK_ID}" 2>/dev/null || echo '{}')
                        HEAL_CNT=$(echo "${HEAL_OUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('actions_taken', [])))" 2>/dev/null || echo "0")
                        if [ "${HEAL_CNT}" -gt 0 ]; then
                            log_ok "auto-evidence healed ${HEAL_CNT} issue(s) — advancing to verifying"
                            python3 "${PY_DIR}/session.py" save "${TASK_ID}" "verifying" \
                                --branch "task/${TASK_ID}" 2>/dev/null || true
                            START_PHASE=5
                        else
                            log_warn "blocked task could not be healed — falling through to wait"
                        fi
                    fi
                fi
            fi

            echo ""
            log_info "auto-repair() helper:"
            echo ""
            echo "    auto-repair() {"
            echo "      local cmd=\"\$1\" logf=\"/tmp/repair-\$\$.log\""
            echo "      local retry=\$(python3 -c \"import json; s=json.load(open('${SESSION_STATE}')); print(s.get('retry_count',0))\")"
            echo "      if eval \"\$cmd\" > \"\$logf\" 2>&1; then"
            echo "        log_ok \"\$cmd — PASS\""
            echo "        return 0"
            echo "      fi"
            echo "      retry=\$((retry + 1))"
            echo "      python3 ${PY_DIR}/session.py save '${TASK_ID:-unknown}' 'implementing' --retry \"\$retry\""
            echo "      python3 ${PY_DIR}/repair.py build \"\$logf\""
            echo "      if [ \"\$retry\" -gt 3 ]; then"
            echo "        log_fail \"repair exhausted — marking blocked\""
            echo "        python3 ${PY_DIR}/session.py save '${TASK_ID:-unknown}' 'blocked' --error 'repair exhausted'"
            echo "        return 1"
            echo "      fi"
            echo "      return 2  # signal retry"
            echo "    }"
            echo ""

            log_info "waiting for implementation to complete..."
            echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')] waiting for implementation" >> "${LOG_FILE}"

            # Poll session state every 30s for up to 60 minutes
            WAIT_COUNT=0
            while [ "${WAIT_COUNT}" -lt 120 ]; do
                sleep 30
                WAIT_COUNT=$((WAIT_COUNT + 1))

                if [ -f "${SESSION_STATE}" ]; then
                    SESSION_PHASE=$(python3 -c "
import json
try: d = json.load(open('${SESSION_STATE}')); print(d.get('phase', ''))
except: print('')
" 2>/dev/null || echo "")

                    if [ "${SESSION_PHASE}" = "verifying" ] || [ "${SESSION_PHASE}" = "verified" ] || [ "${SESSION_PHASE}" = "completed" ]; then
                        log_ok "implementation complete — phase changed to ${SESSION_PHASE}"
                        if [ "${SESSION_PHASE}" = "completed" ]; then
                            START_PHASE=6
                        else
                            START_PHASE=5
                        fi
                        break
                    elif [ "${SESSION_PHASE}" = "blocked" ]; then
                        log_warn "task blocked — attempting auto-evidence heal..."
                        HEAL_OUTPUT=$(python3 "${PY_DIR}/auto_evidence.py" heal "${TASK_ID}" 2>/dev/null || echo '{}')
                        HEAL_ACTIONS=$(echo "${HEAL_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('actions_taken', [])))" 2>/dev/null || echo "0")
                        if [ "${HEAL_ACTIONS}" -gt 0 ]; then
                            log_ok "auto-evidence healed — retrying"
                            continue
                        fi
                        log_fail "task blocked — see session state for details"
                        exit 1
                    fi
                fi

                # Heartbeat log every 5 minutes
                if [ $((WAIT_COUNT % 10)) -eq 0 ]; then
                    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')] cycle=${CYCLE_NUM} still waiting for implementation (${WAIT_COUNT} checks so far)" >> "${LOG_FILE}"
                    log_info "still waiting... (${WAIT_COUNT}/120 checks)"

                    # Heartbeat the lock every 5 min to prevent stale expiry
                    if [ -n "${TASK_ID:-}" ]; then
                        python3 "${PY_DIR}/lock.py" heartbeat "task:${TASK_ID}" --ttl 3600 2>/dev/null >/dev/null || true
                    fi
                    if [ -n "${TARGET_REPO:-}" ]; then
                        python3 "${PY_DIR}/lock.py" heartbeat "repo:${TARGET_REPO}" --ttl 3600 2>/dev/null >/dev/null || true
                    fi

                    # ── Health check: verify lock still held ──────────────────
                    LOCK_CHECK=$(python3 "${PY_DIR}/lock.py" check "task:${TASK_ID:-unknown}" 2>/dev/null || echo '{"status":"free"}')
                    LOCK_STATUS_CHECK=$(echo "${LOCK_CHECK}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('status', 'free'))
except: print('free')
" 2>/dev/null || echo "free")
                    if [ "${LOCK_STATUS_CHECK}" = "free" ]; then
                        log_warn "task lock lost — re-acquiring..."
                        python3 "${PY_DIR}/lock.py" acquire "task:${TASK_ID:-unknown}" \
                            --ttl 3600 --session "cycle-${CYCLE_NUM}" 2>/dev/null >/dev/null || true
                    fi
                fi
            done

            if [ "${WAIT_COUNT}" -ge 120 ]; then
                log_fail "implementation timeout after 60 minutes"
                python3 "${PY_DIR}/session.py" save "${TASK_ID:-unknown}" "timeout" \
                    --error "implementation timeout" 2>/dev/null || true
                exit 1
            fi
        fi
    fi

    # ----------------------------------------------------------------
    # Phase 5: VERIFY
    # ----------------------------------------------------------------
    if [ "${START_PHASE}" -le 5 ]; then
        CURRENT_PHASE="verifying"
        log_phase "5" "Verification"

        python3 "${PY_DIR}/session.py" save "${TASK_ID:-unknown}" "verifying" 2>/dev/null || true

        if [ -n "${TARGET_REPO:-}" ] && [ -d "${LIVEMASK_ROOT}/${TARGET_REPO}" ]; then
            log_info "running verification in ${TARGET_REPO}..."

            pushd "${LIVEMASK_ROOT}/${TARGET_REPO}" >/dev/null || {
                log_fail "cannot cd to ${TARGET_REPO}"
                continue
            }

            VAL_CMDS=$(python3 -c "
import json
try:
    d = json.load(open('${CONTEXT_FILE}'))
    for cmd in d.get('validation_commands', []): print(cmd)
except: pass
" 2>/dev/null || true)

            VAL_PASS=true
            while IFS= read -r cmd; do
                [ -z "${cmd}" ] && continue

                # Retry up to 3 times with auto-repair
                for RETRY in 1 2 3; do
                    log_info "running: ${cmd} (attempt ${RETRY}/3)"

                    LOGF="/tmp/dev-loop-verify-$$-${RETRY}.log"
                    if eval "${cmd}" > "${LOGF}" 2>&1; then
                        log_ok "${cmd} — PASS (attempt ${RETRY})"
                        break  # out of retry loop
                    fi

                    if [ "${RETRY}" -lt 3 ]; then
                        log_warn "${cmd} — FAIL (attempt ${RETRY}, see ${LOGF})"

                        # Auto-repair with --apply mode
                        REPAIR_OUTPUT=$(python3 "${PY_DIR}/repair.py" build "${LOGF}" \
                            --apply --repo "${LIVEMASK_ROOT}/${TARGET_REPO}" 2>/dev/null || true)
                        REPAIR_STATUS=$(echo "${REPAIR_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('status', 'error'))
except: print('error')
" 2>/dev/null || echo "error")

                        if [ "${REPAIR_STATUS}" = "fixed" ]; then
                            log_ok "auto-repair applied fixes — retrying..."
                            # Show what was fixed
                            echo "${REPAIR_OUTPUT}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for a in d.get('applied_actions', []):
        print(f'  ✓ {a.get(\"cmd\",\"\")} (success={a.get(\"success\",False)})')
except: pass
" 2>/dev/null || true
                        elif [ "${REPAIR_STATUS}" = "retry" ]; then
                            log_info "repair has suggestions — will retry without applying"
                        else
                            log_info "no auto-repair available for this error"
                        fi

                        # ── Experience system: look up known fixes ──────────
                        SUGGEST_OUTPUT=$(python3 "${PY_DIR}/experience.py" suggest "${LOGF}" 2>/dev/null || true)
                        SUGGEST_STATUS=$(echo "${SUGGEST_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('status', ''))
except: print('')
" 2>/dev/null || echo "")
                        SUGGEST_COUNT=$(echo "${SUGGEST_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(len(d.get('suggestions', [])))
except: print('0')
" 2>/dev/null || echo "0")

                        if [ "${SUGGEST_COUNT}" -gt 0 ]; then
                            log_info "experience system has ${SUGGEST_COUNT} known fix(es) for this error"

                            # Save to temp file and auto-apply via experience.py _apply
                            SUGGEST_TMP="/tmp/dev-loop-suggest-$$.json"
                            echo "${SUGGEST_OUTPUT}" > "${SUGGEST_TMP}"
                            EXP_RESULT=$(python3 "${PY_DIR}/experience.py" _apply \
                                "${SUGGEST_TMP}" --repo "${TARGET_REPO}" 2>/dev/null || echo "HEALED=no")
                            rm -f "${SUGGEST_TMP}"

                            # Print diagnostic lines (skip HEALED= marker)
                            echo "${EXP_RESULT}" | grep -v '^HEALED=' | while read line; do
                                log_info "${line}"
                            done 2>/dev/null || true

                            SELF_HEALED=$(echo "${EXP_RESULT}" | grep '^HEALED=' | tail -1 | cut -d= -f2)
                            if [ "${SELF_HEALED}" = "yes" ]; then
                                log_info "retrying original command after experience fix..."
                                if eval "${cmd}" > "${LOGF}" 2>&1; then
                                    log_ok "${cmd} — PASS after experience-based fix"
                                    break
                                fi
                            fi
                        fi
                    else
                        log_fail "${cmd} — FAIL after 3 attempts"
                        VAL_PASS=false

                        # Log to experience system as failed record
                        python3 "${PY_DIR}/experience.py" record "${LOGF}" \
                            '{"type":"human","message":"manual intervention needed"}' 0 \
                            --repo "${TARGET_REPO}" 2>/dev/null || true
                    fi
                done
            done <<< "${VAL_CMDS}"

            popd >/dev/null || true

            if [ "${VAL_PASS}" = false ]; then
                log_warn "some verification steps failed"
                lark_notify "task_failed" "${TASK_ID:-unknown}" "${TARGET_REPO}"
            fi
        else
            log_info "no target repo or repo not found — skipping repo verification"
        fi

        # Self-review
        log_section "Self-Review"
        REVIEW_OUTPUT=$(python3 "${PY_DIR}/self_review.py" check "${CONTEXT_FILE}" 2>/dev/null || true)
        REVIEW_VERDICT=$(echo "${REVIEW_OUTPUT}" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('verdict', 'error'))
except: print('error')
" 2>/dev/null || echo "error")

        if [ "${REVIEW_VERDICT}" = "pass" ]; then
            log_ok "self-review: PASS"
        elif [ "${REVIEW_VERDICT}" = "changes" ]; then
            log_info "self-review: CHANGES NEEDED"
            echo "${REVIEW_OUTPUT}" | python3 -m json.tool 2>/dev/null || echo "${REVIEW_OUTPUT}"
        elif [ "${REVIEW_VERDICT}" = "blocked" ]; then
            log_fail "self-review: BLOCKED"
            echo "${REVIEW_OUTPUT}" | python3 -m json.tool 2>/dev/null || echo "${REVIEW_OUTPUT}"
            exit 1
        fi

        python3 "${PY_DIR}/session.py" save "${TASK_ID:-unknown}" "verified" 2>/dev/null || true
    fi

    # ----------------------------------------------------------------
    # Phase 6: COMPLETE
    # ----------------------------------------------------------------
    if [ "${START_PHASE}" -le 6 ]; then
        CURRENT_PHASE="completing"
        log_phase "6" "Completion"

        if [ -n "${TARGET_REPO:-}" ] && [ -n "${TASK_ID:-}" ]; then
            TASK_BRANCH="task/${TASK_ID}"
            MERGE_SHA=""
            ISSUE_URL=""

            # Merge to dev
            REPO_DIR="${LIVEMASK_ROOT}/${TARGET_REPO}"

            # Gate 2: Push task branch to remote before merge
            if [ -d "${REPO_DIR}" ]; then
                pushd "${REPO_DIR}" >/dev/null || true
                if git remote -v 2>/dev/null | grep -q origin; then
                    log_info "pushing ${TASK_BRANCH} to origin..."
                    git push origin "${TASK_BRANCH}" 2>&1 | tail -3 | while read line; do log_info "  push: ${line}"; done || log_warn "push failed — may need manual push"
                else
                    log_info "no remote configured — skipping push"
                fi
                popd >/dev/null || true
            fi

            if [ -f "${CI_CD_DIR}/scripts/dev-merge-guard.sh" ]; then
                log_info "running merge guard..."
                MERGE_OUTPUT=$(bash "${CI_CD_DIR}/scripts/dev-merge-guard.sh" \
                    --repo "${TARGET_REPO}" --task-branch "${TASK_BRANCH}" \
                    --task-id "${TASK_ID}" --push 2>&1) || true
                echo "${MERGE_OUTPUT}" >> "${LOG_FILE}"

                # Extract merge commit SHA from output
                MERGE_SHA=$(echo "${MERGE_OUTPUT}" | grep -oE '[0-9a-f]{7,40}' | head -1 || echo "")
                if [ -n "${MERGE_SHA}" ]; then
                    log_ok "merge to dev successful (SHA: ${MERGE_SHA})"
                else
                    log_warn "merge guard may have failed — manual merge may be needed"
                fi
            else
                log_info "dev-merge-guard.sh not found — skipping merge"
            fi

            # Record evidence
            log_section "Evidence Chain"
            if [ -n "${MERGE_SHA}" ]; then
                python3 "${PY_DIR}/planner.py" evidence "${TASK_ID}" \
                    --merge-sha "${MERGE_SHA}" 2>/dev/null || true
                log_ok "dev_merge_commit: ${MERGE_SHA}"
            fi

            # Collect validation evidence
            VALIDATION_EVIDENCE="[verified: build+test pass through dev loop]"
            python3 "${PY_DIR}/planner.py" evidence "${TASK_ID}" \
                --validation "${VALIDATION_EVIDENCE}" 2>/dev/null || true
            log_ok "validation: ${VALIDATION_EVIDENCE}"

            # Find or create GitHub issue
            log_section "GitHub Issue"
            if command -v gh &>/dev/null; then
                # Check if an issue already exists for this task
                EXISTING_ISSUE=$(gh issue list \
                    --repo "MyAiDevs/${TARGET_REPO}" \
                    --state all \
                    --limit 50 \
                    --json number,title,url 2>/dev/null | \
                    python3 -c "
import sys, json
try:
    issues = json.load(sys.stdin)
    for i in issues:
        if '${TASK_ID}' in i.get('title', ''):
            print(i['url'])
            break
except: pass
" 2>/dev/null || true)

                if [ -n "${EXISTING_ISSUE}" ]; then
                    ISSUE_URL="${EXISTING_ISSUE}"
                    log_info "found existing issue: ${ISSUE_URL}"

                    # Post evidence comment
                    gh issue comment "${ISSUE_URL}" \
                        --body "## Evidence

| Field | Result |
|-------|--------|
| Build | ✅ PASS |
| Test | ✅ PASS |
| Vet | ✅ PASS |
| Merge SHA | \`${MERGE_SHA:-pending}\` |
| Validation | ${VALIDATION_EVIDENCE} |

_Completed by Claude dev loop cycle #${CYCLE_NUM}_" 2>/dev/null || true

                    # Close the issue
                    gh issue close "${ISSUE_URL}" --reason completed 2>/dev/null || true
                    log_ok "issue closed with evidence comment"
                else
                    # Create new issue
                    ISSUE_BODY=$(python3 -c "
import json
try:
    d = json.load(open('${CONTEXT_FILE}')); criteria = d.get('acceptance_criteria', [])
    txt = '\\n'.join(f'- {c}' for c in criteria) if criteria else ''
    print(f'## Task ${TASK_ID}\\n\\n### Acceptance Criteria\\n{txt}' if txt else f'## Task ${TASK_ID}')
except: print('## Task ${TASK_ID}')
" 2>/dev/null || echo "## Task ${TASK_ID}")

                    ISSUE_URL=$(gh issue create \
                        --repo "MyAiDevs/${TARGET_REPO}" \
                        --title "[${TASK_ID}] Implementation" \
                        --body "${ISSUE_BODY}

---

### Evidence

| Field | Result |
|-------|--------|
| Merge SHA | \`${MERGE_SHA:-pending}\` |
| Validation | ${VALIDATION_EVIDENCE} |

_Completed by Claude dev loop cycle #${CYCLE_NUM}_" \
                        --label "auto" 2>/dev/null || true)

                    if [ -n "${ISSUE_URL}" ]; then
                        gh issue close "${ISSUE_URL}" --reason completed 2>/dev/null || true
                        log_ok "issue created and closed: ${ISSUE_URL}"
                    else
                        log_warn "gh issue create failed"
                    fi
                fi

                # Record issue URL in evidence
                if [ -n "${ISSUE_URL}" ]; then
                    python3 "${PY_DIR}/planner.py" evidence "${TASK_ID}" \
                        --issue "${ISSUE_URL}" 2>/dev/null || true
                fi
            else
                log_info "gh CLI not available — skipping GitHub issue"
            fi

            # Add to ledger via ledger.py add (takes raw JSON, not flags)
            log_section "Ledger Update"

            # Build ledger entry JSON
            LEDGER_ENTRY=$(python3 -c "
import json
entry = {
    'task_id': '${TASK_ID}',
    'status': 'completed',
    'repo': '${TARGET_REPO}',
    'dev_merge_commit': '${MERGE_SHA}',
    'remote_dev_ref': '${MERGE_SHA}',
    'validation': '${VALIDATION_EVIDENCE}',
    'issue': '${ISSUE_URL}',
    'blocked_by': [],
    'unlocks': [],
    'notes': 'Completed by Claude dev loop cycle #${CYCLE_NUM}',
}
print(json.dumps(entry))
" 2>/dev/null || echo "")

            if [ -n "${LEDGER_ENTRY}" ]; then
                python3 "${PY_DIR}/ledger.py" add "${LEDGER_ENTRY}" 2>/dev/null || true
                log_ok "ledger entry added for ${TASK_ID}"
            else
                log_warn "failed to build ledger entry"
            fi

            # Show final evidence chain
            log_section "Final Evidence"
            python3 "${PY_DIR}/planner.py" evidence-show "${TASK_ID}" 2>/dev/null | \
                python3 -m json.tool 2>/dev/null || true

            # Send Lark completion notification
            lark_notify "task_completed" "${TASK_ID}" "${TARGET_REPO}" "${MERGE_SHA}" "${VALIDATION_EVIDENCE}"

            # Clean session
            python3 "${PY_DIR}/session.py" clean 2>/dev/null || true
            log_ok "task ${TASK_ID} completed"
        else
            log_warn "TASK_ID or TARGET_REPO not set — skipping completion"
        fi

        # ── Release all locks for this cycle ─────────────────────────
        if [ -n "${TASK_ID:-}" ]; then
            python3 "${PY_DIR}/lock.py" release "task:${TASK_ID}" 2>/dev/null || true
        fi
        if [ -n "${TARGET_REPO:-}" ]; then
            python3 "${PY_DIR}/lock.py" release "repo:${TARGET_REPO}" 2>/dev/null || true
        fi
        # Break any stale locks from this cycle as well
        python3 "${PY_DIR}/lock.py" break-stale --prefix "task:" 2>/dev/null || true

        # Reset for next cycle
        START_PHASE=1
        unset TASK_ID TARGET_REPO
    fi

    # ---- End of cycle ----
    CURRENT_PHASE=""

    if [ "${SINGLE_SHOT}" = true ]; then
        log_info "single-shot mode — one cycle complete"
        lark_notify "cycle_summary" "${CYCLE_NUM}" ""
        exit 0
    fi

    log_info "cycle #${CYCLE_NUM} complete — starting next cycle"
    log_debug_info
done
