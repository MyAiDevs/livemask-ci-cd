#!/usr/bin/env bash
# monitor-learn.sh — Real-time, event-driven monitor for ALL roles.
#
# Watches every role's activity, detects patterns across the entire system,
# learns from successes AND failures, and feeds guidance back to each role
# via the event bus in real-time.
#
# Monitored roles: PM, Product, Tech, QA, Task Review, Leader, Executor, Codex
# Interaction: event-bus.sh — monitor subscribes to ALL events and reacts immediately
#
# Architecture:
#   Any Role emits event → Monitor receives → Analyze + Learn → Feed back to Role
#   ┌─────────┐    ┌──────────┐    ┌──────────────┐    ┌──────────────┐
#   │  Role   │───→│ Event Bus│───→│   Monitor    │───→│  Role Guide  │
#   │ (action)│    │ (event)  │    │ (analyze)    │    │ (feedback)   │
#   └─────────┘    └──────────┘    └──────────────┘    └──────────────┘
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
ROLE_CACHE_DIR="${ROLE_CACHE_DIR:-${HOME}/.claude/role-cache}"
MONITOR_DIR="${ROLE_CACHE_DIR}/monitor"
LEARNED_DIR="${ROLE_CACHE_DIR}/learned"
OBSERVATIONS_FILE="${MONITOR_DIR}/observations.jsonl"
PATTERNS_FILE="${LEARNED_DIR}/patterns.json"
GUIDANCE_FILE="${LEARNED_DIR}/guidance.json"
MEMORY_DIR="${HOME}/.claude/projects/-Users-sammytan-Developer-LiveMask/memory"

monitor_init() {
  mkdir -p "${MONITOR_DIR}" "${LEARNED_DIR}"
  touch "${OBSERVATIONS_FILE}" 2>/dev/null || true
  if [[ ! -f "${PATTERNS_FILE}" ]]; then
    echo '{"schema_version":2,"updated_at":"","role_patterns":{},"cross_role_patterns":[],"learned_rules":[],"velocity_stats":{}}' > "${PATTERNS_FILE}"
  fi
  if [[ ! -f "${GUIDANCE_FILE}" ]]; then
    echo '{"schema_version":2,"updated_at":"","per_role_guidance":{},"active_warnings":[],"deadlock_alerts":[]}' > "${GUIDANCE_FILE}"
  fi
}

# ── Observe ALL roles via event bus ──────────────────────────────────────
# Called by event-bus.sh after ANY event is emitted
monitor_observe_event() {
  local event_type="${1:-}" task_id="${2:-}" metadata="${3:-{}}"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  monitor_init

  python3 -c "
import json, pathlib, sys, time
event_type = '${event_type}'
task_id = '${task_id}'
now = '${now}'

# Record observation
obs = {
    'event_type': event_type,
    'task_id': task_id,
    'observed_at': now,
    'metadata': json.loads('${metadata}') if '${metadata}' and '${metadata}' != '{}' else {},
}

# Add contextual data based on event type
docs = pathlib.Path('${DOCS_DIR}')
root = pathlib.Path('${LIVEMASK_ROOT}')

# Agent state context
agent_file = root / '.claude/agent-state.json'
if agent_file.exists():
    agent = json.loads(agent_file.read_text())
    obs['agent_phase'] = agent.get('phase', '?')

# Task context
if task_id:
    ledger = json.loads((docs / 'docs/development/task-state-ledger.json').read_text())
    for m in ledger.get('modules', []):
        for t in m.get('tasks', []):
            if t.get('task_id') == task_id:
                obs['task_status'] = t.get('status', '?')
                obs['task_repo'] = t.get('repo', '?')
                break

path = pathlib.Path('${OBSERVATIONS_FILE}')
with open(path, 'a', encoding='utf-8') as f:
    f.write(json.dumps(obs, ensure_ascii=False) + '\n')
print(f'  [Monitor] Observed: {event_type} {task_id}')
" 2>/dev/null

  # Analyze immediately (real-time, not batch)
  monitor_analyze_event "${event_type}" "${task_id}" 2>/dev/null || true
  # DeepSeek: deep pattern analysis for recurring issues
  if [[ -n "${DEEPSEEK_API_KEY:-}" && -f "${PATTERNS_FILE}" ]]; then
    local recent; recent=$(tail -20 "${OBSERVATIONS_FILE}" 2>/dev/null | head -500 || echo "")
    [[ -n "${recent}" ]] && ds_monitor_analyze "${recent}" 2>/dev/null | tail -10 &
  fi
}

