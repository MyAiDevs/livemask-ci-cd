#!/usr/bin/env bash
# TASK-CICD-CONTRACT-OWNERSHIP-001
# Validate that a task review contract's domain-separated fields
# were written by the correct actor (Claude=claude, Codex=codex, CI/CD=merge).
#
# Usage: bash scripts/validate-contract-ownership.sh <contract-file>
# Exit: 0=valid, 1=violation found, 2=usage/parse error
set -euo pipefail

CONTRACT_FILE="${1:-}"

if [[ -z "${CONTRACT_FILE}" ]]; then
  echo "Usage: $0 <contract-file>" >&2
  exit 2
fi

if [[ ! -f "${CONTRACT_FILE}" ]]; then
  echo "ERROR: contract file not found: ${CONTRACT_FILE}" >&2
  exit 2
fi

echo "=== Contract Ownership Validation ==="
echo "  file: ${CONTRACT_FILE}"

python3 -c "
import json, sys

with open('${CONTRACT_FILE}') as f:
    c = json.load(f)

violations = []
warnings = []
rounds = c.get('rounds', [])
state = c.get('state', '')
task_id = c.get('task_id', '?')

if not rounds:
    print('  WARN: no review rounds found in contract')
    sys.exit(0)

for r in rounds:
    round_num = r.get('round', '?')
    claude = r.get('claude', {})
    codex = r.get('codex', {})

    claude_ts = claude.get('submitted_at', '') if claude else ''
    codex_ts = codex.get('reviewed_at', '') if codex else ''

    # ── Check 1: Timestamp reversal ──────────────────────────────────────
    # codex.reviewed_at must be AFTER claude.submitted_at
    if claude_ts and codex_ts and codex_ts < claude_ts:
        violations.append(
            f'Round {round_num}: codex.reviewed_at ({codex_ts}) is BEFORE '
            f'claude.submitted_at ({claude_ts}) — timestamp reversal detected'
        )

    # ── Check 2: Codex fields in claude-only states ──────────────────────
    # If state is 'claimed', 'analyzing', or 'implementing', Codex should
    # not have written a verdict yet.
    early_states = {'claimed', 'analyzing', 'implementing', 'self_review'}
    if state in early_states and codex and codex.get('verdict'):
        violations.append(
            f'Round {round_num}: codex.verdict=({codex.get(\"verdict\")}) is '
            f'present but contract state is \"{state}\" (claude-only phase)'
        )

    # ── Check 3: Orphaned findings response ───────────────────────────────
    # Claude responded to findings that Codex never filed.
    previous_codex = None
    for prev_r in rounds:
        if prev_r.get('round', 0) >= round_num:
            break
        if prev_r.get('codex', {}).get('findings'):
            previous_codex = prev_r.get('codex', {}).get('findings', [])

    if claude.get('addressed_findings') and not codex and not previous_codex:
        violations.append(
            f'Round {round_num}: claude.addressed_findings present but '
            f'no codex.findings exist in any prior round — orphaned response'
        )

    # ── Check 4: Self-approval pattern ────────────────────────────────────
    # Claude should not be the one writing codex.verdict=approved
    # when the contract state is still in a claude-only phase.
    if codex and codex.get('verdict') == 'approved':
        if state in ('implementing', 'self_review', 'claimed', 'analyzing'):
            violations.append(
                f'Round {round_num}: codex.verdict=approved but state is '
                f'\"{state}\" — possible self-approval pattern'
            )

    # ── Check 5 (WARN): Third-person references ───────────────────────────
    for finding in codex.get('findings', []) if codex else []:
        req_action = finding.get('required_action', '')
        issue_text = finding.get('issue', '')
        if 'Claude' in req_action or 'Claude' in issue_text:
            warnings.append(
                f'Round {round_num} finding {finding.get(\"id\",\"?\")}: '
                f'references \"Claude\" in finding text (possible self-review)'
            )

# ── Report ────────────────────────────────────────────────────────────────
if violations:
    print(f'')
    print(f'CONTRACT OWNERSHIP VIOLATION ({len(violations)} found):')
    for v in violations:
        print(f'  FAIL: {v}')
    print(f'')
    print(f'Task {task_id} cannot proceed until violations are resolved.')
    print(f'Claude must NOT write codex fields. Codex must NOT write before claude submission.')
    sys.exit(1)

if warnings:
    print(f'')
    print(f'CONTRACT OWNERSHIP WARNINGS ({len(warnings)} found):')
    for w in warnings:
        print(f'  WARN: {w}')
    print(f'')
    print(f'VALIDATION PASS (with {len(warnings)} warning(s))')
    sys.exit(0)

print(f'')
print(f'CONTRACT OWNERSHIP VALIDATION PASS')
print(f'All {len(rounds)} round(s) have proper domain separation.')
sys.exit(0)
"

EXIT_CODE=$?

echo ""
if [[ "${EXIT_CODE}" -eq 0 ]]; then
  echo "=== Result: PASS ==="
elif [[ "${EXIT_CODE}" -eq 1 ]]; then
  echo "=== Result: VIOLATION FOUND ==="
else
  echo "=== Result: ERROR ==="
fi

exit "${EXIT_CODE}"
