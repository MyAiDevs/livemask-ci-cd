#!/usr/bin/env bash
set -euo pipefail

JOB_SERVICE_URL="${JOB_SERVICE_URL:-http://127.0.0.1:${LIVEMASK_JOB_SERVICE_PORT:-19191}}"

pass=0
fail=0

ok() {
  echo "PASS $*"
  pass=$((pass + 1))
}

bad() {
  echo "FAIL $*" >&2
  fail=$((fail + 1))
}

json_get() {
  curl -fsS "$1"
}

echo "[jobs-smoke] Job Service: ${JOB_SERVICE_URL}"

if health="$(json_get "${JOB_SERVICE_URL}/healthz")"; then
  echo "${health}" | grep -q '"status":"ok"' && ok "healthz ok" || bad "healthz missing ok"
else
  bad "healthz unavailable"
fi

if defs="$(json_get "${JOB_SERVICE_URL}/internal/jobs")"; then
  echo "${defs}" | grep -q 'geoip_source_update' && ok "definitions include geoip_source_update" || bad "missing geoip_source_update"
  echo "${defs}" | grep -q 'nodeagent_release_rollout' && ok "definitions include nodeagent_release_rollout" || bad "missing nodeagent_release_rollout"
else
  bad "definitions unavailable"
fi

run_body='{"job_type":"geoip_source_update","trigger_type":"manual","triggered_by":"smoke","parameters":{"source":"dbip_lite","edition":"country","force":false}}'
if run_resp="$(curl -fsS -X POST "${JOB_SERVICE_URL}/internal/jobs/runs" -H "Content-Type: application/json" -d "${run_body}")"; then
  run_id="$(printf '%s' "${run_resp}" | sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p')"
  [[ -n "${run_id}" ]] && ok "run created ${run_id}" || bad "run_id missing"
else
  bad "run create failed"
fi

if [[ -n "${run_id:-}" ]]; then
  sleep 3
  if detail="$(json_get "${JOB_SERVICE_URL}/internal/jobs/runs/${run_id}")"; then
    echo "${detail}" | grep -Eq '"status":"(queued|running|succeeded)"' && ok "run detail status valid" || bad "run detail invalid"
  else
    bad "run detail unavailable"
  fi
  if events="$(json_get "${JOB_SERVICE_URL}/internal/jobs/runs/${run_id}/events")"; then
    echo "${events}" | grep -q 'run_queued' && ok "events include run_queued" || bad "events missing run_queued"
    if echo "${events}" | grep -Eiq 'license_key|api_key|node_secret|private_key|hmac|token='; then
      bad "events leak sensitive marker"
    else
      ok "events do not leak sensitive markers"
    fi
  else
    bad "events unavailable"
  fi
fi

echo "[jobs-smoke] passed=${pass} failed=${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
