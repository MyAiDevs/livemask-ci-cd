#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(pwd -P)}"
repo="$(cd -- "${repo}" && pwd -P)"

export GOCACHE="${GOCACHE:-/tmp/go-build}"
export GOMODCACHE="${GOMODCACHE:-/tmp/go-mod}"

command -v go >/dev/null 2>&1 || {
  echo "missing required command: go" >&2
  exit 2
}

echo "[local-validate-nodeagent] repo=${repo}"
cd -- "${repo}"

echo "[local-validate-nodeagent] vet"
go vet ./...

echo "[local-validate-nodeagent] unit tests"
go test ./... -count=1

echo "[local-validate-nodeagent] build"
go build ./cmd/nodeagent
