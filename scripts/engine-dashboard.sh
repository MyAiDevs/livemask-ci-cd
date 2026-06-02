#!/usr/bin/env bash
# engine-dashboard.sh - compatibility wrapper for the Python dashboard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/engine-dashboard.py" "$@"
