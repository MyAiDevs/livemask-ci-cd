#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy_workflow="${ROOT}/.github/workflows/dev-runtime-deploy.yml"
trigger_workflow="${ROOT}/.github/workflows/reusable-trigger-dev-runtime-deploy.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "${deploy_workflow}" ]] || fail "missing ${deploy_workflow}"
[[ -f "${trigger_workflow}" ]] || fail "missing ${trigger_workflow}"

if grep -Eq '^[[:space:]]+push:' "${deploy_workflow}"; then
  fail "dev-runtime-deploy must not auto-run on livemask-ci-cd push"
fi

grep -q "github.event.inputs.service || github.event.client_payload.service || 'status-only'" "${deploy_workflow}" \
  || fail "dev-runtime-deploy fallback must be status-only"

grep -q "status-only|backend|admin|website|job-service|nodeagent|all" "${deploy_workflow}" \
  || fail "dev-runtime-deploy must validate allowed service names"

grep -Fq 'DEV_RUNTIME_SECRET_FILE: "${{ github.workspace }}/../.livemask-dev/runtime-secrets.env"' "${deploy_workflow}" \
  || fail "dev-runtime-deploy generated dev secrets must use a runner-writable workspace sibling"
grep -q "Pre-clean stale build deps" "${deploy_workflow}" \
  || fail "dev-runtime-deploy must pre-clean stale build deps before checkout"
grep -Fq 'target="${GITHUB_WORKSPACE}/infra/_build_deps"' "${deploy_workflow}" \
  || fail "dev-runtime-deploy pre-clean must target only infra/_build_deps"
grep -q "clean: false" "${deploy_workflow}" \
  || fail "dev-runtime-deploy checkout must disable pre-step clean so stale build deps can be repaired"
grep -q "Reset stale build deps" "${deploy_workflow}" \
  || fail "dev-runtime-deploy must reset stale build deps after checkout"
grep -Fq 'sudo -n rm -rf "${target}"' "${deploy_workflow}" \
  || fail "dev-runtime-deploy stale build deps reset must support non-interactive sudo cleanup"
grep -q "busybox:1.36" "${deploy_workflow}" \
  || fail "dev-runtime-deploy stale build deps reset must support docker cleanup fallback"

grep -q "livemask-backend' && 'backend'" "${trigger_workflow}" \
  || fail "backend repo must map to backend service"
grep -q "livemask-admin' && 'admin'" "${trigger_workflow}" \
  || fail "admin repo must map to admin service"
grep -q "livemask-website' && 'website'" "${trigger_workflow}" \
  || fail "website repo must map to website service"
grep -q "livemask-job-service' && 'job-service'" "${trigger_workflow}" \
  || fail "job-service repo must map to job-service service"
grep -q "livemask-nodeagent' && 'nodeagent'" "${trigger_workflow}" \
  || fail "nodeagent repo must map to nodeagent service"
grep -q "|| 'status-only'" "${trigger_workflow}" \
  || fail "unknown repo fallback must be status-only"

echo "dev-runtime deploy scope smoke PASS"
