#!/usr/bin/env bash
# /mvp — Quick MVP task submission
# Usage: /mvp bug "description" | /mvp requirement "description" | /mvp feature "description"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export DOCS_DIR="${DOCS_DIR:-/Users/sammytan/Developer/LiveMask/livemask-docs}"
export ROLE_CACHE_DIR="${ROLE_CACHE_DIR:-/Users/sammytan/.claude/role-cache}"

TYPE="${1:-}"
shift 2>/dev/null || true
DESCRIPTION="${*:-}"

if [[ -z "$TYPE" || -z "$DESCRIPTION" ]]; then
  echo "Usage: /mvp <bug|requirement|feature> <description>"
  echo "Examples:"
  echo "  /mvp bug 'Admin dashboard crashes on refresh'"
  echo "  /mvp requirement 'Add two-factor authentication for admin users'"
  echo "  /mvp feature 'Dark mode support for website'"
  exit 1
fi

python3 "${SCRIPT_DIR}/lib/py/mvp_submit.py" "$TYPE" "$DESCRIPTION"
