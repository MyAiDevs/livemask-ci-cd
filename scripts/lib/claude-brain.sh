#!/usr/bin/env bash
# claude-brain.sh — Claude-powered doc analysis + learning + caching

ROOT="/Users/sammytan/Developer/LiveMask"
DOCS="${ROOT}/livemask-docs"
CACHE="${HOME}/.claude/role-cache"
KNOWLEDGE="${CACHE}/lessons-learned.jsonl"

# ── Document Analysis: read MVP docs, contracts, create intelligent task plan ──
claude_analyze_docs() {
  echo "[Claude-Brain] analyzing project docs for task planning..."

  local prompt="You are the task planning system for LiveMask. Analyze these documents:

## 1. Contract Index
$(cat "${DOCS}/docs/contracts/contract-index.md" 2>/dev/null | head -100)

## 2. MVP Implementation Plan 
$(cat "${DOCS}/docs/development/MVP_IMPLEMENTATION_PLAN.md" 2>/dev/null | head -80)

## 3. Task State Ledger Summary
$(python3 -c "
import json
l=json.load(open('${DOCS}/docs/development/task-state-ledger.json'))
from collections import Counter
c=Counter(t['status'] for m in l['modules'] for t in m['tasks'])
print(f'Total: {sum(c.values())}')
for s,n in c.most_common(): print(f'{s}: {n}')
" 2>/dev/null)

## YOUR TASK
1. Identify the top 5 most important tasks that need implementation
2. For each task, specify: task_id (TASK-MVP-xxx), repo, priority (P0/P1/P2), one-line description
3. Consider: contract readiness, dependency chains, business value, implementation complexity
4. Output as JSON array: [{\"task_id\":\"...\", \"repo\":\"...\", \"priority\":\"...\", \"description\":\"...\"}]
Output ONLY valid JSON, no other text."

  if command -v claude &>/dev/null; then
    source "${SCRIPT_DIR}/lib/claude-memory.sh" 2>/dev/null
    claude_with_memory "brain" "$prompt" "" "livemask-docs" "Read" 2>&1
  else
    echo '[{"task_id":"CLAUDE_UNAVAILABLE","repo":"livemask-docs","priority":"P1","description":"Claude CLI not installed"}]'
  fi
}

# ── Learning: analyze task result, extract patterns, cache knowledge ──
claude_learn() {
  local tid="$1" result="${2:-completed}" errors="${3:-}"

  echo "[Claude-Learn] analyzing task ${tid} (${result})..."

  mkdir -p "$(dirname "${KNOWLEDGE}")"

  local prompt="You are analyzing task completion to learn patterns for future tasks.

## TASK: ${tid}
## RESULT: ${result}
## ERRORS (if any): ${errors}

## PREVIOUS KNOWLEDGE
$(cat "${KNOWLEDGE}" 2>/dev/null | tail -20 || echo "No prior knowledge")

## YOUR TASK
1. Analyze what patterns led to success or failure
2. Extract reusable lessons (max 3 bullet points)
3. Output as JSON: {\"task_id\":\"${tid}\", \"result\":\"${result}\", \"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"lessons\":[\"lesson1\",\"lesson2\",\"lesson3\"], \"patterns\":{\"what_worked\":\"...\",\"what_failed\":\"...\"}}
Output ONLY valid JSON, append to ${KNOWLEDGE}."

  if command -v claude &>/dev/null; then
    local lesson
    lesson=$(claude -p "$prompt" --dangerously-skip-permissions --allowedTools "Read,Write" 2>&1)
    echo "$lesson" >> "${KNOWLEDGE}"
    echo "[Claude-Learn] knowledge cached (${KNOWLEDGE})"
    echo "$lesson" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  lessons: {len(d.get(\"lessons\",[]))}')" 2>/dev/null || true
  else
    echo "[Claude-Learn] claude CLI not available"
  fi
}

# ── Query: retrieve relevant past learnings for a task ──
claude_recall() {
  local tid="$1" context="${2:-}"
  echo "[Claude-Recall] retrieving relevant knowledge for ${tid}..."

  if [ ! -f "${KNOWLEDGE}" ]; then
    echo "[Claude-Recall] no knowledge base yet"
    return 0
  fi

  local prompt="You are retrieving relevant past learnings for a new task.

## CURRENT TASK: ${tid}
## CONTEXT: ${context}

## KNOWLEDGE BASE
$(tail -50 "${KNOWLEDGE}" 2>/dev/null)

## YOUR TASK
Find the 3 most relevant past lessons for this task. Output as bullet points. Be concise."

  if command -v claude &>/dev/null; then
    claude -p "$prompt" --dangerously-skip-permissions --allowedTools "Read" 2>&1 | tail -10
  fi
}
