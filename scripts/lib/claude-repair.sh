#!/usr/bin/env bash
# claude-repair.sh — Claude-powered intelligent repair
# Usage: source this, then call claude_repair BUILD_LOG TASK_ID REPO

claude_repair() {
  local logf="$1" tid="${2:-}" repo="${3:-}"
  [[ ! -f "$logf" ]] && { echo "[repair] log not found: $logf"; return 1; }
  [[ -z "$tid" ]] && { echo "[repair] no task id"; return 1; }

  local errors
  errors=$(tail -50 "$logf" 2>/dev/null)
  
  echo "[Claude-Repair] analyzing errors for $tid in $repo..."
  
  local prompt="You are fixing a build/test failure. Task: $tid in repo $repo.
ERROR LOG:
$errors

Analyze the error, then fix the code in $repo. Run build+test after fixing. Be concise."
  
  if command -v claude &>/dev/null; then
    claude -p "$prompt" --dangerously-skip-permissions \
      --allowedTools "Edit,Write,Read,Bash(git *),Bash(go *),Bash(npm *),Bash(flutter *)" 2>&1 || echo "[Claude-Repair] claude failed"
  else
    echo "[Claude-Repair] claude CLI not available"
    return 1
  fi
}

claude_evidence_heal() {
  local tid="$1" repo="${2:-}"
  local prompt="Task $tid in $repo has missing evidence. Read the task doc and ledger entry. Fix missing dev_merge_commit, remote_dev_ref, validation, or issue URL. Update the ledger. NEVER commit directly to dev. Use dev-merge-guard.sh for all merges. Output DONE when complete."
  
  echo "[Claude-Evidence] healing evidence for $tid..."
  
  if command -v claude &>/dev/null; then
    claude -p "$prompt" --dangerously-skip-permissions \
      --allowedTools "Edit,Write,Read,Bash(git *),Bash(gh *)" 2>&1 || echo "[Claude-Evidence] claude failed"
  else
    echo "[Claude-Evidence] claude CLI not available"
    return 1
  fi
}
