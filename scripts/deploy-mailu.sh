#!/usr/bin/env bash
set -euo pipefail

# Deploy the LiveMask Mailu stack and seed default mailboxes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAILU_DIR="${REPO_ROOT}/infra/mailu"
COMPOSE_FILE="${MAILU_COMPOSE_FILE:-${MAILU_DIR}/docker-compose.mailu.yml}"
ENV_FILE="${MAILU_ENV_FILE:-${MAILU_DIR}/mailu.env}"
EXAMPLE_ENV="${MAILU_DIR}/mailu.env.example"
RUNTIME_DIR="${MAILU_RUNTIME_DIR:-/opt/livemask-mailu}"
CREDENTIALS_FILE="${MAILU_CREDENTIALS_FILE:-${RUNTIME_DIR}/credentials.env}"
PROJECT_NAME="${MAILU_COMPOSE_PROJECT:-livemask-mailu}"

INIT_ENV=false
PULL=false
UP=false
SEED=false
SMOKE=false
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-mailu.sh [--init-env] [--pull] [--up] [--seed-users] [--smoke] [--all] [--dry-run]

Examples:
  bash scripts/deploy-mailu.sh --init-env
  bash scripts/deploy-mailu.sh --all
  MAILU_ENV_FILE=/etc/livemask/mailu.env bash scripts/deploy-mailu.sh --up --seed-users

This script does not store mailbox passwords in git. Default mailbox passwords
are generated/read from MAILU_CREDENTIALS_FILE, defaulting to:
  /opt/livemask-mailu/credentials.env
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init-env)
      INIT_ENV=true
      shift
      ;;
    --pull)
      PULL=true
      shift
      ;;
    --up)
      UP=true
      shift
      ;;
    --seed-users)
      SEED=true
      shift
      ;;
    --smoke)
      SMOKE=true
      shift
      ;;
    --all)
      INIT_ENV=true
      PULL=true
      UP=true
      SEED=true
      SMOKE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${INIT_ENV}${PULL}${UP}${SEED}${SMOKE}${DRY_RUN}" == "falsefalsefalsefalsefalsefalse" ]]; then
  usage
  exit 2
fi

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '\n'
  else
    LC_ALL=C tr -dc 'A-Za-z0-9_=-' </dev/urandom | head -c 48
  fi
}

init_env() {
  mkdir -p "$(dirname "${ENV_FILE}")" "${RUNTIME_DIR}"
  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${EXAMPLE_ENV}" "${ENV_FILE}"
    local secret
    secret="$(random_secret)"
    python3 - "$ENV_FILE" "$secret" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
secret = sys.argv[2]
text = path.read_text()
text = text.replace("SECRET_KEY=change-me-generate-with-deploy-mailu", f"SECRET_KEY={secret}")
path.write_text(text)
PY
    chmod 600 "${ENV_FILE}" || true
    echo "[mailu] initialized env: ${ENV_FILE}"
  else
    echo "[mailu] env already exists: ${ENV_FILE}"
  fi

  if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    umask 077
    cat >"${CREDENTIALS_FILE}" <<EOF
MAILU_ADMIN_PASSWORD=$(random_secret)
MAILU_SUPPORT_PASSWORD=$(random_secret)
MAILU_NO_REPLY_PASSWORD=$(random_secret)
EOF
    echo "[mailu] generated mailbox credentials: ${CREDENTIALS_FILE}"
  else
    echo "[mailu] mailbox credentials already exist: ${CREDENTIALS_FILE}"
  fi
}

load_envs() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[mailu] env file missing: ${ENV_FILE}" >&2
    echo "[mailu] run: bash scripts/deploy-mailu.sh --init-env" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CREDENTIALS_FILE}"
  fi
  export MAILU_ENV_FILE="${ENV_FILE}"
  export MAILU_COMPOSE_PROJECT="${MAILU_COMPOSE_PROJECT:-${PROJECT_NAME}}"
}

compose() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

render_config() {
  if [[ ! -f "${ENV_FILE}" && -f "${EXAMPLE_ENV}" ]]; then
    ENV_FILE="${EXAMPLE_ENV}"
  fi
  load_envs
  echo "[mailu] compose config: ${COMPOSE_FILE}"
  compose config >/tmp/livemask-mailu-compose-config.yml
  echo "[mailu] compose config rendered OK"
}

pull_images() {
  load_envs
  echo "[mailu] pulling Mailu images"
  compose pull
}

start_stack() {
  load_envs
  mkdir -p "${MAILU_DATA_DIR:-${RUNTIME_DIR}/data}" "${MAILU_CERTS_DIR:-${RUNTIME_DIR}/certs}"
  echo "[mailu] starting stack ${MAILU_COMPOSE_PROJECT:-${PROJECT_NAME}}"
  compose up -d --build
}

mailu_admin_exec() {
  compose exec -T admin "$@"
}

seed_mailboxes() {
  load_envs
  local domain="${DOMAIN:-livemask-vpn.com}"
  local admin_local="${MAILU_ADMIN_LOCALPART:-admin}"
  local support_local="${MAILU_SUPPORT_LOCALPART:-support}"
  local noreply_local="${MAILU_NO_REPLY_LOCALPART:-no-reply}"

  : "${MAILU_ADMIN_PASSWORD:?MAILU_ADMIN_PASSWORD missing; run --init-env}"
  : "${MAILU_SUPPORT_PASSWORD:?MAILU_SUPPORT_PASSWORD missing; run --init-env}"
  : "${MAILU_NO_REPLY_PASSWORD:?MAILU_NO_REPLY_PASSWORD missing; run --init-env}"

  echo "[mailu] seeding admin mailbox ${admin_local}@${domain}"
  mailu_admin_exec flask mailu admin "${admin_local}" "${domain}" "${MAILU_ADMIN_PASSWORD}" || \
    echo "[mailu] admin mailbox may already exist; continuing"

  echo "[mailu] seeding support mailbox ${support_local}@${domain}"
  mailu_admin_exec flask mailu user "${support_local}" "${domain}" "${MAILU_SUPPORT_PASSWORD}" || \
    echo "[mailu] support mailbox may already exist; continuing"

  echo "[mailu] seeding no-reply mailbox ${noreply_local}@${domain}"
  mailu_admin_exec flask mailu user "${noreply_local}" "${domain}" "${MAILU_NO_REPLY_PASSWORD}" || \
    echo "[mailu] no-reply mailbox may already exist; continuing"
}

run_smoke() {
  load_envs
  MAILU_ENV_FILE="${ENV_FILE}" MAILU_COMPOSE_FILE="${COMPOSE_FILE}" bash "${SCRIPT_DIR}/mailu-smoke.sh"
}

if [[ "${DRY_RUN}" == "true" ]]; then
  render_config
  exit 0
fi

if [[ "${INIT_ENV}" == "true" ]]; then
  init_env
fi
if [[ "${PULL}" == "true" ]]; then
  pull_images
fi
if [[ "${UP}" == "true" ]]; then
  start_stack
fi
if [[ "${SEED}" == "true" ]]; then
  seed_mailboxes
fi
if [[ "${SMOKE}" == "true" ]]; then
  run_smoke
fi

echo "[mailu] complete"
