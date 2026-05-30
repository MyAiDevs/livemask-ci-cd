#!/usr/bin/env bash
# TASK-CICD-CLAUDE-LOOP-STARTUP-001
# Deterministic startup sequence for Claude /loop.
# Every Claude session starts here. No guessing, no aimless exploration.
#
# Usage:
#   bash scripts/claude-loop-startup.sh              # full startup
#   bash scripts/claude-loop-startup.sh --recovery   # recovery only
#   bash scripts/claude-loop-startup.sh --quick      # skip preflight, use cached state
set -euo pipefail

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
AGENT_STATE="${LIVEMASK_ROOT}/.claude/agent-state.json"
ADAPTER_LIB="${CI_CD_DIR}/scripts/event-adapters/lib/adapter-lib.sh"

MODE="${1:-full}"

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }
ok()      { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
fail()    { echo -e "  ${RED}[FAIL]${RESET} $*"; }
info()    { echo -e "  ${CYAN}[..]${RESET} $*"; }

# ── Step 0: Read agent state ──────────────────────────────────────────────────
read_agent_state() {
  header "Step 0: Agent State"
  if [[ ! -f "${AGENT_STATE}" ]]; then
    warn "no agent-state.json — treating as fresh start"
    AGENT_PHASE="idle"
    CURRENT_TASK="null"
    TASK_PHASE="null"
    TARGET_REPO=""
    TASK_BRANCH=""
    LAST_ACTION=""
    return 0
  fi

  AGENT_PHASE=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('phase','idle'))" 2>/dev/null || echo "idle")
  CURRENT_TASK=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('task_id') or 'null')" 2>/dev/null || echo "null")
  TASK_PHASE=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('phase') or 'null')" 2>/dev/null || echo "null")
  TARGET_REPO=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('target_repo') or '')" 2>/dev/null || echo "")
  TASK_BRANCH=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('task_branch') or '')" 2>/dev/null || echo "")
  LAST_ACTION=$(python3 -c "import json; d=json.load(open('${AGENT_STATE}')); print(d.get('current_task',{}).get('last_action') or '')" 2>/dev/null || echo "")

  echo ""
  echo "  phase:        ${AGENT_PHASE}"
  echo "  task_id:      ${CURRENT_TASK}"
  echo "  task_phase:   ${TASK_PHASE}"
  echo "  target_repo:  ${TARGET_REPO:-none}"
  echo "  task_branch:  ${TASK_BRANCH:-none}"
  echo "  last_action:  ${LAST_ACTION:-none}"
}

