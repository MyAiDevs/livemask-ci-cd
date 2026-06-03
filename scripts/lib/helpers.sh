#!/usr/bin/env bash
# helpers.sh — Single-agent-usable shell helper functions for Claude dev loop.
#
# Pure Shell. No embedded Python — delegates to Python tools as subprocesses.
#
# Source this file:
#   source scripts/lib/helpers.sh
#
# Functions:
#   doc_parser functions   — resolve_task_source, parse_md_table, parse_contract
#   cache functions         — cache_get, cache_set, cache_incr, cache_list
#   experience functions    — learn_experience, suggest_fix
#   log-watch functions     — watch_start, watch_stop, watch_status
#   git helpers             — git_branch_exists, git_has_diverged, git_ff_pull
#   gh_available            — check GitHub CLI
#   pre_commit_verify       — quick pre-commit sanity check
#   check_repo_integrity    — verify git repo is clean
#   cleanup_alerts          — clear terminal alerts
#   log_evidence            — log evidence line
#   get_evidence            — read evidence from evidence chain
#   auto_resolve_conflict   — git conflict resolver
#   verify_repo             — repo-native build+test+vet

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
PY_DIR="${CI_CD_DIR}/scripts/lib/py"

# ── Doc Parser Helpers ─────────────────────────────────────────────────

resolve_task_source() {
    local task_id="$1"
    local ledger="${2:-${LIVEMASK_ROOT}/livemask-docs/docs/development/task-state-ledger.json}"
    local docs_dir="${3:-${LIVEMASK_ROOT}/livemask-docs/docs/development/tasks}"

    # Use doc_parser.py for fast cached lookup (no grep)
    local dp="${PY_DIR}/doc_parser.py"
    if [ -f "${dp}" ]; then
        local result
        result=$(python3 "${dp}" ledger-lookup "${ledger}" "${task_id}" 2>/dev/null || echo '{"found":false}')
        local found
        found=$(echo "${result}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('found', False))" 2>/dev/null || echo "False")

        if [ "${found}" = "True" ]; then
            # Check task doc exists
            if [ -f "${docs_dir}/${task_id}.md" ]; then
                echo "{\"task_id\":\"${task_id}\",\"source\":\"ledger\",\"doc_path\":\"${docs_dir}/${task_id}.md\"}"
            else
                echo "{\"task_id\":\"${task_id}\",\"source\":\"ledger\",\"doc_path\":\"\"}"
            fi
            return 0
        fi
    fi

    # Fallback: check if task doc exists
    if [ -f "${docs_dir}/${task_id}.md" ]; then
        echo "{\"task_id\":\"${task_id}\",\"source\":\"doc\",\"doc_path\":\"${docs_dir}/${task_id}.md\"}"
        return 0
    fi

    echo "{\"task_id\":\"${task_id}\",\"source\":\"unknown\",\"doc_path\":\"\"}"
    return 1
}

parse_md_table() {
    local file="$1"
    local py="${PY_DIR}/doc_parser.py"
    if [ -f "${py}" ]; then
        python3 "${py}" parse-md "${file}" 2>/dev/null || echo '{"table_count":0,"total_rows":0}'
    else
        echo '{"table_count":0,"total_rows":0}'
    fi
}

parse_mvp() {
    local file="$1"
    local py="${PY_DIR}/doc_parser.py"
    if [ -f "${py}" ]; then
        python3 "${py}" parse-mvp "${file}" 2>/dev/null || echo '{"entry_count":0}'
    else
        echo '{"entry_count":0}'
    fi
}

parse_contracts() {
    local file="$1"
    local py="${PY_DIR}/doc_parser.py"
    if [ -f "${py}" ]; then
        python3 "${py}" parse-contracts "${file}" 2>/dev/null || echo '{"contract_count":0,"contracts":[]}'
    else
        echo '{"contract_count":0,"contracts":[]}'
    fi
}

ledger_refresh() {
    local ledger="${1:-${LIVEMASK_ROOT}/livemask-docs/docs/development/task-state-ledger.json}"
    local py="${PY_DIR}/doc_parser.py"
    if [ -f "${py}" ]; then
        python3 "${py}" ledger-refresh "${ledger}" 2>/dev/null || true
    fi
}

# ── Cache Helpers ──────────────────────────────────────────────────────

_cache_exec() {
    local py="${PY_DIR}/cache.py"
    if [ -f "${py}" ]; then
        python3 "${py}" "$@"
    fi
}

