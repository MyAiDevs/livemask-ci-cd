#!/usr/bin/env bash
# claude-implement.sh — Claude-driven task implementation with detailed context

claude_implement() {
  local tid="$1" repo="$2"
  [[ -z "$tid" ]] && return 1
  [[ -z "$repo" ]] && return 1

  local ROOT="/Users/sammytan/Developer/LiveMask"
  local TASK_DOC="${ROOT}/livemask-docs/docs/development/tasks/${tid}.md"
  local LEDGER="${ROOT}/livemask-docs/docs/development/task-state-ledger.json"
  local CONTRACTS="${ROOT}/livemask-docs/docs/contracts/contract-index.md"
  local REPO_DIR="${ROOT}/${repo}"

  echo "[Claude-Impl] ========================================"
  echo "[Claude-Impl] Task:    $tid"
  echo "[Claude-Impl] Repo:    $repo"
  echo "[Claude-Impl] Doc:     $TASK_DOC"
  echo "[Claude-Impl] ========================================"

  # ── Build comprehensive prompt ──
  local PROMPT="You are autonomously implementing task ${tid} in the LiveMask project.

## REPOSITORY
${repo} at ${REPO_DIR}

## TASK DOCUMENT
$(cat "${TASK_DOC}" 2>/dev/null | head -80 || echo "Task doc not found")

## LEDGER ENTRY
$(python3 -c "
import json
l=json.load(open('${LEDGER}'))
for m in l.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id')=='${tid}':
            print(json.dumps(t, indent=2))
" 2>/dev/null || echo "Not found in ledger")

## RELATED CONTRACTS
$(python3 -c "
import re
with open('${CONTRACTS}') as f:
    for line in f:
        if '| Ready |' in line:
            parts=[p.strip() for p in line.split('|')]
            if len(parts)>=6:
                print(f'{parts[1]}: {parts[5]}')
" 2>/dev/null | head -10 || echo "No contracts found")

## EXISTING CODE PATTERNS
$(cd "${REPO_DIR}" && find . -name "*.go" -o -name "*.tsx" -o -name "*.ts" 2>/dev/null | grep -v node_modules | grep -v .cache | head -20)

## BUILD & TEST COMMANDS
$(case "$repo" in
  livemask-backend)     echo "Build: go build ./...; Test: go test ./... -count=1; Vet: go vet ./..." ;;
  livemask-admin)       echo "Build: npm run build; Test: npm test; Lint: npm run lint" ;;
  livemask-website)     echo "Build: npm run build; Dev: npm run dev" ;;
  livemask-nodeagent)   echo "Build: go build ./...; Test: go test ./... -count=1" ;;
  livemask-job-service) echo "Build: go build ./...; Test: go test ./... -count=1" ;;
  *)                    echo "Check repo for build commands" ;;
esac)

## DOCKER CONTAINERS
$(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | head -7 || echo "Docker not available")

## INSTRUCTIONS
1. Read the task document carefully
2. Study existing code patterns in the repo
3. Create branch task/${tid} in ${repo}
4. Implement the changes following project conventions
4. ALL commits must use dev-merge-guard.sh to merge to dev — NEVER commit directly to dev
5. Run build and tests
6. After build/test pass, merge using: bash /Users/sammytan/Developer/LiveMask/livemask-ci-cd/scripts/dev-merge-guard.sh --repo REPO --task-branch task/ --task-id TASKID --push
6. If build/test fails, analyze the error and fix (retry up to 3 times)
7. Commit with message: 'feat(${repo}): implement ${tid}'
8. Update session-state.json: set phase='completed'
9. Output the commit SHA on the last line

## EVIDENCE REQUIRED
After completion, the task must have:
- dev_merge_commit: the commit SHA
- remote_dev_ref: origin/dev
- validation: build+test evidence
- issue: GitHub issue URL

Go!"

  if command -v claude &>/dev/null; then
    cd "${REPO_DIR}" || return 1
    source "${SCRIPT_DIR}/lib/claude-memory.sh" 2>/dev/null
    claude_with_memory "dev" "$(echo "$PROMPT")" "${tid}" "${repo}" "Edit,Write,Read,Bash(git *),Bash(go *),Bash(npm *),Bash(flutter *)" 2>&1
    return $?
  else
    echo "[Claude-Impl] claude CLI not available"
    return 1
  fi
}

# claude_learn — learn from experience, update knowledge base
claude_learn() {
  local tid="$1" result="${2:-success}"
  echo "[Claude-Learn] recording experience for $tid ($result)..."
  
  local prompt="Task $tid completed with result: $result. Analyze what worked, what could be improved. Write a one-paragraph lesson learned to /Users/sammytan/.claude/role-cache/lessons.md (append)."
  
  if command -v claude &>/dev/null; then
    claude -p "$prompt" --dangerously-skip-permissions --allowedTools "Read,Write" 2>&1 | tail -3
  fi
}
