#!/usr/bin/env bash
# claude-memory.sh — Role-isolated memory system for stateless Claude CLI
#
# Architecture:
#   Each role has its own context file. Before calling claude -p, 
#   we LOAD the role's memory into the prompt. After, we SAVE results back.
#
# Files:
#   ~/.claude/role-cache/brain-context.json   (PM/Planning)
#   ~/.claude/role-cache/dev-context.json     (DEV/Implementation)
#   ~/.claude/role-cache/qa-context.json      (QA/Verification)
#   ~/.claude/role-cache/repair-context.json  (Repair/Evidence)
#   ~/.claude/role-cache/lessons-learned.jsonl (Cross-role learning)
#   ~/.claude/role-cache/task-history.jsonl   (Task execution log)

MEM_DIR="${HOME}/.claude/role-cache"
mkdir -p "${MEM_DIR}"

# ── Memory: load role context ──────────────────────────────────────────
memory_load() {
  local role="$1"  # brain|dev|qa|repair
  local ctx_file="${MEM_DIR}/${role}-context.json"
  
  if [ -f "${ctx_file}" ]; then
    # Return last 5 entries + summary stats
    python3 -c "
import json
d=json.load(open('${ctx_file}'))
print(f'## ROLE: ${role} | Entries: {len(d.get(\"history\",[]))} | Last: {d.get(\"last_action\",\"none\")}')
for h in d.get('history',[])[-5:]:
    print(f'- [{h.get(\"ts\",\"?\")}] {h.get(\"action\",\"?\")}: {h.get(\"result\",\"?\")[:120]}')
if d.get('patterns'):
    print(f'## Learned Patterns:')
    for p in d.get('patterns',[])[-3:]:
        print(f'- {p}')
" 2>/dev/null || echo "## ROLE: ${role} | NEW"
  else
    echo "## ROLE: ${role} | FIRST RUN — no prior memory"
  fi
}

# ── Memory: save role context ──────────────────────────────────────────
memory_save() {
  local role="$1" action="$2" result="$3" patterns="${4:-}"
  local ctx_file="${MEM_DIR}/${role}-context.json"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 -c "
import json,os
f='${ctx_file}'
d=json.load(open(f)) if os.path.exists(f) else {'role':'${role}','history':[],'patterns':[],'stats':{}}
d['last_action']='${action}'
d['last_updated']='${ts}'
d.setdefault('history',[]).append({
    'ts':'${ts}','action':'${action}','result':'''${result}'''[:200]
})
# Keep only last 20 entries
if len(d['history'])>20: d['history']=d['history'][-20:]
# Add patterns if provided
if '${patterns}': d.setdefault('patterns',[]).append('${patterns}')
# Update stats
d.setdefault('stats',{})['total_actions']=d['stats'].get('total_actions',0)+1
json.dump(d,open(f,'w'),indent=2,ensure_ascii=False)
" 2>/dev/null
}

# ── Memory: cross-role lesson learned ──────────────────────────────────
memory_learn() {
  local lesson="$1" source_role="$2"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"ts\":\"${ts}\",\"role\":\"${source_role}\",\"lesson\":\"${lesson}\"}" >> "${MEM_DIR}/lessons-learned.jsonl"
}

# ── Memory: log task execution ─────────────────────────────────────────
memory_log_task() {
  local tid="$1" phase="$2" status="$3" detail="${4:-}"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "{\"ts\":\"${ts}\",\"task\":\"${tid}\",\"phase\":\"${phase}\",\"status\":\"${status}\",\"detail\":\"${detail}\"}" >> "${MEM_DIR}/task-history.jsonl"
}

# ── Memory: build comprehensive prompt with role context ───────────────
memory_build_prompt() {
  local role="$1" task_prompt="$2" tid="${3:-}" repo="${4:-}"
  
  cat <<PROMPT
## YOUR ROLE: ${role}
$(memory_load "${role}")

## CURRENT TASK: ${tid:-N/A} in ${repo:-N/A}

## RECENT TASK HISTORY
$(tail -10 "${MEM_DIR}/task-history.jsonl" 2>/dev/null | python3 -c "
import json,sys
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        print(f'- [{d.get(\"ts\",\"?\")}] {d.get(\"task\",\"?\")}: {d.get(\"phase\",\"?\")} → {d.get(\"status\",\"?\")}')
    except: pass
" 2>/dev/null || echo "No prior tasks")

## CROSS-ROLE LESSONS
$(tail -10 "${MEM_DIR}/lessons-learned.jsonl" 2>/dev/null | python3 -c "
import json,sys
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        print(f'- [{d.get(\"role\",\"?\")}] {d.get(\"lesson\",\"\")}')
    except: pass
" 2>/dev/null || echo "No prior lessons")

## YOUR TASK
${task_prompt}

## OUTPUT FORMAT
After completing your work, end with a line: ROLE_${role}_DONE: <summary>
This allows the system to know you finished successfully.
PROMPT
}

# ── Combined: run Claude with full memory context ──────────────────────
claude_with_memory() {
  local role="$1" task_prompt="$2" tid="${3:-}" repo="${4:-}"
  local allowed_tools="${5:-Read,Write,Edit,Bash(git *)}"
  
  echo "[Memory] ${role}: loading context..."
  local full_prompt
  full_prompt=$(memory_build_prompt "$role" "$task_prompt" "$tid" "$repo")
  
  echo "[Memory] ${role}: executing with context (${MEM_DIR}/${role}-context.json)..."
  local result
  if command -v claude &>/dev/null; then
    cd "/Users/sammytan/Developer/LiveMask/${repo:-livemask-docs}" 2>/dev/null || cd "/Users/sammytan/Developer/LiveMask/livemask-docs"
    result=$(echo "$full_prompt" | claude -p - --dangerously-skip-permissions --allowedTools "$allowed_tools" 2>&1)
    local rc=$?
    
    # Extract completion marker
    local summary
    summary=$(echo "$result" | grep "ROLE_${role}_DONE:" | tail -1 || echo "No completion marker")
    
    # Save to memory
    memory_save "$role" "${tid:-unknown}" "$summary" ""
    memory_log_task "${tid:-unknown}" "${role}" "$(echo $summary | head -1)" ""
    
    echo "[Memory] ${role}: context saved (rc=$rc)"
    echo "$result"
    return $rc
  else
    echo "[Memory] ${role}: Claude CLI not available"
    return 1
  fi
}

echo "[Memory] system initialized at ${MEM_DIR}"