# ── Step 1: Recovery check ────────────────────────────────────────────────────
run_recovery() {
  header "Step 1: Recovery Check"

  # 1a. Sync docs first (always)
  info "syncing livemask-docs/dev..."
  cd "${DOCS_DIR}"
  if git switch dev 2>/dev/null && git pull --ff-only origin dev 2>/dev/null; then
    DOCS_HEAD=$(git rev-parse --short HEAD)
    ok "docs/dev at ${DOCS_HEAD}"
  else
    fail "docs/dev sync failed — may be dirty or diverged"
  fi

  # 1b. Check for orphaned task branches
  info "scanning for orphaned task branches..."
  local orphaned=0
  for repo_dir in "${LIVEMASK_ROOT}"/livemask-*/; do
    local repo_name
    repo_name=$(basename "${repo_dir}")
    [[ "${repo_name}" == "livemask-docs" ]] && continue
    [[ "${repo_name}" == "livemask-ci-cd" ]] && continue
    [[ ! -d "${repo_dir}/.git" ]] && continue

    cd "${repo_dir}"
    local branches
    branches=$(git branch --list 'task/*' --format='%(refname:short)' 2>/dev/null || true)
    if [[ -n "${branches}" ]]; then
      while IFS= read -r branch; do
        [[ -z "${branch}" ]] && continue
        local branch_sha
        branch_sha=$(git rev-parse --short "${branch}" 2>/dev/null || echo "?")
        local branch_date
        branch_date=$(git log -1 --format=%ar "${branch}" 2>/dev/null || echo "?")
        echo "  ${repo_name}: ${branch} (${branch_sha}, ${branch_date})"
        orphaned=$((orphaned + 1))
      done <<< "${branches}"
    fi
  done

  if [[ "${orphaned}" -eq 0 ]]; then
    ok "no orphaned task branches"
  else
    warn "${orphaned} task branch(es) found — if current_task is null, these need attention"
  fi

  # 1c. Check for dirty worktrees
  info "checking for dirty worktrees..."
  local dirty=0
  cd "${DOCS_DIR}"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "livemask-docs: DIRTY"
    dirty=$((dirty + 1))
  fi
  for repo_dir in "${LIVEMASK_ROOT}"/livemask-backend "${LIVEMASK_ROOT}"/livemask-admin; do
    local rn
    rn=$(basename "${repo_dir}")
    [[ ! -d "${repo_dir}/.git" ]] && continue
    cd "${repo_dir}"
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      warn "${rn}: DIRTY"
      dirty=$((dirty + 1))
    fi
  done
  if [[ "${dirty}" -eq 0 ]]; then
    ok "all worktrees clean"
  fi

  # 1d. Decision
  if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
    echo ""
    echo -e "${BOLD}${YELLOW}>>> RECOVERY PATH: phase=${AGENT_PHASE}, task=${CURRENT_TASK}${RESET}"
    echo "  task_phase: ${TASK_PHASE}"
    echo "  last_action: ${LAST_ACTION:-none}"
    echo ""
    echo "  Claude must:"
    echo "  1. Read agent-state.json for recovery context"
    echo "  2. bash ${ADAPTER_LIB} task-context ${CURRENT_TASK}"
    echo "  3. Read the required_first_reads from the context bundle"
    echo "  4. Continue from last_action: ${LAST_ACTION:-none}"
    echo "  5. Do NOT accept new tasks until this one reaches closure"
    return 10  # signal: recovery path
  fi

  ok "no recovery needed — agent phase is ${AGENT_PHASE}"
  return 0
}

# ── Step 2: Preflight ─────────────────────────────────────────────────────────
run_preflight() {
  header "Step 2: Preflight"
  local preflight_rc=0

  bash "${CI_CD_DIR}/scripts/claude-loop-preflight.sh" || preflight_rc=$?

  echo ""
  case "${preflight_rc}" in
    0) ok "preflight: IDLE — no work, entering monitor mode";;
    1) echo -e "${BOLD}${YELLOW}>>> preflight: WORK_AVAILABLE — proceed to task context${RESET}";;
    2) echo -e "${BOLD}${RED}>>> preflight: BLOCKED — resolve blockers first${RESET}";;
    *) warn "preflight: unexpected exit code ${preflight_rc}";;
  esac
  return "${preflight_rc}"
}

