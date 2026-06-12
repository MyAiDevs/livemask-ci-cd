#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(pwd -P)}"
repo="$(cd -- "${repo}" && pwd -P)"

export GOCACHE="${GOCACHE:-/tmp/go-build}"
export GOMODCACHE="${GOMODCACHE:-/tmp/go-mod}"

cleanup() {
  docker stop "${pg_container:-}" "${redis_container:-}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 2
  }
}

wait_for_postgres() {
  local deadline=$((SECONDS + 45))
  until docker exec "${pg_container}" pg_isready -U postgres >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "postgres did not become ready in time" >&2
      docker logs "${pg_container}" >&2 || true
      exit 1
    fi
    sleep 1
  done
}

need_cmd docker
if command -v go >/dev/null 2>&1; then
  GO_BIN="go"
elif [[ -x "/usr/local/go/bin/go" ]]; then
  GO_BIN="/usr/local/go/bin/go"
else
  echo "missing required command: go" >&2
  exit 2
fi

echo "[local-validate-backend] repo=${repo}"
cd -- "${repo}"

echo "[local-validate-backend] unit tests"
"${GO_BIN}" test ./... -count=1

echo "[local-validate-backend] vet"
"${GO_BIN}" vet ./...

echo "[local-validate-backend] build"
"${GO_BIN}" build ./...

suffix="$$-$(date +%s)"
pg_container="livemask-backend-guard-postgres-${suffix}"
redis_container="livemask-backend-guard-redis-${suffix}"

echo "[local-validate-backend] start postgres/redis for integration"
docker run --rm -d \
  --name "${pg_container}" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -p 127.0.0.1::5432 \
  postgres:16-alpine >/dev/null

docker run --rm -d \
  --name "${redis_container}" \
  -p 127.0.0.1::6379 \
  redis:7-alpine >/dev/null

wait_for_postgres

pg_port="$(docker port "${pg_container}" 5432/tcp | sed -E 's/.*:([0-9]+)$/\1/')"
redis_port="$(docker port "${redis_container}" 6379/tcp | sed -E 's/.*:([0-9]+)$/\1/')"

echo "[local-validate-backend] integration tests"
DB_DSN="postgres://postgres:postgres@127.0.0.1:${pg_port}/postgres?sslmode=disable" \
REDIS_ADDR="127.0.0.1:${redis_port}" \
"${GO_BIN}" test -tags=integration ./... -count=1