cache_get() {
    local ns="$1" key="$2"
    _cache_exec get "${ns}" "${key}" 2>/dev/null | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('value', ''))
except: print('')
"
}

cache_set() {
    local ns="$1" key="$2" value="$3"
    shift 3
    _cache_exec set "${ns}" "${key}" "${value}" "$@" 2>/dev/null | python3 -c "...
import sys, json
try: d = json.load(sys.stdin); print(d.get('value_truncated', d.get('status', 'ok'))[:40])
except: print('')
"
}

cache_incr() {
    local ns="$1" key="$2"
    local delta="${3:-1}"
    _cache_exec incr "${ns}" "${key}" --delta "${delta}" 2>/dev/null | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('value', '?'))
except: print('?')
"
}

cache_list() {
    local ns="$1"
    shift
    _cache_exec list "${ns}" "$@" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k in d.get('keys', []): print(\"$ '{k['key']}' (expires: {k.get('expire_at','-')})\")
except: pass
"
}

cache_del() {
    local ns="$1" key="$2"
    _cache_exec del "${ns}" "${key}" 2>/dev/null | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('action', 'error'))
except: print('error')
"
}

# ── Experience System Helpers ─────────────────────────────────────────

learn_experience() {
    local error_input="$1" action="$2" success="$3"
    local repo="${4:-}"
    local py="${PY_DIR}/experience.py"
    if [ -f "${py}" ]; then
        python3 "${py}" record "${error_input}" "${action}" "${success}" \
            ${repo:+--repo "${repo}"} 2>/dev/null || true
    fi
}

suggest_fix() {
    local log_file="$1"
    local py="${PY_DIR}/experience.py"
    if [ -f "${py}" ] && [ -f "${log_file}" ]; then
        python3 "${py}" suggest "${log_file}" 2>/dev/null || echo '{"status":"no_experience"}'
    else
        echo '{"status":"no_experience"}'
    fi
}

experience_stats() {
    local py="${PY_DIR}/experience.py"
    if [ -f "${py}" ]; then
        python3 "${py}" stats 2>/dev/null || echo '{"total_experiences":0}'
    fi
}

# ── Log-Watch Helpers ─────────────────────────────────────────────────

watch_start() {
    bash "${CI_CD_DIR}/scripts/lib/log-watch.sh" start
}

watch_stop() {
    bash "${CI_CD_DIR}/scripts/lib/log-watch.sh" stop
}

watch_status() {
    bash "${CI_CD_DIR}/scripts/lib/log-watch.sh" status
}

# ── Git Helpers ───────────────────────────────────────────────────────

git_branch_exists() {
    local repo="$1" branch="$2"
    (cd "${LIVEMASK_ROOT}/${repo}" && git rev-parse --verify "${branch}" 2>/dev/null) && return 0
    return 1
}

git_has_diverged() {
    local repo="$1" branch="$2" base="${3:-dev}"
    (cd "${LIVEMASK_ROOT}/${repo}" && \
        git merge-base --is-ancestor "${base}" "${branch}" 2>/dev/null) && return 1
    return 0
}

git_ff_pull() {
    local repo="$1" branch="${2:-dev}"
    (cd "${LIVEMASK_ROOT}/${repo}" && \
        git pull --ff-only origin "${branch}" 2>&1) || {
        echo "WARNING: fast-forward pull failed for ${repo}/${branch}" >&2
        return 1
    }
}