# ── Step 3: Build task context ────────────────────────────────────────────────
build_task_context() {
  header "Step 3: Task Context"

  info "getting top dispatchable task from planner..."
  local top_task
  top_task=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
    python3 -c "
import json,sys
d = json.load(sys.stdin)
tasks = [t for t in d.get('global_next',[]) if t.get('readiness') == 'dispatch_now']
if tasks:
    t = tasks[0]
    print(f\"{t['task_id']}|{t['repo']}|{t['status']}|{t['priority']}\")
else:
    print('NONE')
" 2>/dev/null || echo "NONE")

  if [[ "${top_task}" == "NONE" ]]; then
    warn "no dispatch_now tasks — checking for dispatch_for_evidence..."
    top_task=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "
import json,sys
d = json.load(sys.stdin)
tasks = [t for t in d.get('global_next',[]) if t.get('readiness') in ('dispatch_for_evidence','dispatch_with_issue_gap')]
if tasks:
    t = tasks[0]
    print(f\"{t['task_id']}|{t['repo']}|{t['status']}|{t['priority']}\")
else:
    print('NONE')
" 2>/dev/null || echo "NONE")
  fi

  if [[ "${top_task}" == "NONE" ]]; then
    warn "no dispatchable tasks found — checking open modules..."
    python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | \
      python3 -c "
import json,sys
d = json.load(sys.stdin)
modules = d.get('open_modules',[])
for m in modules[:5]:
    print(f\"  {m['module_id']}: {m['overall_status']}\")
"
    return 1
  fi

  local task_id repo status priority
  task_id="${top_task%%|*}"
  top_task="${top_task#*|}"
  repo="${top_task%%|*}"
  top_task="${top_task#*|}"
  status="${top_task%%|*}"
  priority="${top_task##*|}"

  echo ""
  echo -e "${BOLD}Top dispatchable task:${RESET}"
  echo "  task_id:   ${task_id}"
  echo "  repo:      ${repo}"
  echo "  status:    ${status}"
  echo "  priority:  ${priority}"

  # Build the context bundle
  echo ""
  info "building context bundle..."
  bash "${ADAPTER_LIB}" task-context "${task_id}" 2>/dev/null | python3 -c "
import json,sys
bundle = json.load(sys.stdin)
print(f\"  required_first_reads: {len(bundle.get('required_first_reads',[]))} files\")
for f in bundle.get('required_first_reads',[]):
    mark = '[EXISTS]' if f.get('exists') else '[MISSING]'
    print(f\"    {mark} {f['path']} — {f.get('reason','')}\")
print(f\"  domain_roots: {len(bundle.get('domain_roots',[]))} dirs\")
print(f\"  recommended_searches: {len(bundle.get('recommended_searches',[]))}\")
reminders = bundle.get('closure_reminders',[])
if reminders:
    print(f\"  closure_reminders: {len(reminders)}\")
    for r in reminders:
        print(f\"    REMINDER: {r}\")
" 2>/dev/null || warn "could not parse context bundle"

  # Also show ledger entry
  echo ""
  info "ledger entry:"
  bash "${ADAPTER_LIB}" task-ledger-entry "${task_id}" 2>/dev/null | python3 -c "
import json,sys
entry = json.load(sys.stdin)
print(f\"  status:     {entry.get('status','?')}\")
print(f\"  repo:       {entry.get('repo','?')}\")
print(f\"  issue:      {entry.get('issue','?')}\")
print(f\"  validation: {entry.get('validation','?')[:120]}\")
blocked = entry.get('blocked_by',[])
if blocked:
    print(f\"  blocked_by: {', '.join(blocked)}\")
notes = entry.get('notes','')
if notes:
    print(f\"  notes:      {notes[:200]}\")
" 2>/dev/null || warn "could not parse ledger entry"

  # Show repo doc hints
  echo ""
  info "repo doc hints:"
  bash "${ADAPTER_LIB}" repo-doc-hints "${repo}" 2>/dev/null | while IFS=$'\t' read -r r p; do
    echo "  ${r}: ${p}"
  done || true

  return 0
}

# ── Step 4: Fixed channels ───────────────────────────────────────────────────
check_fixed_channels() {
  header "Step 4: Fixed Control Channels"

  for pair in "MyAiDevs/livemask-ci-cd:14" "MyAiDevs/livemask-docs:68"; do
    local repo="${pair%%:*}"
    local num="${pair##*:}"
    info "${repo}#${num}..."

    local summary
    summary=$(gh issue view "${num}" --repo "${repo}" --json state,updatedAt,comments --jq '
"state=\(.state) updated=\(.updatedAt) comments=\(.comments | length)"
' 2>/dev/null || echo "FETCH_FAILED")

    echo "  ${summary}"

    # Check latest comment for actionable keywords
    local latest_keywords
    latest_keywords=$(gh issue view "${num}" --repo "${repo}" --json comments --jq '
[.comments[-1].body | scan("ACTION_NEEDED|RULE_UPDATE|ENFORCE|PROCESS_DEFECT|WAIT_TASK|WAIT_CI|PERMANENT_CHANNEL")] | join(",")
' 2>/dev/null || echo "")

    if [[ -n "${latest_keywords}" ]]; then
      echo -e "  ${RED}>>> latest comment contains: ${latest_keywords}${RESET}"
    else
      ok "no actionable keywords in latest comment"
    fi
  done
}

# ── Step 5: Event cache ──────────────────────────────────────────────────────
check_event_cache() {
  header "Step 5: Event Cache (accelerator only)"
  local cache_file="${LIVEMASK_ROOT}/.claude/event-cache/event-cache.jsonl"

  if [[ ! -f "${cache_file}" ]]; then
    info "no event cache — first run or pollers not yet executed"
    return 0
  fi

  local line_count
  line_count=$(wc -l < "${cache_file}" 2>/dev/null | tr -d ' ' || echo "0")
  echo "  events in cache: ${line_count}"

  if [[ "${line_count}" -gt 0 ]]; then
    local last_events
    last_events=$(tail -5 "${cache_file}" 2>/dev/null | python3 -c "
import json,sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        print(f\"  {e.get('event_type','?')} | {e.get('source','?')} | {e.get('ts','?')}\")
    except: pass
" 2>/dev/null || echo "  (parse error)")
    echo "${last_events}"
  fi

  echo ""
  echo "  Event cache is accelerator only. Authoritative state is GitHub + ledger."
}

# ── Step 6: Decision summary ─────────────────────────────────────────────────
decision_summary() {
  header "Step 6: Decision"

  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  STARTUP COMPLETE${RESET}"
  echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
  echo ""
  echo "  agent phase:   ${AGENT_PHASE}"
  echo "  current task:  ${CURRENT_TASK}"
  echo "  task phase:    ${TASK_PHASE}"

  if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}>>> RECOVERING: Continue ${CURRENT_TASK} from phase ${TASK_PHASE}${RESET}"
    echo "  Last action: ${LAST_ACTION:-none}"
    echo ""
    echo "  NEXT: bash ${ADAPTER_LIB} task-context ${CURRENT_TASK}"
  elif [[ "${AGENT_PHASE}" == "idle" ]]; then
    echo ""
    echo -e "  ${BOLD}${GREEN}>>> READY: Accept top dispatchable task and begin implementation${RESET}"
    echo ""
    echo "  BEFORE implementing:"
    echo "  1. Read ALL required_first_reads from the context bundle"
    echo "  2. Read the relevant domain docs for the target repo"
    echo "  3. Read the linked GitHub issue (body + comments)"
    echo "  4. Read the task doc under docs/development/tasks/"
    echo "  5. Run the recommended searches for existing references"
    echo "  6. Update agent-state.json: phase=implementing"
  else
    echo ""
    echo -e "  ${BOLD}${GREEN}>>> MONITORING: Idle until event or /loop wake${RESET}"
  fi
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${MODE}" in
  --recovery)
    read_agent_state
    run_recovery
    ;;
  --quick)
    read_agent_state
    if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
      run_recovery
      decision_summary
    else
      echo "quick mode: agent is idle, nothing to recover"
    fi
    ;;
  *)
    read_agent_state

    # If in a non-idle phase, go straight to recovery
    if [[ "${AGENT_PHASE}" != "idle" && "${AGENT_PHASE}" != "idle_monitor" ]]; then
      run_recovery
      decision_summary
      exit $?
    fi

    # Full startup: recovery + preflight + context + channels + cache
    run_recovery || true  # recovery warnings don't block
    preflight_rc=0
    run_preflight || preflight_rc=$?

    if [[ "${preflight_rc}" -eq 2 ]]; then
      echo ""
      echo -e "${BOLD}${RED}BLOCKED — resolve the blockers listed above before accepting tasks.${RESET}"
      exit 2
    fi

    # Always build context so Claude knows what to read
    build_task_context || warn "context build returned non-zero"

    # Remaining checks (informational — don't block on cache being stale)
    check_fixed_channels || true
    check_event_cache || true

    decision_summary
    ;;
esac
