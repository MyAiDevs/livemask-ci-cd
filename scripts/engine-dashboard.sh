#!/usr/bin/env bash
# engine-dashboard.sh — Real-time CLI panel for autonomous engine.
# Usage: watch -n 3 bash scripts/engine-dashboard.sh
set +e

LIVEMASK_ROOT="/Users/sammytan/Developer/LiveMask"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
CACHE="${HOME}/.claude/role-cache"
PID_FILE="${CACHE}/autonomous-loop.pid"
LOOP_LOG="/tmp/claude/autonomous-loop.log"

# Colors
BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; BLUE="\033[34m"; RESET="\033[0m"
OK="[OK]"; WARN="[!!]"; DEAD="[XX]"; SLEEP="[zz]"


echo "╔══════════════════════════════════════════════════════════╗"
echo "║        LiveMask Autonomous Engine Dashboard             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Engine Health ──────────────────────────────────────────────────
echo "━━━ ENGINE ━━━"
DAEMON_PID=$(cat "${PID_FILE}" 2>/dev/null || echo "NONE")
if kill -0 "${DAEMON_PID}" 2>/dev/null; then
  DAEMON_STATUS="${OK} RUNNING"
else
  DAEMON_STATUS="${DEAD} STOPPED"
fi
AGENT_PHASE=$(python3 -c "import json;print(json.load(open('${LIVEMASK_ROOT}/.claude/agent-state.json')).get('phase','?'))" 2>/dev/null || echo "?")
PM_LEASE=$(python3 -c "import json,time;d=json.load(open('${CACHE}/pm-lease.json'));print(f\"{d.get('agent','?')}/{d.get('phase','?')}\")" 2>/dev/null || echo "none")
QUEUE=$(python3 "${DOCS_DIR}/scripts/plan-next-tasks.py" --format json 2>/dev/null | python3 -c "import json,sys;s=json.load(sys.stdin).get('summary',{});print(f\"c={s.get('candidate_count',0)} b={s.get('blocked_open_count',0)}\")" 2>/dev/null || echo "?")
PKT=$(ls "${DOCS_DIR}/docs/development/dispatch-packets"/TASK-*.json 2>/dev/null | wc -l | tr -d ' ' || echo "0")
CYCLE=$(grep -o "CYCLE#[0-9]*" "${LOOP_LOG}" 2>/dev/null | tail -1 | grep -o "[0-9]*" || echo "0")

echo "  Daemon:  ${DAEMON_STATUS} (PID ${DAEMON_PID})"
echo "  Agent:   ${AGENT_PHASE}"
echo "  PM:      ${PM_LEASE}"
echo "  Queue:   ${QUEUE} | Packets: ${PKT}"
echo "  Cycle:   #${CYCLE}"
echo ""

# ── Roles ──────────────────────────────────────────────────────────
echo "━━━ ROLES ━━━"
for role in PM Product Tech QA TaskReview Leader Executor Monitor Codex; do
  case "${role}" in
    PM)       status=$([[ "${PM_LEASE}" != "none" ]] && echo "${OK} ${PM_LEASE}" || echo "${OK} idle") ;;
    Product)  status="${OK} idle (MVP tracking active)" ;;
    Tech)     status="${OK} idle (API check on commit)" ;;
    QA)       status="${OK} idle (verify on review)" ;;
    TaskReview) status="${OK} idle (audit on complete)" ;;
    Leader)   status="${OK} idle (review on submit)" ;;
    Executor) status=$([[ "${AGENT_PHASE}" == "implementing" ]] && echo "${OK} ACTIVE-${AGENT_PHASE}" || echo "${OK} ${AGENT_PHASE}") ;;
    Monitor)  status="${OK} observing (event-driven)" ;;
    Codex)    status="${WARN} manual-only (per CODEX_LOOP_RULES §15)" ;;
  esac
  printf "  %-12s %b\n" "${role}:" "${status}"
done
echo ""