# ── Analyze single event in real-time ────────────────────────────────────
monitor_analyze_event() {

  # Detect repeated crash recovery pattern
  local crash_count; crash_count=$(grep -c "crash recovery" "${LOOP_LOG:-/tmp/claude/autonomous-loop.log}" 2>/dev/null || echo 0)
  if [[ "${crash_count}" -gt 5 ]]; then
    echo "  [Monitor] WARNING: ${crash_count} crash recoveries detected — possible bug!"
    executor_notify_human "crash_loop" "Monitor detected ${crash_count} crash recoveries — agent may be stuck" 2>/dev/null || true
    ds_monitor_analyze "Repeated crash recovery detected (${crash_count} times). Agent phase stuck. Root cause analysis needed." 2>/dev/null &
  fi
  local event_type="${1:-}" task_id="${2:-}"
  monitor_init

  python3 - "${event_type}" "${task_id}" "${PATTERNS_FILE}" "${GUIDANCE_FILE}" "${OBSERVATIONS_FILE}" "${DOCS_DIR}" "${LIVEMASK_ROOT}" "${MEMORY_DIR}" <<'PY'
import json, pathlib, sys, time
from collections import Counter, defaultdict
from datetime import datetime, timezone

event_type = sys.argv[1]
task_id = sys.argv[2]
patterns_file = pathlib.Path(sys.argv[3])
guidance_file = pathlib.Path(sys.argv[4])
obs_file = pathlib.Path(sys.argv[5])
docs = pathlib.Path(sys.argv[6])
root = pathlib.Path(sys.argv[7])
memory_dir = pathlib.Path(sys.argv[8])

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

# Load existing patterns
patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {"role_patterns": {}, "cross_role_patterns": [], "learned_rules": [], "velocity_stats": {}}
guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {"per_role_guidance": {}, "active_warnings": [], "deadlock_alerts": []}

# Count recent events for pattern detection
recent_events = []
if obs_file.exists():
    for line in obs_file.read_text().splitlines()[-200:]:
        try: recent_events.append(json.loads(line))
        except: pass

# ── Per-role pattern detection ────────────────────────────────────────
role_patterns = patterns.setdefault("role_patterns", {})

# PM patterns
pm_events = [e for e in recent_events if e["event_type"] in ("task_accepted", "task_completed", "task_blocked", "review_submitted", "leader_approved")]
if pm_events:
    role_patterns.setdefault("PM", {"event_counts": {}, "insights": []})
    for e in pm_events:
        role_patterns["PM"]["event_counts"][e["event_type"]] = role_patterns["PM"]["event_counts"].get(e["event_type"], 0) + 1

    # Insight: if no task_completed in last 20 events, executor may be stuck
    completions = sum(1 for e in pm_events[-20:] if e["event_type"] == "task_completed")
    if len(pm_events) >= 10 and completions == 0:
        insight = "PM: No task completions in recent window — executor may be stuck or not submitting"
        if insight not in role_patterns["PM"]["insights"]:
            role_patterns["PM"]["insights"].append(insight)
            guidance.setdefault("per_role_guidance", {}).setdefault("PM", []).append({"tip": insight, "at": now})

# Tech patterns
if event_type in ("code_committed", "review_submitted"):
    role_patterns.setdefault("Tech", {"event_counts": {}, "insights": []})
    role_patterns["Tech"]["event_counts"][event_type] = role_patterns["Tech"]["event_counts"].get(event_type, 0) + 1

# QA patterns
qa_events = [e for e in recent_events if e["event_type"] in ("qa_passed", "qa_failed", "review_submitted")]
if qa_events:
    role_patterns.setdefault("QA", {"event_counts": {}, "insights": []})
    for e in qa_events:
        role_patterns["QA"]["event_counts"][e["event_type"]] = role_patterns["QA"]["event_counts"].get(e["event_type"], 0) + 1

    # Insight: high QA failure rate
    qa_total = sum(1 for e in qa_events if e["event_type"] in ("qa_passed", "qa_failed"))
    qa_fails = sum(1 for e in qa_events if e["event_type"] == "qa_failed")
    if qa_total >= 3 and qa_fails / qa_total > 0.5:
        insight = f"QA: {qa_fails}/{qa_total} QA failures — check common failure reasons"
        if insight not in role_patterns["QA"]["insights"]:
            role_patterns["QA"]["insights"].append(insight)
            guidance.setdefault("per_role_guidance", {}).setdefault("QA", []).append({"tip": insight, "at": now})

# Leader patterns
leader_events = [e for e in recent_events if e["event_type"] in ("leader_approved", "changes_requested", "review_submitted")]
if leader_events:
    role_patterns.setdefault("Leader", {"event_counts": {}, "insights": []})
    for e in leader_events:
        role_patterns["Leader"]["event_counts"][e["event_type"]] = role_patterns["Leader"]["event_counts"].get(e["event_type"], 0) + 1

# Executor patterns
executor_events = [e for e in recent_events if e["agent_phase"] in ("implementing", "under_review", "revising", "merging")]
if executor_events:
    role_patterns.setdefault("Executor", {"event_counts": {}, "insights": []})
    phases = Counter(e.get("agent_phase", "?") for e in executor_events)
    for phase, count in phases.most_common(3):
        role_patterns["Executor"]["event_counts"][phase] = count

# ── Cross-role pattern detection ──────────────────────────────────────
cross_patterns = patterns.setdefault("cross_role_patterns", [])

# Deadlock detection: queue empty + PM lease held > 30min
empty_queue_events = [e for e in recent_events if e.get("event_type") == "task_completed"]
if len(empty_queue_events) >= 2:
    # Check if new tasks were created after completions
    accepted_after = [e for e in recent_events if e.get("event_type") == "task_accepted"]
    if len(accepted_after) < len(empty_queue_events[-3:]):
        alert = f"Cross-role: More completions than acceptances — queue may be draining. Last check: {now}"
        if alert not in [a.get("alert") for a in guidance.get("deadlock_alerts", [])]:
            guidance.setdefault("deadlock_alerts", []).append({"alert": alert, "at": now, "severity": "warning"})
            cross_patterns.append({"type": "queue_draining", "detected_at": now, "detail": alert})

# ── Write feedback to memory for real-time role consumption ────────────
for role_name, role_data in role_patterns.items():
    if "insights" in role_data and role_data["insights"]:
        memory_file = memory_dir / f"monitor-{role_name.lower()}.md"
        memory_file.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"# Monitor: {role_name} Insights\n", f"Updated: {now}\n\n"]
        for insight in role_data["insights"][-5:]:
            lines.append(f"- {insight}\n")
        memory_file.write_text("".join(lines))

