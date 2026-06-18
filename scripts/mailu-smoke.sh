#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAILU_DIR="${REPO_ROOT}/infra/mailu"
COMPOSE_FILE="${MAILU_COMPOSE_FILE:-${MAILU_DIR}/docker-compose.mailu.yml}"
ENV_FILE="${MAILU_ENV_FILE:-${MAILU_DIR}/mailu.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[mailu-smoke] env file missing: ${ENV_FILE}" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

compose() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

echo "[mailu-smoke] compose config"
compose config >/tmp/livemask-mailu-smoke-compose.yml

echo "[mailu-smoke] service status"
compose ps

required_services=(front admin imap smtp antispam webmail redis)
for service in "${required_services[@]}"; do
  if ! compose ps --status running --services | grep -qx "${service}"; then
    echo "[mailu-smoke] service not running: ${service}" >&2
    exit 1
  fi
done

echo "[mailu-smoke] admin CLI"
compose exec -T admin flask mailu config >/tmp/livemask-mailu-smoke-config.txt

echo "[mailu-smoke] TCP probes"
for port in "${MAILU_SMTP_PORT:-25}" "${MAILU_SUBMISSION_PORT:-587}" "${MAILU_IMAPS_PORT:-993}"; do
  if ! timeout 3 bash -c ":</dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    echo "[mailu-smoke] port not reachable: ${port}" >&2
    exit 1
  fi
done

echo "[mailu-smoke] PASS"
