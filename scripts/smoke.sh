#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
HEALTH_URL="http://127.0.0.1:${BACKEND_HTTP_PORT}/api/v1/health"

echo "=== Smoke: Health API ==="
echo "Target: ${HEALTH_URL}"

# Wait for backend to be ready (up to 60s)
for attempt in $(seq 1 30); do
  response=$(curl -sS --max-time 3 "${HEALTH_URL}" 2>/dev/null || true)
  if [[ -n "$response" ]]; then
    echo "Backend responded on attempt ${attempt}"
    break
  fi
  echo "Waiting for backend... attempt ${attempt}/30"
  sleep 2
done

echo ""
echo "=== Health Response ==="
echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"

# Parse response fields
status=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "")
db=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['db_connected'])" 2>/dev/null || echo "")
redis=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['redis_connected'])" 2>/dev/null || echo "")

failed=0

if [[ "$status" != "ok" ]]; then
  echo "FAIL: status=\"${status}\", expected \"ok\""
  failed=1
fi

if [[ "$db" != "True" ]]; then
  echo "FAIL: db_connected=\"${db}\", expected True"
  failed=1
fi

if [[ "$redis" != "True" ]]; then
  echo "FAIL: redis_connected=\"${redis}\", expected True"
  failed=1
fi

if [[ "$failed" -eq 1 ]]; then
  echo ""
  echo "=== Diagnostic Info ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo ""
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo ""
  echo "--- docker compose logs postgres (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs postgres --tail=50 2>/dev/null || true
  echo ""
  echo "--- docker compose logs redis (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs redis --tail=50 2>/dev/null || true
  exit 1
fi

echo ""
echo "Smoke PASS: backend + postgres + redis all connected"
