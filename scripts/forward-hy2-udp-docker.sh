#!/usr/bin/env bash
# DEPRECATED: HY2 UDP is published directly in docker-compose.local.yml.
# This script only stops a legacy host forwarder if it is still running.
#
# Usage:
#   bash scripts/forward-hy2-udp-docker.sh stop
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="${ROOT}/.state/hy2-udp-forward.pid"

if [[ "${1:-}" != "stop" ]]; then
  echo "HY2 TCP/UDP is published by Docker Compose (${SINGBOX_PUBLIC_ENDPOINT_PORT_START:-65001}-${SINGBOX_PUBLIC_ENDPOINT_PORT_END:-65535})." >&2
  echo "Recreate nodeagent instead:" >&2
  echo "  docker compose -f ${ROOT}/infra/docker-compose.local.yml --profile nodeagent up -d --force-recreate nodeagent" >&2
  exit 1
fi

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  kill "${pid}" 2>/dev/null || true
  rm -f "${PID_FILE}"
  echo "--- Stopped legacy UDP forwarder (pid ${pid}) ---"
else
  echo "--- No legacy UDP forwarder running ---"
fi