git_current_branch() {
    local repo="$1"
    (cd "${LIVEMASK_ROOT}/${repo}" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || echo "unknown"
}

git_dirty() {
    local repo="$1"
    (cd "${LIVEMASK_ROOT}/${repo}" && git status --porcelain 2>/dev/null) || true
}

# ── GitHub Helpers ────────────────────────────────────────────────────

gh_available() {
    command -v gh &>/dev/null && gh auth status 2>&1 | grep -q "Logged in"
}

gh_create_issue() {
    local repo="$1" title="$2" body="$3"
    if gh_available; then
        gh issue create --repo "MyAiDevs/${repo}" --title "${title}" --body "${body}" 2>/dev/null || {
            echo "gh issue create failed for ${repo}" >&2
            return 1
        }
    else
        echo "gh not available" >&2
        return 1
    fi
}

# ── Pre-Commit Verify ──────────────────────────────────────────────────

pre_commit_verify() {
    local repo="${1:-}"
    if [ -z "${repo}" ]; then
        echo "usage: pre_commit_verify <repo>" >&2
        return 1
    fi

    local repo_path="${LIVEMASK_ROOT}/${repo}"
    if [ ! -d "${repo_path}" ]; then
        echo "repo not found: ${repo_path}" >&2
        return 1
    fi

    pushd "${repo_path}" >/dev/null || return 1

    local errors=0
    echo "├─ pre-commit verify for ${repo}"

    # 1. Git status
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        echo "│  ⚠  uncommitted changes"
    else
        echo "│  ✓ clean working tree"
    fi

    # 2. Build
    case "${repo}" in
        livemask-backend|livemask-nodeagent|livemask-job-service)
            if go build ./... 2>/dev/null; then
                echo "│  ✓ go build"
            else
                echo "│  ✗ go build FAILED" >&2
                errors=$((errors + 1))
            fi
            if go vet ./... 2>/dev/null; then
                echo "│  ✓ go vet"
            else
                echo "│  ✗ go vet FAILED" >&2
                errors=$((errors + 1))
            fi
            ;;
        livemask-admin|livemask-website)
            if npm run build 2>/dev/null; then
                echo "│  ✓ npm build"
            else
                echo "│  ✗ npm build FAILED" >&2
                errors=$((errors + 1))
            fi
            ;;
        livemask-app)
            if flutter analyze 2>/dev/null; then
                echo "│  ✓ flutter analyze"
            else
                echo "│  ✗ flutter analyze FAILED" >&2
                errors=$((errors + 1))
            fi
            ;;
        livemask-ci-cd)
            if bash -n scripts/*.sh 2>/dev/null; then
                echo "│  ✓ shellcheck bash syntax"
            else
                echo "│  ✗ shell syntax FAILED" >&2
                errors=$((errors + 1))
            fi
            ;;
        *)
            echo "│  ? no verify rules for ${repo}"
            ;;
    esac

    popd >/dev/null || return 1

    if [ "${errors}" -gt 0 ]; then
        echo "└─ ✗ ${errors} error(s) found"
        return 1
    fi
    echo "└─ ✓ pre-commit verify passed"
    return 0
}

# ── Repo Integrity ────────────────────────────────────────────────────

check_repo_integrity() {
    local repo="${1:-}"
    if [ -z "${repo}" ]; then
        echo "usage: check_repo_integrity <repo>" >&2
        return 1
    fi

    local repo_path="${LIVEMASK_ROOT}/${repo}"
    if [ ! -d "${repo_path}" ]; then
        echo "ERROR: ${repo} not found at ${repo_path}" >&2
        return 2
    fi

    local issues=0

    # Check git repo
    if [ ! -d "${repo_path}/.git" ]; then
        echo "WARN: ${repo} missing .git" >&2
        issues=$((issues + 1))
    fi

    # Check critical files
    case "${repo}" in
        livemask-backend)       [ -f "${repo_path}/go.mod" ] || { echo "WARN: no go.mod"; issues=$((issues + 1)); } ;;
        livemask-admin)         [ -f "${repo_path}/package.json" ] || { echo "WARN: no package.json"; issues=$((issues + 1)); } ;;
        livemask-app)           [ -f "${repo_path}/pubspec.yaml" ] || { echo "WARN: no pubspec.yaml"; issues=$((issues + 1)); } ;;
        livemask-nodeagent)     [ -f "${repo_path}/go.mod" ] || { echo "WARN: no go.mod"; issues=$((issues + 1)); } ;;
        livemask-job-service)   [ -f "${repo_path}/go.mod" ] || { echo "WARN: no go.mod"; issues=$((issues + 1)); } ;;
        livemask-website)       [ -f "${repo_path}/package.json" ] || { echo "WARN: no package.json"; issues=$((issues + 1)); } ;;
    esac

    return "${issues}"
}

# ── Alert Cleanup ──────────────────────────────────────────────────────

cleanup_alerts() {
    local tmp_files=(
        "/tmp/dev-loop-verify-$$.log"
        "/tmp/dev-loop-suggest-$$.json"
        "/tmp/log-watch-suggest-$$.json"
        "/tmp/repair-$$.log"
        "/tmp/exp-suggest-$$.json"
    )
    for f in "${tmp_files[@]}"; do
        [ -f "${f}" ] && rm -f "${f}" 2>/dev/null || true
    done
}

# ── Evidence Logging ──────────────────────────────────────────────────

log_evidence() {
    local task_id="$1" field="$2" value="$3"
    local py="${PY_DIR}/planner.py"
    if [ -f "${py}" ]; then
        python3 "${py}" evidence "${task_id}" "--${field}" "${value}" 2>/dev/null || true
    fi
}

get_evidence() {
    local task_id="$1"
    local py="${PY_DIR}/planner.py"
    if [ -f "${py}" ]; then
        python3 "${py}" evidence-show "${task_id}" 2>/dev/null || echo '{"status":"not_found"}'
    else
        echo '{"status":"not_found"}'
    fi
}

# ── Auto-Conflict Resolution ──────────────────────────────────────────

auto_resolve_conflict() {
    local repo="$1" file="$2"
    local repo_path="${LIVEMASK_ROOT}/${repo}"

    if [ ! -f "${repo_path}/${file}" ]; then
        echo "file not found: ${repo_path}/${file}" >&2
        return 1
    fi

    pushd "${repo_path}" >/dev/null || return 1

    # Check if file has conflict markers
    if grep -q "^<<<<<<< " "${file}" 2>/dev/null; then
        echo "auto-resolving conflict in ${file}..." >&2

        # Use git checkout --ours or --theirs for simple resolutions
        # The merge is assumed to be in progress
        git checkout --theirs "${file}" 2>/dev/null && {
            git add "${file}"
            echo "  → resolved with theirs (${file})"
            popd >/dev/null || true
            return 0
        }

        # Fallback: try --ours
        git checkout --ours "${file}" 2>/dev/null && {
            git add "${file}"
            echo "  → resolved with ours (${file})"
            popd >/dev/null || true
            return 0
        }

        echo "  → could not auto-resolve ${file}" >&2
        popd >/dev/null || true
        return 1
    fi

    popd >/dev/null || true
    echo "no conflict markers in ${file}"
    return 0
}

# ── Repo-native verify ────────────────────────────────────────────────

verify_repo() {
    local repo="$1"
    local verbose="${2:-false}"
    local repo_path="${LIVEMASK_ROOT}/${repo}"

    if [ ! -d "${repo_path}" ]; then
        if [ "${verbose}" = "true" ]; then echo "repo not found: ${repo_path}" >&2; fi
        return 1
    fi

    pushd "${repo_path}" >/dev/null || return 1

    local status="PASS"
    local build_output=""
    local test_output=""
    local vet_output=""
    local build_pass=true test_pass=true vet_pass=true

    # Build
    case "${repo}" in
        livemask-backend|livemask-nodeagent|livemask-job-service)
            build_output=$(go build ./... 2>&1) || build_pass=false
            ;;
        livemask-admin|livemask-website)
            build_output=$(npm run build 2>&1) || build_pass=false
            ;;
        livemask-app)
            build_output=$(flutter build apk --debug 2>&1) || {
                build_pass=false
                build_output=$(flutter build apk --debug 2>&1 || true)
            }
            ;;
        livemask-ci-cd)
            build_output=$(bash -n scripts/*.sh 2>&1) || build_pass=false
            ;;
        livemask-docs)
            build_output=$(bash scripts/check-docs.sh 2>&1) || build_pass=false
            ;;
        *)
            build_output="no build command defined for ${repo}"
            build_pass=true
            ;;
    esac

    # Test (for Go repos and npm repos)
    case "${repo}" in
        livemask-backend|livemask-nodeagent|livemask-job-service)
            test_output=$(go test ./... 2>&1) || test_pass=false
            ;;
        livemask-admin)
            test_output=$(npm test 2>&1) || test_pass=false
            ;;
        *)
            test_output="no test command defined"
            test_pass=true
            ;;
    esac

    # Vet (Go repos only)
    case "${repo}" in
        livemask-backend|livemask-nodeagent|livemask-job-service)
            vet_output=$(go vet ./... 2>&1) || vet_pass=false
            ;;
        *)
            vet_output="no vet command defined"
            vet_pass=true
            ;;
    esac

    if [ "${build_pass}" = false ] || [ "${test_pass}" = false ] || [ "${vet_pass}" = false ]; then
        status="FAIL"
    fi

    popd >/dev/null || true

    echo "{\"repo\":\"${repo}\",\"status\":\"${status}\",\"build\":${build_pass},\"test\":${test_pass},\"vet\":${vet_pass}}"
    return 0
}
