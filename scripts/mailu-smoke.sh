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

probe_tcp() {
  local host="$1"
  local port="$2"
  timeout 5 bash -c ":</dev/tcp/${host}/${port}" 2>/dev/null
}

relay_host_part() {
  local relay="${RELAYHOST:-}"
  relay="${relay#\[}"
  relay="${relay%\]}"
  relay="${relay%]:*}"
  relay="${relay%%:*}"
  printf '%s' "${relay}"
}

relay_port_part() {
  local relay="${RELAYHOST:-}"
  if [[ "${relay}" =~ :([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '25'
  fi
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
compose exec -T admin flask mailu config-export --help >/tmp/livemask-mailu-smoke-config.txt

echo "[mailu-smoke] TCP probes"
for port in "${MAILU_SMTP_PORT:-25}" "${MAILU_SUBMISSION_PORT:-587}" "${MAILU_IMAPS_PORT:-993}"; do
  if ! probe_tcp 127.0.0.1 "${port}"; then
    echo "[mailu-smoke] port not reachable: ${port}" >&2
    exit 1
  fi
done

echo "[mailu-smoke] outbound delivery mode"
if [[ -n "${RELAYHOST:-}" ]]; then
  relay_host="$(relay_host_part)"
  relay_port="$(relay_port_part)"
  echo "[mailu-smoke] relayhost configured: ${RELAYHOST}"
  if [[ -z "${RELAYUSER:-}" || -z "${RELAYPASSWORD:-}" ]]; then
    echo "[mailu-smoke] RELAYHOST is set but RELAYUSER/RELAYPASSWORD is incomplete" >&2
    exit 1
  fi
  if [[ -z "${relay_host}" ]] || ! probe_tcp "${relay_host}" "${relay_port}"; then
    echo "[mailu-smoke] relayhost not reachable: ${RELAYHOST}" >&2
    exit 1
  fi
else
  direct_mx_host="${MAILU_SMOKE_DIRECT_MX_HOST:-gmail-smtp-in.l.google.com}"
  if probe_tcp "${direct_mx_host}" 25; then
    echo "[mailu-smoke] direct MX delivery probe OK: ${direct_mx_host}:25"
  else
    echo "[mailu-smoke] warning: direct MX delivery probe failed: ${direct_mx_host}:25" >&2
    echo "[mailu-smoke] warning: configure RELAYHOST/RELAYUSER/RELAYPASSWORD or unblock outbound TCP 25" >&2
    if [[ "${MAILU_REQUIRE_OUTBOUND_DELIVERY:-false}" == "true" ]]; then
      exit 1
    fi
  fi
fi

echo "[mailu-smoke] PASS"
