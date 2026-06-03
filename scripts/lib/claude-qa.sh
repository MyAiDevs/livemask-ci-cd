#!/usr/bin/env bash
# claude-qa.sh — Multi-repo QA verification with DEV feedback loop

claude_qa_verify() {
  local tid="$1" repo="$2"
  [[ -z "$tid" ]] && return 1
  
  echo "[Claude-QA] ========================================"
  echo "[Claude-QA] Verifying: $tid in $repo"
  echo "[Claude-QA] ========================================"

  local ROOT="/Users/sammytan/Developer/LiveMask"
  local TASK_DOC="${ROOT}/livemask-docs/docs/development/tasks/${tid}.md"
  local LEDGER="${ROOT}/livemask-docs/docs/development/task-state-ledger.json"

  # Determine affected repos based on task type
  local AFFECTED_REPOS="$repo"
  case "$repo" in
    livemask-backend) AFFECTED_REPOS="livemask-backend livemask-admin" ;;
    livemask-admin)   AFFECTED_REPOS="livemask-admin livemask-backend" ;;
    livemask-website) AFFECTED_REPOS="livemask-website livemask-backend" ;;
    *) AFFECTED_REPOS="$repo" ;;
  esac

  local PROMPT="You are QA for task ${tid}. Verify the FULL stack, not just a single repo.

## TASK
$(cat "${TASK_DOC}" 2>/dev/null | head -60 || echo "N/A")

## AFFECTED REPOS
${AFFECTED_REPOS}

## VERIFICATION CHECKLIST

### 1. Build Verification (ALL affected repos)
$(for r in $AFFECTED_REPOS; do
  echo "  - $r: $(case $r in
    livemask-backend|livemask-nodeagent|livemask-job-service) echo 'go build ./... && go test ./... -count=1 && go vet ./...' ;;
    livemask-admin|livemask-website) echo 'npm run build' ;;
    *) echo 'verify per project conventions' ;;
  esac)"
done)

### 2. Docker Container Health
$(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | head -7 || echo "Docker not available")

### 3. Container Error Logs
$(for c in $(docker ps --format '{{.Names}}' 2>/dev/null | head -7); do
  echo "--- $c (last 10 lines) ---"
  docker logs --tail 10 "$c" 2>/dev/null | grep -iE 'error|fail|panic|fatal' || echo "  No errors found"
done)

### 4. i18n/Localization Check (Website + Admin)
- ALL pages must support zh-CN and en-US
- ALL sub-pages, modals, dialogs must have i18n keys
- No hardcoded Chinese or English strings
- Language switcher must work on every page
- Check: grep for hardcoded Chinese chars in .tsx/.jsx files
$(cd "${ROOT}/livemask-admin" 2>/dev/null && grep -r '[\\u4e00-\\u9fff]' app/ --include="*.tsx" -l 2>/dev/null | head -10 || echo "  No admin hardcoded Chinese found")
$(cd "${ROOT}/livemask-website" 2>/dev/null && grep -r '[\\u4e00-\\u9fff]' src/ --include="*.tsx" -l 2>/dev/null | head -10 || echo "  No website hardcoded Chinese found")

### 5. API Integration (if backend changes)
- Backend health endpoint: $(curl -s http://127.0.0.1:18080/api/v1/health 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','FAIL'))" 2>/dev/null || echo "FAIL")
- Job Service health: $(curl -s http://127.0.0.1:19191/healthz 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','FAIL'))" 2>/dev/null || echo "FAIL")

### 6. Frontend Smoke (if UI changes)
- Admin: curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/admin 2>/dev/null || echo "N/A"
- Website: curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3002/ 2>/dev/null || echo "N/A"

## YOUR TASK
1. Verify ALL checks above
2. If ANY check fails, output: QA_FAILED: <specific failure reason>
3. If ALL checks pass, output: QA_PASSED: all checks green
4. Update session-state.json: set phase='verified' (if pass) or phase='verification_failed' (if fail)
5. If failed, include EXACT instructions for DEV to fix

GO!"

  if command -v claude &>/dev/null; then
    cd "${ROOT}/${repo}" 2>/dev/null || cd "${ROOT}/livemask-docs"
    source "${SCRIPT_DIR}/lib/claude-memory.sh" 2>/dev/null
    claude_with_memory "qa" "$(echo "$PROMPT")" "${tid}" "${repo}" "Read,Bash(git *),Bash(go *),Bash(npm *),Bash(docker *),Bash(curl *)" 2>&1
      --dangerously-skip-permissions \
      --allowedTools "Read,Bash(git *),Bash(go *),Bash(npm *),Bash(docker *),Bash(curl *)" 2>&1
    local rc=$?
    echo "[Claude-QA] Exit: $rc"
    return $rc
  else
    echo "[Claude-QA] claude CLI not available"
    return 1
  fi
}

# QA→DEV feedback loop: if verification fails, fix and retry
claude_qa_fix_loop() {
  local tid="$1" repo="$2" max_retries="${3:-3}"
  
  for attempt in $(seq 1 $max_retries); do
    echo "[Claude-QA-Fix] Attempt $attempt/$max_retries..."
    
    # Run QA
    local qa_result
    qa_result=$(claude_qa_verify "$tid" "$repo" 2>&1)
    
    if echo "$qa_result" | grep -q "QA_PASSED"; then
      echo "[Claude-QA-Fix] ✅ All checks passed!"
      return 0
    fi
    
    # Extract failure reasons
    local failures
    failures=$(echo "$qa_result" | grep "QA_FAILED:" || echo "Unknown failure")
    echo "[Claude-QA-Fix] ❌ Failed: $failures"
    
    if [ "$attempt" -lt "$max_retries" ]; then
      echo "[Claude-QA-Fix] → Sending back to DEV for fix (attempt $attempt)..."
      
      # Call Claude to fix the issues
      local fix_prompt="QA found these failures for task ${tid} in ${repo}:
${failures}

Fix ALL of these issues now. Run verification after fixing. Output FIXED when done."
      
      claude -p "$fix_prompt" \
        --dangerously-skip-permissions \
        --allowedTools "Edit,Write,Read,Bash(git *),Bash(go *),Bash(npm *),Bash(docker *)" 2>&1 || true
    fi
  done
  
  echo "[Claude-QA-Fix] ❌ Failed after $max_retries attempts"
  return 1
}
