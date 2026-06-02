#!/usr/bin/env bash
# local-verify.sh — Per-repo build, test, lint, and runtime verification.
# Source this, then call verify_repo <repo> to run full verification.
# Outputs structured JSON results for model consumption.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"

# ── Service metadata ─────────────────────────────────────────────────────
# Returns: is_service|compose_service|health_url|port|dependencies
repo_service_info() {
  local repo="${1:-}"
  local bp="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
  local ap="${LIVEMASK_ADMIN_PORT:-3001}"
  local wp="${LIVEMASK_WEBSITE_PORT:-3002}"
  local np="${LIVEMASK_NODEAGENT_PORT:-19090}"
  local jp="${LIVEMASK_JOB_SERVICE_PORT:-19191}"
  case "${repo}" in
    livemask-backend)     echo "true|backend|http://127.0.0.1:${bp}/api/v1/health|${bp}|postgres,redis" ;;
    livemask-admin)       echo "true|admin|http://127.0.0.1:${ap}/login|${ap}|backend" ;;
    livemask-website)     echo "true|website|http://127.0.0.1:${wp}/|${wp}|backend" ;;
    livemask-nodeagent)   echo "true|nodeagent|http://127.0.0.1:${np}/config/status|${np}|backend" ;;
    livemask-job-service) echo "true|job-service|http://127.0.0.1:${jp}/healthz|${jp}|backend,postgres,redis" ;;
    *)                    echo "false||||" ;;
  esac
}

# Returns space-separated smoke test basenames for a repo
repo_smoke_tests() {
  local repo="${1:-}"
  case "${repo}" in
    livemask-backend)     echo "smoke node billing connect jobs dashboard" ;;
    livemask-admin)       echo "admin-nav-ia admin-nodes-ux" ;;
    livemask-website)     echo "website" ;;
    livemask-nodeagent)   echo "nodeagent-release nodeagent-config" ;;
    livemask-job-service) echo "jobs jobs-hardening" ;;
    *)                    echo "" ;;
  esac
}

