#!/usr/bin/env bash
# TASK-C2C-POINTS-MARKET-CLOSED-LOOP-001
set -euo pipefail
BACKEND_ROOT="${BACKEND_ROOT:-../livemask-backend}"
JOB_ROOT="${JOB_ROOT:-../livemask-job-service}"
cd "$BACKEND_ROOT"
echo "[c2c-smoke] backend commerce tests"
go test ./internal/commerce/... -count=1 -timeout 3m
cd "$JOB_ROOT"
echo "[c2c-smoke] job points_market definition drift"
go test ./internal/jobs/... -run 'TestDefinitionDrift' -count=1
echo "[c2c-smoke] PASS"