# Save updated patterns and guidance
patterns["updated_at"] = now
guidance["updated_at"] = now
patterns_file.write_text(json.dumps(patterns, indent=2, ensure_ascii=False))
guidance_file.write_text(json.dumps(guidance, indent=2, ensure_ascii=False))
PY
}

# ── Get guidance for any role in real-time ───────────────────────────────
monitor_guide_role() {
  local role="${1:-}" task_id="${2:-}"
  monitor_init

  python3 - "${role}" "${task_id}" "${GUIDANCE_FILE}" "${PATTERNS_FILE}" "${DOCS_DIR}" <<'PY'
import json, pathlib, sys

role = sys.argv[1]
task_id = sys.argv[2]
guidance_file = pathlib.Path(sys.argv[3])
patterns_file = pathlib.Path(sys.argv[4])
docs = pathlib.Path(sys.argv[5])

guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {}
patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {}

print(f"=== Monitor Guidance for {role} ===")
print()

# Role-specific guidance
role_guidance = guidance.get("per_role_guidance", {}).get(role, [])
if role_guidance:
    print("Recent insights:")
    for g in role_guidance[-5:]:
        print(f"  - {g.get('tip', g)}")

# Cross-role patterns relevant to this role
for pattern in patterns.get("cross_role_patterns", [])[-5:]:
    if role.lower() in pattern.get("detail", "").lower():
        print(f"  [!] {pattern.get('detail', '')}")

# Deadlock alerts
for alert in guidance.get("deadlock_alerts", [])[-3:]:
    print(f"  [DEADLOCK] {alert.get('alert', '')} (severity={alert.get('severity', '?')})")

# Active warnings
for warn in guidance.get("active_warnings", [])[-5:]:
    print(f"  [WARN] {warn.get('message', '')}")

# Event stats for this role
role_stats = patterns.get("role_patterns", {}).get(role, {}).get("event_counts", {})
if role_stats:
    print(f"\nEvent counts for {role}:")
    for event, count in sorted(role_stats.items()):
        print(f"  {event}: {count}")

if not role_guidance and not role_stats:
    print("  No data yet — monitor needs more observations")
PY
}

