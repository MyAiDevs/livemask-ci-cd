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

echo "[local-validate-job-service] repo=${repo}"
cd -- "${repo}"

echo "[local-validate-job-service] unit tests"
"${GO_BIN}" test ./... -count=1

echo "[local-validate-job-service] sqlstore integration tests"
"${GO_BIN}" test -tags sqlstore ./... -count=1

echo "[local-validate-job-service] vet"
"${GO_BIN}" vet ./...

echo "[local-validate-job-service] build"
"${GO_BIN}" build ./cmd/job-service
