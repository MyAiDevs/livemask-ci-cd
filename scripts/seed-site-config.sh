#!/usr/bin/env bash
# Seed site-config privacy policy and terms of service via Admin API.
# Delegates to seed-site-config.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Seed Site Config: Privacy Policy & Terms of Service ==="
echo "Backend: ${LIVEMASK_STAGING_BACKEND_URL:-http://127.0.0.1:18080}"
echo ""

python3 "${SCRIPT_DIR}/seed-site-config.py" "$@"
