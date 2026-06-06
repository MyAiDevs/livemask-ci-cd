#!/usr/bin/env bash
# TASK-JOBS-FLEET-CONTROL-PLANE-MVP-001
# Dry-run fleet scale smoke: 10k / 50k / 100k target snapshot expansion and claim recovery.
set -euo pipefail

ROOT="${1:-../livemask-job-service}"
if [[ ! -d "$ROOT" ]]; then
  echo "job-service repo not found at $ROOT" >&2
  exit 1
fi

cd "$ROOT"
echo "[fleet-smoke] go test fleet scale dry-run paths"
go test ./internal/jobs -run 'TestFleetScale' -count=1 -timeout 5m
echo "[fleet-smoke] PASS"
