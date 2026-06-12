#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(pwd -P)}"
repo="$(cd -- "${repo}" && pwd -P)"

export GOCACHE="${GOCACHE:-/tmp/go-build}"
export GOMODCACHE="${GOMODCACHE:-/tmp/go-mod}"

if command -v go >/dev/null 2>&1; then
  GO_BIN="go"
elif [[ -x "/usr/local/go/bin/go" ]]; then
  GO_BIN="/usr/local/go/bin/go"
else
  echo "missing required command: go" >&2
  exit 2
fi

echo "[local-validate-nodeagent] repo=${repo}"
cd -- "${repo}"

echo "[local-validate-nodeagent] vet"
"${GO_BIN}" vet ./...

echo "[local-validate-nodeagent] unit tests"
"${GO_BIN}" test ./... -count=1

echo "[local-validate-nodeagent] build"
"${GO_BIN}" build ./cmd/nodeagent
