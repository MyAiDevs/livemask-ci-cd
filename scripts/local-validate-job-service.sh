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

echo "[local-validate-job-service] repo=${repo}"
cd -- "${repo}"

echo "[local-validate-job-service] unit tests"
go test ./... -count=1

echo "[local-validate-job-service] sqlstore integration tests"
go test -tags sqlstore ./... -count=1

echo "[local-validate-job-service] vet"
go vet ./...

echo "[local-validate-job-service] build"
go build ./cmd/job-service
