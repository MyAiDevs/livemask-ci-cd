#!/usr/bin/env bash
# claude-webhook.sh — Claude-powered webhook event processing with memory

WEBHOOK_INBOX="${HOME}/.claude/role-cache/webhook-events/inbox.jsonl"
WEBHOOK_PROCESSED="${HOME}/.claude/role-cache/webhook-events/processed.jsonl"

# ── Process a single webhook event with Claude intelligence ───────────
claude_webhook_process() {
  local event_file="${1:-}"
  [[ ! -f "$event_file" ]] && { echo "[Webhook] no event file: $event_file"; return 1; }

  local event
  event=$(cat "$event_file" 2>/dev/null)
  [[ -z "$event" ]] && { echo "[Webhook] empty event"; return 1; }

  # Extract event type
  local event_type
  event_type=$(echo "$event" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('event_type','unknown'))" 2>/dev/null || echo "unknown")

  echo "[Webhook] processing: ${event_type}"

  local prompt="You are processing a webhook event for the LiveMask project.

## EVENT
${event}

## YOUR ROLE: Webhook Event Processor
1. Analyze the event: is it a new issue, PR comment, push, or CI notification?
2. Route to the correct action:
   - New GitHub Issue → Analyze if it's a bug/feature, create task via /mvp
   - PR Comment → Check if it needs action (review requested, changes needed)
   - Push/CI → Update task status, check evidence chain
   - Unknown → Log and skip
3. If a task needs creation, use task.py create with appropriate type/priority
4. If a task needs status update, use ledger.py status
5. Output the action taken as: WEBHOOK_DONE: <action>

## RECENT TASK HISTORY
$(tail -10 "${HOME}/.claude/role-cache/task-history.jsonl" 2>/dev/null || echo "No history")

## CROSS-ROLE LESSONS
$(tail -5 "${HOME}/.claude/role-cache/lessons-learned.jsonl" 2>/dev/null || echo "No lessons")"

  if command -v claude &>/dev/null; then
    local result
    result=$(echo "$prompt" | claude -p - --dangerously-skip-permissions \
      --allowedTools "Read,Edit,Write,Bash(gh *),Bash(git *),Bash(python3 *)" 2>&1)
    
    # Record to memory
    local action
    action=$(echo "$result" | grep "WEBHOOK_DONE:" | tail -1 || echo "processed")
    python3 -c "
import json,os
ts='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
entry={'ts':ts,'type':'${event_type}','action':'${action//\'/}','source':'webhook'}
f='${WEBHOOK_PROCESSED}'
os.makedirs(os.path.dirname(f),exist_ok=True)
with open(f,'a') as fh: fh.write(json.dumps(entry)+'\n')
" 2>/dev/null

    echo "[Webhook] processed: ${action}"
    echo "$result" | tail -3
  else
    echo "[Webhook] Claude CLI not available — using basic processing"
    _webhook_basic_process "$event" "$event_type"
  fi
}

# ── Basic fallback processing (no Claude) ──────────────────────────────
_webhook_basic_process() {
  local event="$1" event_type="$2"
  
  case "$event_type" in
    issues|issue_comment)
      local issue_url
      issue_url=$(echo "$event" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',{}).get('issue','{}').get('html_url',''))" 2>/dev/null || echo "")
      if [[ -n "$issue_url" ]]; then
        echo "[Webhook] new issue: ${issue_url}"
        # Auto-label based on keywords
        local title
        title=$(echo "$event" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('payload',{}).get('issue',{}).get('title',''))" 2>/dev/null || echo "")
        if echo "$title" | grep -qi "bug\|error\|fail\|crash\|broken"; then
          echo "[Webhook] detected bug report — creating task"
        fi
      fi
      ;;
    push)
      echo "[Webhook] push event — checking for CI triggers"
      ;;
    *)
      echo "[Webhook] unknown event type: ${event_type} — logging only"
      ;;
  esac
}

# ── Process all unread webhook events ──────────────────────────────────
claude_webhook_process_all() {
  mkdir -p "$(dirname "${WEBHOOK_INBOX}")"
  
  if [[ ! -f "${WEBHOOK_INBOX}" ]]; then
    echo "[Webhook] no inbox events"
    return 0
  fi

  local count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local tmpfile="/tmp/webhook-event-$$-${count}.json"
    echo "$line" > "$tmpfile"
    claude_webhook_process "$tmpfile" 2>&1 | tail -5
    rm -f "$tmpfile"
    count=$((count + 1))
    [[ $count -ge 5 ]] && break  # Max 5 per cycle
  done < "${WEBHOOK_INBOX}"

  # Clear processed events
  if [[ $count -gt 0 ]]; then
    mv "${WEBHOOK_INBOX}" "${WEBHOOK_INBOX}.processed-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    echo "[Webhook] processed ${count} events"
  fi
}

echo "[Webhook] module loaded"