# ── Full system health from monitor's perspective ────────────────────────
monitor_system_health() {
  monitor_init

  python3 - "${PATTERNS_FILE}" "${GUIDANCE_FILE}" "${OBSERVATIONS_FILE}" "${DOCS_DIR}" <<'PY'
import json, pathlib, sys
from collections import Counter

patterns_file = pathlib.Path(sys.argv[1])
guidance_file = pathlib.Path(sys.argv[2])
obs_file = pathlib.Path(sys.argv[3])
docs = pathlib.Path(sys.argv[4])

patterns = json.loads(patterns_file.read_text()) if patterns_file.exists() else {}
guidance = json.loads(guidance_file.read_text()) if guidance_file.exists() else {}

# Count observations
obs_count = 0
if obs_file.exists():
    obs_count = len(obs_file.read_text().splitlines())

# Event type distribution
event_counts = Counter()
if obs_file.exists():
    for line in obs_file.read_text().splitlines()[-500:]:
        try: event_counts[json.loads(line).get("event_type", "?")] += 1
        except: pass

print(json.dumps({
    "total_observations": obs_count,
    "recent_events": dict(event_counts.most_common(10)),
    "roles_monitored": list(patterns.get("role_patterns", {}).keys()),
    "cross_role_patterns": len(patterns.get("cross_role_patterns", [])),
    "deadlock_alerts": len(guidance.get("deadlock_alerts", [])),
    "active_warnings": len(guidance.get("active_warnings", [])),
    "last_updated": patterns.get("updated_at", "never"),
}, indent=2))
PY
}

# ── Learn from Codex reconcile patterns ────────────────────────────────
monitor_learn_from_codex() {
  echo "  [CodexLearn] Analyzing Codex reconcile patterns..."
  cd "${DOCS_DIR}" 2>/dev/null || return 0
  git log --oneline --since="24 hours ago" --grep="reconcile" 2>/dev/null | head -20 | python3 -c "
import sys,re
lines = sys.stdin.readlines()
completed = [l for l in lines if 'completed' in l.lower() or 'mark' in l.lower()]
skipped = [l for l in lines if 'skip' in l.lower() or 'blocked' in l.lower()]
patterns = []
for l in completed[:5]:
    tid = re.findall(r'TASK-[A-Z0-9-]+', l)
    if tid: patterns.append(f'Codex completed {tid[0]}')
for l in skipped[:3]:
    tid = re.findall(r'TASK-[A-Z0-9-]+', l)
    if tid: patterns.append(f'Codex skipped {tid[0]}')
for p in patterns: print(f'  [CodexLearn] {p}')
if not patterns: print('  [CodexLearn] No recent Codex activity')
" 2>/dev/null || true
}

# ── Track verify performance over time ──────────────────────────────────
monitor_performance_track() {
  local perf_file="${ROLE_CACHE_DIR}/monitor/perf-stats.jsonl"
  mkdir -p "$(dirname "${perf_file}")" 2>/dev/null
  for repo in livemask-backend livemask-admin livemask-docs; do
    local repo_dir="${LIVEMASK_ROOT}/${repo}"
    [[ ! -d "${repo_dir}" ]] && continue
    local start; start=$(python3 -c "import time; print(int(time.time()))")
    case "${repo}" in
      livemask-backend) cd "${repo_dir}" && go build ./... 2>/dev/null ;;
      livemask-admin) cd "${repo_dir}" && npm run build 2>/dev/null | tail -1 ;;
      livemask-docs) cd "${repo_dir}" && bash scripts/check-docs.sh 2>/dev/null | tail -1 ;;
    esac
    local elapsed; elapsed=$(python3 -c "import time; print(int(time.time())-${start})")
    python3 -c "import json,pathlib; d={'repo':'${repo}','elapsed_s':${elapsed},'at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}; f=open('${perf_file}','a'); f.write(json.dumps(d)+'\n')" 2>/dev/null || true
  done
  # Show trend
  python3 -c "
import json,pathlib
from collections import defaultdict
f=pathlib.Path('${perf_file}')
if f.exists():
    data=[json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    by_repo=defaultdict(list)
    for d in data: by_repo[d['repo']].append(d['elapsed_s'])
    for repo,times in sorted(by_repo.items()):
        avg=sum(times)/len(times)
        trend='↑' if len(times)>1 and times[-1]>times[-2] else '↓' if len(times)>1 else '→'
        print(f'  [Perf] {repo}: avg={avg:.1f}s over {len(times)} builds {trend}')
" 2>/dev/null || true
}

