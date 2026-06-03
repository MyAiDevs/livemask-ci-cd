#!/usr/bin/env bash
# venv.sh — Python virtual environment setup for LiveMask dev tools.
#
# Creates/activates a shared venv with the packages needed by:
#   - planner.py (stdlib + requests)
#   - cache.py  (diskcache)
#   - experience.py (stdlib)
#   - context_graph.py (diskcache + networkx)
#   - doc_parser.py (orjson + diskcache)
#   - repair.py (stdlib)
#   - lark_send.py (requests)
#   - gates.py (stdlib)
#   - ledger.py (stdlib)
#
# Usage:
#   source venv.sh                 # Activate only (must exist)
#   bash venv.sh setup             # Create or update venv
#   bash venv.sh check             # Check if venv is healthy
#   bash venv.sh path              # Print venv python path
#   bash venv.sh install <pkg...>  # Install additional packages

set -u
# NO set -e or pipefail! This is a sourced library.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENV_DIR="${PROJECT_DIR}/.venv"

setup() {
    echo "├─ Setting up Python virtual environment..."
    echo "│  VENV: ${VENV_DIR}"

    if [ ! -d "${VENV_DIR}" ]; then
        echo "│  creating venv..."
        python3 -m venv "${VENV_DIR}"
    else
        echo "│  venv already exists — updating"
    fi

    # Activate
    source "${VENV_DIR}/bin/activate"

    echo "│  Python: $(python --version 2>&1 || echo 'unknown')"
    echo "│  Pip:    $(pip --version 2>&1 || echo 'unknown')"

    # Upgrade pip
    pip install --quiet --upgrade pip 2>/dev/null || true

    # Install required packages
    local packages=(
        "diskcache>=5.6.3"
        "networkx>=3.2.1"
        "orjson>=3.9.10"
        "requests>=2.31.0"
    )

    echo "│  Installing required packages..."

    for pkg in "${packages[@]}"; do
        echo "│    installing ${pkg}..."
        pip install --quiet "${pkg}" 2>/dev/null || {
            echo "│    ⚠  failed to install ${pkg}" >&2
        }
    done

    echo "│  ✓ venv setup complete"
    deactivate 2>/dev/null || true
}

check() {
    if [ ! -d "${VENV_DIR}" ]; then
        echo "ERROR: venv not found at ${VENV_DIR}" >&2
        echo "Run: bash $0 setup" >&2
        return 1
    fi

    source "${VENV_DIR}/bin/activate"

    local errors=0

    # Check required modules
    local modules=("diskcache" "networkx" "orjson" "requests")
    echo "├─ Checking venv modules..."
    for mod in "${modules[@]}"; do
        if python -c "import ${mod}" 2>/dev/null; then
            echo "│  ✓ ${mod}"
        else
            echo "│  ✗ ${mod} missing"
            errors=$((errors + 1))
        fi
    done

    deactivate 2>/dev/null || true

    if [ "${errors}" -gt 0 ]; then
        echo "└─ ✗ ${errors} module(s) missing — run 'bash $0 setup'"
        return 1
    fi

    echo "└─ ✓ venv healthy"
    return 0
}

path() {
    if [ ! -d "${VENV_DIR}" ]; then
        echo "ERROR: venv not found" >&2
        return 1
    fi

    local py="${VENV_DIR}/bin/python3"
    if [ ! -f "${py}" ]; then
        py="${VENV_DIR}/bin/python"
    fi
    echo "${py}"
}

install_pkgs() {
    if [ ! -d "${VENV_DIR}" ]; then
        echo "ERROR: venv not found — run 'bash $0 setup' first" >&2
        return 1
    fi

    source "${VENV_DIR}/bin/activate"
    for pkg in "$@"; do
        echo "installing ${pkg}..."
        pip install "${pkg}"
    done
    deactivate 2>/dev/null || true
}

case "${1:-}" in
    setup)
        setup
        ;;
    check)
        check
        ;;
    path)
        path
        ;;
    install)
        shift
        install_pkgs "$@"
        ;;
    *)
        echo "Usage:"
        echo "  source $0              # Activate venv"
        echo "  bash $0 setup          # Create/update venv"
        echo "  bash $0 check          # Verify venv health"
        echo "  bash $0 path           # Print venv python path"
        echo "  bash $0 install <pkg>  # Install extra packages"
        ;;
esac