verify_repo() {
  local repo="${1:-livemask-docs}"
  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  local result_file="/tmp/claude/verify-${repo}-$(date -u +%Y%m%d-%H%M%S).json"
  mkdir -p /tmp/claude

  python3 - "${repo}" "${repo_dir}" "${result_file}" <<'PY'
import json, os, subprocess, sys, pathlib, time

repo = sys.argv[1]
repo_dir = sys.argv[2]
result_file = sys.argv[3]

def run(cmd, cwd=None, timeout=60):
    """Run a command and return (rc, stdout, stderr, duration_sec)."""
    start = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd or repo_dir, text=True,
                          capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip(), round(time.time()-start, 1)
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s", timeout
    except Exception as e:
        return 1, "", str(e), 0

results = {"repo": repo, "checks": [], "passed": 0, "failed": 0, "skipped": 0}

def add_check(name, cmd, cwd=None, timeout=60, required=True):
    rc, out, err, dur = run(cmd, cwd=cwd, timeout=timeout)
    check = {"name": name, "command": " ".join(cmd), "exit_code": rc,
             "duration_sec": dur, "required": required,
             "stdout_tail": out[-500:] if out else "",
             "stderr_tail": err[-500:] if err else ""}
    if rc == 0:
        check["status"] = "pass"
        if required: results["passed"] += 1
    elif rc == 124:
        check["status"] = "timeout"
        if required: results["failed"] += 1
    else:
        check["status"] = "fail"
        if required: results["failed"] += 1
    results["checks"].append(check)
    return check

# Per-repo verification
r = pathlib.Path(repo_dir)
if not r.exists():
    results["error"] = f"repo directory not found: {repo_dir}"
    pathlib.Path(result_file).write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
    sys.exit(1)

if repo == "livemask-docs":
    add_check("check-docs", ["bash", "scripts/check-docs.sh"])
    add_check("git-diff-check", ["git", "diff", "--check"])
    add_check("git-status-clean", ["bash", "-c", "test -z \"$(git status --porcelain)\""], required=False)

elif repo == "livemask-ci-cd":
    # Bash syntax check all scripts
    add_check("bash-syntax", ["bash", "-c",
        "find scripts -name '*.sh' -exec bash -n {} \\; 2>&1"])
    add_check("workflow-syntax", ["bash", "scripts/validate-workflow-syntax.sh"], timeout=90)
    add_check("role-engine-flow", ["bash", "scripts/validate-role-engine-flow.sh"], timeout=30)
    add_check("role-engine-self-create-smoke", ["bash", "scripts/role-engine-self-create-smoke.sh"], timeout=30)
    add_check("autonomy-closed-loop-audit-smoke", ["bash", "scripts/autonomy-closed-loop-audit-smoke.sh"], timeout=120)
    add_check("target-repo-task-bridge-smoke", ["bash", "scripts/target-repo-task-bridge-smoke.sh"], timeout=120)
    add_check("worker-harness-smoke", ["bash", "scripts/worker-harness-smoke.sh"], timeout=240)
    add_check("git-diff-check", ["git", "diff", "--check"])
    # Docker compose validation (if available)
    if (r / "infra/docker-compose.local.yml").exists():
        add_check("docker-compose-validate", ["docker", "compose", "-f",
            "infra/docker-compose.local.yml", "config"], required=False)

elif repo == "livemask-backend":
    add_check("go-build", ["go", "build", "./..."], timeout=120)
    add_check("go-vet", ["go", "vet", "./..."], timeout=60)
    add_check("go-test", ["go", "test", "./..."], timeout=180, required=True)
    # Check OpenAPI/Swagger
    if (r / "internal/swagger").exists():
        add_check("swagger-exists", ["bash", "-c",
            "ls internal/swagger/*.yaml 2>/dev/null | head -1"], required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-admin":
    if (r / "package.json").exists():
        add_check("npm-install", ["npm", "install", "--prefer-offline"], timeout=120, required=False)
        add_check("npm-build", ["npm", "run", "build"], timeout=180)
        add_check("npm-lint", ["npm", "run", "lint"], timeout=60, required=False)
        add_check("npm-test", ["npm", "test"], timeout=120, required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-app":
    if (r / "pubspec.yaml").exists():
        add_check("flutter-analyze", ["flutter", "analyze"], timeout=120)
        add_check("flutter-test", ["flutter", "test"], timeout=120, required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-website":
    if (r / "package.json").exists():
        add_check("npm-build", ["npm", "run", "build"], timeout=180, required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-nodeagent":
    add_check("go-build", ["go", "build", "./..."], timeout=120)
    add_check("go-vet", ["go", "vet", "./..."], timeout=60)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-job-service":
    add_check("go-build", ["go", "build", "./..."], timeout=120)
    add_check("go-vet", ["go", "vet", "./..."], timeout=60)
    add_check("git-diff-check", ["git", "diff", "--check"])

else:
    results["error"] = f"unknown repo: {repo}"

pathlib.Path(result_file).write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
print(f"\nResult: {results['passed']} passed, {results['failed']} failed, {results['skipped']} skipped")
print(f"Full report: {result_file}")
PY
}

# Shortcut: quick check (just git status + basic lint)
verify_quick() {
  local repo="${1:-livemask-docs}"
  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  cd "${repo_dir}" 2>/dev/null || { echo "{\"error\": \"repo not found: ${repo}\"}"; return 1; }

  echo "{"
  echo "  \"repo\": \"${repo}\","
  echo "  \"branch\": \"$(git branch --show-current 2>/dev/null || echo '?')\","
  echo "  \"dirty\": $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo '?'),"
  echo "  \"behind_dev\": $(git rev-list --count HEAD..origin/dev 2>/dev/null || echo '?'),"
  echo "  \"ahead_dev\": $(git rev-list --count origin/dev..HEAD 2>/dev/null || echo '?'),"
  echo "  \"last_commit\": \"$(git log --oneline -1 2>/dev/null || echo '?')\""
  echo "}"
}

# Run verification for the repo a task belongs to
verify_task_repo() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: verify_task_repo <TASK-ID>"; return 1; }

  local repo; repo=$(python3 -c "
import json
ledger = json.load(open('${LIVEMASK_ROOT}/livemask-docs/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('repo',''))
            break
" 2>/dev/null || echo "")

  if [[ -z "${repo}" ]]; then
    echo "{\"error\": \"task ${tid} not found in ledger\"}"
    return 1
  fi

  verify_repo "${repo}"
}

# ── Runtime health verification ──────────────────────────────────────────
# Usage: verify_runtime_health <repo> [fast|full]
# Writes result to /tmp/claude/runtime-health-<repo>.json
# fast: start service + health check (< 2min), full: + docker compose (< 5min)
verify_runtime_health() {
  local repo="${1:-}" mode="${2:-fast}" now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local max_attempts=15; [[ "${mode}" == "full" ]] && max_attempts=30
  local outfile="/tmp/claude/runtime-health-${repo}.json"

  local info; info=$(repo_service_info "${repo}")
  local is_service; is_service=$(echo "${info}" | cut -d'|' -f1)
  local svc_name; svc_name=$(echo "${info}" | cut -d'|' -f2)
  local health_url; health_url=$(echo "${info}" | cut -d'|' -f3)

  if [[ "${is_service}" != "true" ]]; then
    python3 -c "import json;print(json.dumps({'repo':'${repo}','is_service':False,'skipped':True,'reason':'not a runnable service'}))" > "${outfile}"
    cat "${outfile}"
    return 0
  fi

  python3 - "${repo}" "${mode}" "${now}" "${svc_name}" "${health_url}" "${max_attempts}" "${LIVEMASK_ROOT}" "${outfile}" <<'PY'
import json, subprocess, time, sys, os

repo = sys.argv[1]
mode = sys.argv[2]
now = sys.argv[3]
svc_name = sys.argv[4]
health_url = sys.argv[5]
max_attempts = int(sys.argv[6])
livemask_root = sys.argv[7]
outfile = sys.argv[8]

results = {"repo": repo, "mode": mode, "timestamp": now, "checks": [], "passed": 0, "failed": 0, "skipped": 0}

def add_check(name, status, detail=""):
    results["checks"].append({"name": name, "status": status, "detail": detail})
    if status == "pass": results["passed"] += 1
    elif status == "fail": results["failed"] += 1
    else: results["skipped"] += 1

# Check docker
docker_ok = subprocess.run(["docker", "info"], capture_output=True, timeout=10).returncode == 0
if not docker_ok:
    add_check("docker-available", "skip", "docker not available")
    results["skipped"] = True
    with open(outfile, "w") as f: json.dump(results, f, indent=2)
    print(json.dumps(results))
    sys.exit(0)
add_check("docker-available", "pass", "docker daemon reachable")

# Check if service already running
try:
    r = subprocess.run(["curl", "-sSf", "--connect-timeout", "2", health_url], capture_output=True, timeout=5)
    already_running = r.returncode == 0
except:
    already_running = False

if already_running:
    add_check("health-endpoint", "pass", f"service already running at {health_url}")
else:
    cf = f"{livemask_root}/livemask-ci-cd/infra/docker-compose.local.yml"
    if os.path.exists(cf):
        subprocess.run(["docker", "compose", "-f", cf, "up", "-d", svc_name],
                       cwd=os.path.dirname(cf), capture_output=True, timeout=120)
        health_ok = False
        for attempt in range(max_attempts):
            r = subprocess.run(["curl", "-sSf", "--connect-timeout", "3", health_url],
                              capture_output=True, timeout=5)
            if r.returncode == 0:
                health_ok = True
                resp = r.stdout.decode()[:200].replace("\n", " ")
                add_check("health-endpoint", "pass", f"startup {attempt*2}s, response: {resp}")
                break
            time.sleep(2)
        if not health_ok:
            add_check("health-endpoint", "fail", f"could not reach {health_url} after {max_attempts*2}s")
    else:
        add_check("health-endpoint", "skip", f"no compose file")

# Check runtime errors
if already_running or svc_name:
    cf = f"{livemask_root}/livemask-ci-cd/infra/docker-compose.local.yml"
    if os.path.exists(cf):
        r = subprocess.run(["docker", "compose", "-f", cf, "logs", svc_name, "--tail=100"],
                          cwd=os.path.dirname(cf), capture_output=True, timeout=15, text=True)
        has_panic = "panic" in r.stdout.lower() or "FATAL" in r.stdout
        if has_panic:
            add_check("runtime-errors", "fail", "panic/fatal found in logs")
        else:
            add_check("runtime-errors", "pass", "no panics/fatals in recent logs")
    else:
        add_check("runtime-errors", "skip", "no container logs available")
else:
    add_check("runtime-errors", "skip", "no container logs available")

with open(outfile, "w") as f: json.dump(results, f, indent=2)
print(json.dumps(results))
PY
  # The python3 script already printed JSON to stdout — don't cat again
}

# ── Targeted smoke tests ─────────────────────────────────────────────────
# Writes result to /tmp/claude/smoke-tests-<repo>.json
verify_smoke_tests() {
  local repo="${1:-}" top_n="${2:-3}"
  local outfile="/tmp/claude/smoke-tests-${repo}.json"

  python3 - "${repo}" "${top_n}" "${LIVEMASK_ROOT}" "${outfile}" <<'PY'
import json, subprocess, time, sys, os

repo = sys.argv[1]
top_n = int(sys.argv[2])
livemask_root = sys.argv[3]
outfile = sys.argv[4]

# Map repo to smoke test basenames
smoke_map = {
    "livemask-backend": "smoke node billing connect jobs dashboard".split(),
    "livemask-admin": "admin-nav-ia admin-nodes-ux".split(),
    "livemask-website": ["website"],
    "livemask-nodeagent": "nodeagent-release nodeagent-config".split(),
    "livemask-job-service": "jobs jobs-hardening".split(),
}
names = smoke_map.get(repo, [])

if not names:
    result = {"repo": repo, "smoke_tests_run": 0, "skipped": True, "reason": "no smoke tests for repo"}
    with open(outfile, "w") as f: json.dump(result, f, indent=2)
    print(json.dumps(result))
    sys.exit(0)

smoke_dir = f"{livemask_root}/livemask-ci-cd/scripts"
results = {"repo": repo, "results": [], "smoke_tests_run": 0, "smoke_tests_passed": 0, "smoke_tests_failed": 0}
count = 0

for name in names:
    if count >= top_n: break
    script = f"{smoke_dir}/smoke.sh" if name == "smoke" else f"{smoke_dir}/{name}-smoke.sh"
    if os.path.isfile(script) and os.access(script, os.X_OK):
        start = time.time()
        try:
            r = subprocess.run(["timeout", "180", "bash", script], capture_output=True, timeout=190)
            dur = int(time.time() - start)
            if r.returncode == 0:
                results["results"].append({"name": name, "status": "pass", "duration_sec": dur})
                results["smoke_tests_passed"] += 1
            else:
                results["results"].append({"name": name, "status": "fail", "duration_sec": dur})
                results["smoke_tests_failed"] += 1
            results["smoke_tests_run"] += 1
        except:
            results["results"].append({"name": name, "status": "timeout", "duration_sec": 190})
            results["smoke_tests_failed"] += 1
            results["smoke_tests_run"] += 1
        count += 1

with open(outfile, "w") as f: json.dump(results, f, indent=2)
print(json.dumps(results))
PY
}

# ── Test coverage analysis ──────────────────────────────────────────────
verify_coverage() {
  local repo="${1:-livemask-backend}"
  case "${repo}" in
    livemask-backend)
      cd "${LIVEMASK_ROOT}/livemask-backend" 2>/dev/null || return 1
      go test -coverprofile=/tmp/coverage.out ./... 2>/dev/null | tail -5
      go tool cover -func=/tmp/coverage.out 2>/dev/null | tail -1 | awk '{print "  Total coverage: "$NF}'
      ;;
    livemask-admin)
      cd "${LIVEMASK_ROOT}/livemask-admin" 2>/dev/null || return 1
      npx jest --coverage 2>/dev/null | grep "All files" | head -1 | awk '{print "  Coverage: "$0}' || echo "  (nyc/jest not configured)"
      ;;
  esac
}
