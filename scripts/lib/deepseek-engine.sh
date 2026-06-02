#!/usr/bin/env bash
# deepseek-engine.sh — Multi-model router for autonomous engine roles.
# Routes each task to the optimal DeepSeek model:
#   deepseek-reasoner → thinking mode (root cause, WHY questions)
#   deepseek-chat     → fast response (checks, templates, queries)
#   deepseek-chat+json → structured output for downstream consumption
set -euo pipefail

DEEPSEEK_KEY="${DEEPSEEK_API_KEY:-}"
DEEPSEEK_BASE="https://api.deepseek.com"

# ── Model Router ───────────────────────────────────────────────────────
# Usage: ds_think "system_prompt" "user_prompt" → outputs reasoning + answer
ds_think() {
  local sys="$1" usr="$2"
  [[ -z "${DEEPSEEK_KEY}" ]] && { echo "[DS] no key"; return 1; }
  local fallback="${4:-}"  # If set, fallback to chat mode on failure
  python3 -c "
import json,urllib.request
body=json.dumps({'model':'deepseek-reasoner','messages':[{'role':'system','content':'''${sys}'''},{'role':'user','content':'''${usr}'''}],'stream':False}).encode()
r=urllib.request.Request('${DEEPSEEK_BASE}/v1/chat/completions',data=body,headers={'Authorization':'Bearer ${DEEPSEEK_KEY}','Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(r,timeout=180).read())
m=d['choices'][0]['message']
print('=== REASONING ===')
print(m.get('reasoning_content','(none)'))
print('=== ANSWER ===')
print(m.get('content',''))
" 2>/dev/null || {
    if [[ -n "${fallback}" ]]; then
      echo "[DS] reasoner failed, falling back to chat mode"
      ds_chat "${sys}" "${usr}"
    else
      echo "[DS] think failed"
    fi
  }
}

# Usage: ds_chat "system_prompt" "user_prompt" → outputs answer only
ds_chat() {
  local sys="$1" usr="$2"
  [[ -z "${DEEPSEEK_KEY}" ]] && { echo "[DS] no key"; return 1; }
  local fallback="${4:-}"  # If set, fallback to chat mode on failure
  python3 -c "
import json,urllib.request
body=json.dumps({'model':'deepseek-chat','messages':[{'role':'system','content':'''${sys}'''},{'role':'user','content':'''${usr}'''}],'stream':False,'temperature':0.3}).encode()
r=urllib.request.Request('${DEEPSEEK_BASE}/v1/chat/completions',data=body,headers={'Authorization':'Bearer ${DEEPSEEK_KEY}','Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(r,timeout=60).read())
print(d['choices'][0]['message']['content'])
" 2>/dev/null || echo "[DS] chat failed"
}

# Usage: ds_json "system_prompt" "user_prompt" → outputs valid JSON only
ds_json() {
  local sys="$1" usr="$2"
  [[ -z "${DEEPSEEK_KEY}" ]] && { echo '{"error":"no key"}'; return 1; }
  python3 -c "
import json,urllib.request
body=json.dumps({'model':'deepseek-chat','messages':[{'role':'system','content':'''${sys}'''},{'role':'user','content':'''${usr}'''}],'response_format':{'type':'json_object'},'stream':False}).encode()
r=urllib.request.Request('${DEEPSEEK_BASE}/v1/chat/completions',data=body,headers={'Authorization':'Bearer ${DEEPSEEK_KEY}','Content-Type':'application/json'})
d=json.loads(urllib.request.urlopen(r,timeout=60).read())
print(d['choices'][0]['message']['content'])
" 2>/dev/null || echo '{"error":"json failed"}'
}

# ── Role-specific reasoning ────────────────────────────────────────────

# PM: Queue analysis with deep thinking
ds_pm_analyze_queue() {
  ds_think \
    "You are the PM of LiveMask autonomous engine. Analyze deeply: WHY is the queue in this state? What is the root cause? What should be done?" \
    "Queue state: candidates=${1:-0}, blocked=${2:-0}, dispatch_packets=${3:-0}. Ready contract gaps: ${4:-none}. Analyze and give action plan."
}

# Leader: Code review with JSON verdict
ds_leader_review() {
  local diff="${1:-}" tid="${2:-}"
  ds_json \
    "You are a code reviewer. Output valid JSON: {\"verdict\":\"approved\"|\"changes_requested\",\"issues\":[{\"severity\":\"high\"|\"medium\"|\"low\",\"description\":\"...\"}],\"suggestions\":[\"...\"]}. Only output JSON, no other text." \
    "Review diff for task ${tid}:\n${diff}"
}

# Monitor: Pattern detection with thinking
ds_monitor_analyze() {
  local findings="${1:-}"
  ds_think \
    "You are the Monitor of LiveMask engine. Analyze patterns in these findings. What is the root cause of recurring issues? What should the engine learn?" \
    "Recent findings:\n${findings}"
}

# QA: Verification with JSON output
ds_qa_verify() {
  local results="${1:-}" tid="${2:-}"
  ds_json \
    "You are QA. Output JSON: {\"passed\":bool,\"score\":0-100,\"failures\":[{\"check\":\"...\",\"detail\":\"...\"}],\"recommendation\":\"...\"}" \
    "Task ${tid} verification results:\n${results}"
}

# Tech: Impact analysis with thinking
ds_tech_analyze_impact() {
  local changes="${1:-}"
  ds_think \
    "You are Tech Lead. Analyze the API/database changes. What downstream systems are affected? What could break?" \
    "Recent changes:\n${changes}"
}

# General: Classify task complexity → recommend model
ds_classify() {
  local task_desc="${1:-}"
  ds_chat \
    "Classify this task as: SIMPLE (single file, mechanical), MEDIUM (multiple files, some logic), or COMPLEX (new feature, cross-repo, requires design). Output one word." \
    "${task_desc}"
}
