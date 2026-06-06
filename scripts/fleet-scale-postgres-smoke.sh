#!/usr/bin/env bash
# TASK-JOBS-LARGE-FLEET-CONTROL-PLANE-001
# Postgres fleet scale smoke when JOB_SERVICE_DB_DSN is configured.
set -euo pipefail

ROOT="${1:-../livemask-job-service}"
if [[ ! -d "$ROOT" ]]; then
  echo "job-service repo not found at $ROOT" >&2
  exit 1
fi

cd "$ROOT"
echo "[fleet-postgres-smoke] memory dry-run paths"
go test ./internal/jobs -run 'TestFleetScale' -count=1 -timeout 5m

if [[ -z "${JOB_SERVICE_DB_DSN:-}" ]]; then
  echo "[fleet-postgres-smoke] SKIP postgres integration (JOB_SERVICE_DB_DSN unset)"
  exit 0
fi

echo "[fleet-postgres-smoke] postgres integration 10k snapshot + claim"
go test -tags=integration ./internal/jobs -run TestFleetScalePostgresSnapshotAndClaim -count=1 -timeout 10m
echo "[fleet-postgres-smoke] PASS"