# ── Scan for TODOs and create tech-debt tasks ──────────────────────────
monitor_scan_techdebt() {
  echo "  [TechDebt] Scanning for TODOs..."
  local todo_count=0
  for repo in livemask-backend livemask-admin livemask-app livemask-nodeagent livemask-job-service; do
    local dir="${LIVEMASK_ROOT}/${repo}"
    [[ ! -d "${dir}" ]] && continue
    local count; count=$(grep -r "TODO\|FIXME\|HACK\|XXX" "${dir}" --include="*.go" --include="*.ts" --include="*.tsx" --include="*.dart" 2>/dev/null | grep -v "node_modules\|\.git\|vendor" | wc -l | tr -d ' ')
    todo_count=$((todo_count + count))
    [[ "${count}" -gt 5 ]] && echo "  [TechDebt] ${repo}: ${count} TODOs"
  done
  echo "  [TechDebt] Total TODOs across repos: ${todo_count}"
  [[ "${todo_count}" -gt 50 ]] && executor_notify_human "tech_debt" "${todo_count} TODOs across codebase"
}

# ── Active log monitor (runs in background, watches daemon log) ───────
monitor_watch_log() {
  local log_file="${1:-/tmp/claude/autonomous-loop.log}"
  local pid_file="${ROLE_CACHE_DIR}/monitor-log-watcher.pid"
  
  # Prevent duplicate watchers
  if [[ -f "${pid_file}" ]]; then
    local old_pid; old_pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
    if kill -0 "${old_pid}" 2>/dev/null; then return 0; fi
  fi
  
  echo $$ > "${pid_file}"
  
  # Use tail -F to follow even if log file is rotated
  tail -F "${log_file}" 2>/dev/null | while read -r line; do
    [[ -z "${line}" ]] && continue
    
    # Detect error patterns
    if echo "${line}" | grep -q "FAILED\|ERROR\|crash recovery\|dead.loop\|cannot renew\|DEAD\|假活"; then
      local err_type="unknown"
      if echo "${line}" | grep -q "crash recovery"; then err_type="crash_loop"
      elif echo "${line}" | grep -q "cannot renew"; then err_type="pm_lease_conflict"
      elif echo "${line}" | grep -q "DEAD\|假活"; then err_type="liveness_false_positive"
      elif echo "${line}" | grep -q "FAILED"; then err_type="operation_failed"
      fi
      
      # Increment error counter
      local err_file="${ROLE_CACHE_DIR}/monitor/error-${err_type}.count"
      local count; count=$(cat "${err_file}" 2>/dev/null || echo "0")
      count=$((count + 1))
      echo "${count}" > "${err_file}"
      
      # Alert on threshold
      if [[ "${count}" -ge 5 ]]; then
        echo "  [Monitor/LogWatch] ALERT: ${err_type} occurred ${count} times!"
        executor_push_alert "${err_type}" "Monitor detected ${count} occurrences of ${err_type}" 2>/dev/null || true
        
        # Self-heal: kill and restart daemon if crash-loop detected
        if [[ "${err_type}" == "crash_loop" && "${count}" -ge 10 ]]; then
          echo "  [Monitor/LogWatch] SELF-HEAL: restarting daemon due to crash loop"
          local daemon_pid; daemon_pid=$(cat "${ROLE_CACHE_DIR}/autonomous-loop.pid" 2>/dev/null || echo "")
          [[ -n "${daemon_pid}" ]] && kill "${daemon_pid}" 2>/dev/null || true
          sleep 2
          nohup bash "${CI_CD_DIR}/scripts/autonomous-loop.sh" &>/tmp/claude/autonomous-loop-stdout.log &
          # Reset counter
          echo "0" > "${err_file}"
        fi
      fi
    fi
    
    # Detect success patterns - reset counters
    if echo "${line}" | grep -q "TASK COMPLETED\|MERGE.*Successfully\|QA.*PASS"; then
      for f in "${ROLE_CACHE_DIR}/monitor/error-"*.count; do
        [[ -f "${f}" ]] && echo "0" > "${f}"
      done 2>/dev/null || true
    fi
  done
}

# Start log watcher in background
monitor_start_log_watcher() {
  monitor_watch_log "/tmp/claude/autonomous-loop.log" &
  echo "  [Monitor] Log watcher started (PID: $!)"
}