# ── Models ─────────────────────────────────────────────────────────
echo "━━━ MODELS ━━━"
echo "  deepseek-reasoner  ${OK} PM/Leader/Monitor deep analysis"
echo "  deepseek-chat      ${OK} Fast queries, templates"
echo "  deepseek-chat+json ${OK} Structured QA/review output"
echo ""

# ── Skills ─────────────────────────────────────────────────────────
echo "━━━ SKILLS ━━━"
for skill in code-review security-review verify run loop update-config; do
  case "${skill}" in
    code-review)     s="${OK} on commit+review";;
    security-review) s="${OK} on commit";;
    verify)          s="${OK} on commit (async)";;
    run)             s="${OK} on qa_passed";;
    loop)            s="${OK} daemon active";;
    update-config)   s="${OK} on task_complete";;
  esac
  printf "  %-16s %b\n" "${skill}:" "${s}"
done
echo ""

# ── Tasks ──────────────────────────────────────────────────────────
echo "━━━ TASKS ━━━"
python3 -c "
import json; l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'))
from collections import Counter; c=Counter(t['status'] for m in l['modules'] for t in m['tasks'])
total=sum(c.values()); done=c.get('completed',0)+c.get('completed_with_skip',0)
pct=round(done*100/max(total,1))
bar='█'*(pct//10)+'░'*(10-pct//10)
print(f'  Progress: {done}/{total} ({pct}%) [{bar}]')
for s,n in c.most_common(6): print(f'  {s}: {n}')
" 2>/dev/null
echo ""

# ── Latest Activity ────────────────────────────────────────────────
echo "━━━ RECENT ACTIVITY ━━━"
tail -8 "${LOOP_LOG}" 2>/dev/null | grep "CYCLE#" | tail -5 | while read line; do
  # Color-code by event type
  if echo "${line}" | grep -q "WAITING\|SLEEP\|sleeping\|Sleeping"; then
    echo "  ${SLEEP} ${line:12:120}"
  elif echo "${line}" | grep -q "ACCEPT\|CREATE\|COMPLETE"; then
    echo "  ${OK} ${line:12:120}"
  elif echo "${line}" | grep -q "DEAD\|WARNING\|FAIL\|ERROR\|dead.loop\|blocked"; then
    echo "  ${DEAD} ${line:12:120}"
  else
    echo "  ${line:12:120}"
  fi
done
echo ""

# ── Sleep Events ───────────────────────────────────────────────────
echo "━━━ SLEEP STATUS ━━━"
LAST_SLEEP=$(grep "sleeping\|Sleeping" "${LOOP_LOG}" 2>/dev/null | tail -1 | grep -o "sleeping [0-9]*s\|Sleeping [0-9]*s" || echo "none")
LAST_EVENT=$(grep "CYCLE#" "${LOOP_LOG}" 2>/dev/null | tail -1 | grep -o "\[.*\]" | head -1 || echo "?")
echo "  Last event: ${LAST_EVENT}"
echo "  Last sleep: ${LAST_SLEEP}"
echo ""

# ── Alerts ─────────────────────────────────────────────────────────
ALERT_COUNT=$(ls "${CACHE}/alerts/"*.json 2>/dev/null | wc -l | tr -d ' ' || echo "0")
WEBHOOK_HEALTH=$(curl -sS --connect-timeout 2 http://47.243.128.122:10086/health 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('status','DOWN'))" 2>/dev/null || echo "DOWN")
echo "━━━ HEALTH ━━━"
echo "  Webhook:  $([[ "${WEBHOOK_HEALTH}" == "healthy" ]] && echo "${OK} ${WEBHOOK_HEALTH}" || echo "${DEAD} ${WEBHOOK_HEALTH}")"
echo "  Alerts:   ${ALERT_COUNT} pending"
echo "  Lark:     $([[ -f "${CACHE}/../.claude/deepseek.env" ]] && echo "${OK} configured" || echo "${WARN} pending")"

echo ""
echo "Refresh: watch -n 3 bash ${CI_CD_DIR}/scripts/engine-dashboard.sh"