# ── Self-diagnosis: detect ineffective operations ────────────────────
monitor_self_diagnose() {
  local loop_log="${1:-/tmp/claude/autonomous-loop.log}"
  
  # Pattern: "No work" → "running role engine" → "Still no work" repeated
  local no_work_cycles; no_work_cycles=$(grep -c "Still no work\|No work — running" "${loop_log}" 2>/dev/null || echo "0")
  local completed_cycles; completed_cycles=$(grep -c "TASK COMPLETED\|task_completed" "${loop_log}" 2>/dev/null || echo "0")
  
  if [[ "${no_work_cycles}" -gt 3 && "${completed_cycles}" -eq 0 ]]; then
    echo "  [Monitor/Diag] WARNING: ${no_work_cycles} no-work cycles with 0 completions — possible gap detection failure"
    
    # Self-diagnose: check if contracts have gaps that AUTO-CREATE missed
    local gap_count; gap_count=$(python3 -c "
import json,re,pathlib
docs=pathlib.Path('${DOCS_DIR:-/Users/sammytan/Developer/LiveMask/livemask-docs}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
all_tasks={t['task_id'] for m in ledger['modules'] for t in m['tasks']}
ci=docs/'docs/contracts/contract-index.md'
gaps=0
if ci.exists():
    for line in ci.read_text().split('\n'):
        if '| Ready |' not in line: continue
        parts=[p.strip() for p in line.split('|')]
        if len(parts)<6: continue
        domain=parts[1]
        tids=re.findall(r'TASK-[A-Z0-9-]+',line)
        covered=any(t in all_tasks for t in tids)
        if not covered: gaps+=1
print(gaps)
" 2>/dev/null || echo "0")
    
    if [[ "${gap_count}" -gt 0 ]]; then
      echo "  [Monitor/Diag] FOUND: ${gap_count} contract gaps exist but AUTO-CREATE didn't detect them!"
      echo "  [Monitor/Diag] SELF-HEAL: triggering gap detection fix..."
      
      # Force-create tasks from gaps
      python3 -c "
import json,re,pathlib,datetime,subprocess
docs=pathlib.Path('${DOCS_DIR:-/Users/sammytan/Developer/LiveMask/livemask-docs}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
all_tasks={t['task_id'] for m in ledger['modules'] for t in m['tasks']}
ci=docs/'docs/contracts/contract-index.md'
now=datetime.datetime.now(datetime.timezone.utc)
created=0
if ci.exists():
    for line in ci.read_text().split('\n'):
        if '| Ready |' not in line: continue
        parts=[p.strip() for p in line.split('|')]
        if len(parts)<6: continue
        domain=parts[1][:40]
        tids=re.findall(r'TASK-[A-Z0-9-]+',line)
        domain_key=domain.lower().replace(' ','-')[:15]
        # Check both exact TASK-ID match AND domain-based coverage
        if any(t in all_tasks for t in tids): continue
        if any(domain_key in (t.get('notes','')+t.get('task_doc','')).lower() for m in ledger['modules'] for t in m['tasks'] if t.get('status') not in ('completed','completed_with_skip','cancelled')): continue
        repos_raw=parts[5][:80]
        first_repo=repos_raw.split('/')[0].strip()
        repo_map={'Backend':'livemask-backend','Admin':'livemask-admin','App':'livemask-app','Website':'livemask-website','CI-CD':'livemask-ci-cd','CI/CD':'livemask-ci-cd','NodeAgent':'livemask-nodeagent','Job Service':'livemask-job-service','Jobs':'livemask-job-service','Docs':'livemask-docs'}
        repo=repo_map.get(first_repo,'livemask-backend')
        tid=f'TASK-{repo.replace(\"livemask-\",\"\").upper()}-{domain.upper().replace(\" \",\"-\")[:20]}-MONITOR-{now.strftime(\"%Y%m%d%H%M%S\")}'
        tid=re.sub(r'[^A-Z0-9-]','',tid)[:60]
        if any(t.get('task_id')==tid for m in ledger['modules'] for t in m['tasks']): continue
        # Create dispatch packet
        dp_dir=docs/'docs/development/dispatch-packets'; dp_dir.mkdir(parents=True,exist_ok=True)
        (dp_dir/f'{tid}.json').write_text(json.dumps({'schema_version':1,'task_id':tid,'repo':repo,'priority':'P1','readiness':'ready','assigned_to':'claude','assigned_at':now.strftime('%Y-%m-%dT%H:%M:%SZ'),'expires_at':(now+datetime.timedelta(hours=48)).strftime('%Y-%m-%dT%H:%M:%SZ'),'assigned_by':'Monitor-Self-Heal','reason':f'Contract gap: {domain}'},indent=2))
        # Task doc
        (docs/'docs/development/tasks'/f'{tid}.md').parent.mkdir(parents=True,exist_ok=True)
        (docs/'docs/development/tasks'/f'{tid}.md').write_text(f'# {tid}\\n\\n> Status: ready\\n> Repository: {repo}\\n> Priority: P1\\n\\n## 1. Background\\nMonitor self-heal: detected contract gap for {domain}.\\n\\n## 2. Scope\\nImplement {domain} in {repo}.\\n\\n## 3. Acceptance Criteria\\n- [ ] Implementation complete\\n- [ ] Tests pass\\n- [ ] Build passes\\n\\n## 4. Cross-Repo Impact\\n{repos_raw}')
        # Ledger
        found=False
        for m in ledger['modules']:
            if m.get('module_id')==f'monitor-{domain_key}':
                m['tasks'].append({'task_id':tid,'repo':repo,'module_id':m['module_id'],'status':'ready','priority':'P1','task_doc':f'docs/development/tasks/{tid}.md','issue':'','notes':f'Monitor self-heal from gap detection failure. {now.strftime(\"%Y-%m-%d\")}'})
                found=True; break
        if not found:
            ledger['modules'].append({'module_id':f'monitor-{domain_key}','overall_status':'partial','owner_repo':repo,'tasks':[{'task_id':tid,'repo':repo,'module_id':f'monitor-{domain_key}','status':'ready','priority':'P1','task_doc':f'docs/development/tasks/{tid}.md','issue':'','notes':f'Monitor self-heal from gap detection failure. {now.strftime(\"%Y-%m-%d\")}'}]})
        created+=1
        if created>=3: break
    (docs/'docs/development/task-state-ledger.json').write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
    print(f'  [Monitor/SelfHeal] Created {created} tasks from undetected gaps')
" 2>/dev/null || true
      
      # Commit and push
      cd "${DOCS_DIR:-/Users/sammytan/Developer/LiveMask/livemask-docs}" 2>/dev/null || true
      git add docs/development/tasks/ docs/development/dispatch-packets/ docs/development/task-state-ledger.json 2>/dev/null
      if ! git diff --cached --quiet 2>/dev/null; then
        local br="task/monitor-self-heal-$(date -u +%Y%m%d-%H%M%S)"
        git checkout -b "${br}" 2>/dev/null && git commit -m "fix: Monitor self-heal — create tasks from undetected contract gaps" 2>/dev/null && git push origin "${br}" 2>/dev/null
      fi
    else
      echo "  [Monitor/Diag] No contract gaps — queue is genuinely empty"
    fi
  fi
}

# ── Detect silent role-engine crash ────────────────────────────────────
monitor_check_role_engine_health() {
  local output_file="/tmp/claude/role-engine-daemon.out"
  
  # Check if output file exists and is empty (silent crash)
  if [[ -f "${output_file}" ]] && [[ ! -s "${output_file}" ]]; then
    echo "  [Monitor] CRITICAL: Role engine output is EMPTY — silent crash detected!"
    
    # Self-diagnose: check scripts for syntax errors
    local syntax_errors; syntax_errors=$(find "${CI_CD_DIR}/scripts" -name "*.sh" -exec bash -n {} \; 2>&1 | grep -c "syntax error" || echo "0")
    if [[ "${syntax_errors}" -gt 0 ]]; then
      echo "  [Monitor] Found ${syntax_errors} syntax errors in scripts — attempting auto-fix..."
      # Run syntax check and log results
      find "${CI_CD_DIR}/scripts" -name "*.sh" -exec bash -n {} \; 2>&1 | grep "syntax error" | while read err; do
        echo "  [Monitor] Syntax error: ${err:0:120}"
      done
    fi
    
    # Check if contract gaps exist but no tasks created
    local gap_count; gap_count=$(python3 -c "
import json,re,pathlib
docs=pathlib.Path('${DOCS_DIR:-/Users/sammytan/Developer/LiveMask/livemask-docs}')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
all_tasks={t['task_id'] for m in ledger['modules'] for t in m['tasks']}
ci=docs/'docs/contracts/contract-index.md'
gaps=0
if ci.exists():
    for line in ci.read_text().split('\n'):
        if '| Ready |' not in line: continue
        parts=[p.strip() for p in line.split('|')]
        if len(parts)<6: continue
        tids=re.findall(r'TASK-[A-Z0-9-]+',line)
        domain_key=parts[1][:40].lower().replace(' ','-')[:15]
        if any(t in all_tasks for t in tids): continue
        if any(domain_key in (t.get('notes','')+t.get('task_doc','')).lower() for m in ledger['modules'] for t in m['tasks'] if t.get('status') not in ('completed','completed_with_skip','cancelled')): continue
        gaps+=1
print(gaps)
" 2>/dev/null || echo "0")
    
    if [[ "${gap_count}" -gt 0 ]]; then
      echo "  [Monitor] ${gap_count} contract gaps exist but AUTO-CREATE failed — triggering manual creation..."
      # Directly create tasks (bypass AUTO-CREATE)
      python3 -c "
import json,re,pathlib,datetime
docs=pathlib.Path('/Users/sammytan/Developer/LiveMask/livemask-docs')
ledger=json.loads((docs/'docs/development/task-state-ledger.json').read_text())
now=datetime.datetime.now(datetime.timezone.utc)
created=0
ci=docs/'docs/contracts/contract-index.md'
repo_map={'Backend':'livemask-backend','Admin':'livemask-admin','App':'livemask-app','Website':'livemask-website','CI-CD':'livemask-ci-cd','CI/CD':'livemask-ci-cd','NodeAgent':'livemask-nodeagent','Job Service':'livemask-job-service','Docs':'livemask-docs'}
all_tasks={t['task_id'] for m in ledger['modules'] for t in m['tasks']}
for line in ci.read_text().split('\n'):
    if '| Ready |' not in line: continue
    parts=[p.strip() for p in line.split('|')]
    if len(parts)<6: continue
    domain=parts[1][:40]; tids=re.findall(r'TASK-[A-Z0-9-]+',line)
    domain_key=domain.lower().replace(' ','-')[:15]
    if any(t in all_tasks for t in tids): continue
    if any(domain_key in (t.get('notes','')+t.get('task_doc','')).lower() for m in ledger['modules'] for t in m['tasks'] if t.get('status') not in ('completed','completed_with_skip','cancelled')): continue
    repos_raw=parts[5][:80]; first_repo=repos_raw.split('/')[0].strip()
    repo=repo_map.get(first_repo,'livemask-backend')
    tid=f'TASK-{repo.replace(\"livemask-\",\"\").upper()}-{domain.upper().replace(\" \",\"-\")[:20]}-MON-{now.strftime(\"%Y%m%d%H%M%S\")}'
    tid=re.sub(r'[^A-Z0-9-]','',tid)[:60]
    (docs/f'docs/development/tasks/{tid}.md').parent.mkdir(parents=True,exist_ok=True)
    (docs/f'docs/development/tasks/{tid}.md').write_text(f'# {tid}\n\n> Status: ready\n> Repository: {repo}\n> Priority: P1\n\n## 1. Background\nMonitor self-heal from AUTO-CREATE failure: {domain}\n\n## 2. Scope\nImplement {domain} in {repo}.\n\n## 3. Acceptance Criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Build passes\n\n## 4. Cross-Repo Impact\n{repos_raw}')
    (docs/'docs/development/dispatch-packets'/f'{tid}.json').parent.mkdir(parents=True,exist_ok=True)
    (docs/'docs/development/dispatch-packets'/f'{tid}.json').write_text(json.dumps({'task_id':tid,'repo':repo,'priority':'P1','readiness':'ready','assigned_to':'claude','assigned_at':now.strftime('%Y-%m-%dT%H:%M:%SZ'),'expires_at':(now+datetime.timedelta(hours=48)).strftime('%Y-%m-%dT%H:%M:%SZ')},indent=2))
    found=False
    for m in ledger['modules']:
        if m.get('module_id')==f'mon-{domain_key}': m['tasks'].append({'task_id':tid,'repo':repo,'status':'ready','priority':'P1','task_doc':f'docs/development/tasks/{tid}.md'}); found=True; break
    if not found: ledger['modules'].append({'module_id':f'mon-{domain_key}','overall_status':'partial','tasks':[{'task_id':tid,'repo':repo,'status':'ready','priority':'P1','task_doc':f'docs/development/tasks/{tid}.md'}]})
    created+=1; print(f'  [Monitor] Created: {tid}')
    if created>=5: break
(docs/'docs/development/task-state-ledger.json').write_text(json.dumps(ledger,indent=2,ensure_ascii=False))
print(f'  [Monitor] Total created: {created} tasks')
" 2>/dev/null || true
    fi
  fi
}
