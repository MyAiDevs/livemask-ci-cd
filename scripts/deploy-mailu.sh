#!/usr/bin/env bash
set -euo pipefail

# Deploy the LiveMask Mailu stack and seed default mailboxes.
# The script is intentionally repo-friendly and server-friendly:
# - run from a checked-out livemask-ci-cd repo; or
# - copy runtime assets into MAILU_RUNTIME_DIR and keep server-local env/secrets
#   outside git.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -n "${MAILU_SOURCE_DIR:-}" ]]; then
  SOURCE_MAILU_DIR="${MAILU_SOURCE_DIR}"
elif [[ -d "${SCRIPT_DIR}/infra/mailu" ]]; then
  SOURCE_MAILU_DIR="${SCRIPT_DIR}/infra/mailu"
else
  SOURCE_MAILU_DIR="${REPO_ROOT}/infra/mailu"
fi
MAILU_CICD_REF="${MAILU_CICD_REF:-dev}"
MAILU_ASSET_BASE_URL="${MAILU_ASSET_BASE_URL:-https://raw.githubusercontent.com/MyAiDevs/livemask-ci-cd/${MAILU_CICD_REF}}"

RUNTIME_DIR="${MAILU_RUNTIME_DIR:-/opt/livemask-mailu}"
ASSETS_DIR="${MAILU_ASSETS_DIR:-${RUNTIME_DIR}/assets}"
ENV_FILE="${MAILU_ENV_FILE:-${RUNTIME_DIR}/env/mailu.env}"
COMPOSE_FILE="${MAILU_COMPOSE_FILE:-${SOURCE_MAILU_DIR}/docker-compose.mailu.yml}"
EXAMPLE_ENV="${MAILU_EXAMPLE_ENV_FILE:-${SOURCE_MAILU_DIR}/mailu.env.example}"
CREDENTIALS_FILE="${MAILU_CREDENTIALS_FILE:-${RUNTIME_DIR}/credentials.env}"
SMOKE_SCRIPT="${MAILU_SMOKE_SCRIPT:-${SCRIPT_DIR}/mailu-smoke.sh}"
PROJECT_NAME="${MAILU_COMPOSE_PROJECT:-livemask-mailu}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
COMPOSE_BIN=()

INIT_ENV=false
INSTALL_ASSETS=false
PULL=false
UP=false
SEED=false
SMOKE=false
DRY_RUN=false
SKIP_PORT_CHECK=false

compose_file_explicit=false
env_file_explicit=false
example_env_explicit=false
credentials_file_explicit=false
assets_dir_explicit=false
smoke_script_explicit=false
source_dir_explicit=false
asset_base_url_explicit=false

domain_override=""
hostnames_override=""
website_override=""
tls_flavor_override=""
subnet_override=""
project_override=""
data_dir_override=""
certs_dir_override=""
http_port_override=""
https_port_override=""
smtp_port_override=""
submission_port_override=""
submissions_port_override=""
imap_port_override=""
imaps_port_override=""
pop3_port_override=""
pop3s_port_override=""
sieve_port_override=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-mailu.sh [actions] [options]

Actions:
  --install-assets       Copy compose/Dockerfile/env example/smoke into runtime assets dir.
  --init-env             Initialize server-local env and mailbox credentials.
  --pull                 Pull Mailu images.
  --up                   Start or update the Mailu stack.
  --seed-users           Create default admin/support/no-reply mailboxes.
  --smoke                Run Mailu smoke checks.
  --all                  Run install-assets, init-env, pull, up, seed-users, smoke.
  --dry-run              Render docker compose config only.

Portable options:
  --runtime-dir DIR      Runtime root. Default: /opt/livemask-mailu
  --assets-dir DIR       Runtime asset dir. Default: <runtime-dir>/assets
  --env-file FILE        Server-local Mailu env. Default: <runtime-dir>/env/mailu.env
  --compose-file FILE    Compose file. Default: repo infra/mailu/docker-compose.mailu.yml
  --source-dir DIR       Source Mailu asset dir. Default: repo infra/mailu.
  --asset-base-url URL   Remote raw asset base URL used when source-dir is absent.
                          Default: GitHub raw livemask-ci-cd/dev.
  --credentials-file FILE
                          Server-local mailbox credentials file.
                          Default: <runtime-dir>/credentials.env
  --project NAME         Docker Compose project. Default: livemask-mailu

Mail identity and runtime options:
  --domain DOMAIN        Mail domain, for example livemask-vpn.com.
  --hostnames HOSTS      Mailu HOSTNAMES value, comma-separated.
  --website URL          Website URL shown by Mailu.
  --tls-flavor VALUE     letsencrypt, cert, mail, or notls.
  --subnet CIDR          Docker network subnet.
  --data-dir DIR         Mailu data dir. Default for new env: <runtime-dir>/data
  --certs-dir DIR        Mailu cert dir. Default for new env: <runtime-dir>/certs

Port options:
  --http-port PORT       Host port for Mailu HTTP. Use 127.0.0.1:64010 behind nginx.
  --https-port PORT      Host port for Mailu HTTPS. Use 127.0.0.1:64011 behind nginx.
  --smtp-port PORT       Host port for SMTP 25.
  --submission-port PORT Host port for STARTTLS submission 587.
  --submissions-port PORT
                          Host port for SSL/TLS submission 465.
  --imap-port PORT       Host port for IMAP 143.
  --imaps-port PORT      Host port for IMAPS 993.
  --pop3-port PORT       Host port for POP3 110.
  --pop3s-port PORT      Host port for POP3S 995.
  --sieve-port PORT      Host port for Sieve 4190.
  --skip-port-check      Skip host port conflict checks before --up.

Examples:
  bash scripts/deploy-mailu.sh --init-env
  bash scripts/deploy-mailu.sh --all

  bash scripts/deploy-mailu.sh --all \
    --runtime-dir /opt/livemask-mailu \
    --domain livemask-vpn.com \
    --hostnames mailu.livemask-vpn.com,smtp.livemask-vpn.com,imap.livemask-vpn.com \
    --http-port 127.0.0.1:64010 \
    --https-port 127.0.0.1:64011

  MAILU_ENV_FILE=/etc/livemask/mailu.env bash scripts/deploy-mailu.sh --up --seed-users

This script does not store mailbox passwords in git. Default mailbox passwords
are generated/read from MAILU_CREDENTIALS_FILE, defaulting to:
  /opt/livemask-mailu/credentials.env
EOF
}

need_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "${value}" || "${value}" == --* ]]; then
    echo "[mailu] ${flag} requires a value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-assets)
      INSTALL_ASSETS=true
      shift
      ;;
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
      INSTALL_ASSETS=true
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
    --runtime-dir)
      need_value "$1" "${2:-}"
      RUNTIME_DIR="$2"
      shift 2
      ;;
    --assets-dir)
      need_value "$1" "${2:-}"
      ASSETS_DIR="$2"
      assets_dir_explicit=true
      shift 2
      ;;
    --env-file)
      need_value "$1" "${2:-}"
      ENV_FILE="$2"
      env_file_explicit=true
      shift 2
      ;;
    --compose-file)
      need_value "$1" "${2:-}"
      COMPOSE_FILE="$2"
      compose_file_explicit=true
      shift 2
      ;;
    --source-dir)
      need_value "$1" "${2:-}"
      SOURCE_MAILU_DIR="$2"
      source_dir_explicit=true
      shift 2
      ;;
    --asset-base-url)
      need_value "$1" "${2:-}"
      MAILU_ASSET_BASE_URL="$2"
      asset_base_url_explicit=true
      shift 2
      ;;
    --credentials-file)
      need_value "$1" "${2:-}"
      CREDENTIALS_FILE="$2"
      credentials_file_explicit=true
      shift 2
      ;;
    --project|--project-name)
      need_value "$1" "${2:-}"
      PROJECT_NAME="$2"
      project_override="$2"
      shift 2
      ;;
    --domain)
      need_value "$1" "${2:-}"
      domain_override="$2"
      shift 2
      ;;
    --hostnames)
      need_value "$1" "${2:-}"
      hostnames_override="$2"
      shift 2
      ;;
    --website)
      need_value "$1" "${2:-}"
      website_override="$2"
      shift 2
      ;;
    --tls-flavor)
      need_value "$1" "${2:-}"
      tls_flavor_override="$2"
      shift 2
      ;;
    --subnet)
      need_value "$1" "${2:-}"
      subnet_override="$2"
      shift 2
      ;;
    --data-dir)
      need_value "$1" "${2:-}"
      data_dir_override="$2"
      shift 2
      ;;
    --certs-dir)
      need_value "$1" "${2:-}"
      certs_dir_override="$2"
      shift 2
      ;;
    --http-port)
      need_value "$1" "${2:-}"
      http_port_override="$2"
      shift 2
      ;;
    --https-port)
      need_value "$1" "${2:-}"
      https_port_override="$2"
      shift 2
      ;;
    --smtp-port)
      need_value "$1" "${2:-}"
      smtp_port_override="$2"
      shift 2
      ;;
    --submission-port)
      need_value "$1" "${2:-}"
      submission_port_override="$2"
      shift 2
      ;;
    --submissions-port)
      need_value "$1" "${2:-}"
      submissions_port_override="$2"
      shift 2
      ;;
    --imap-port)
      need_value "$1" "${2:-}"
      imap_port_override="$2"
      shift 2
      ;;
    --imaps-port)
      need_value "$1" "${2:-}"
      imaps_port_override="$2"
      shift 2
      ;;
    --pop3-port)
      need_value "$1" "${2:-}"
      pop3_port_override="$2"
      shift 2
      ;;
    --pop3s-port)
      need_value "$1" "${2:-}"
      pop3s_port_override="$2"
      shift 2
      ;;
    --sieve-port)
      need_value "$1" "${2:-}"
      sieve_port_override="$2"
      shift 2
      ;;
    --skip-port-check)
      SKIP_PORT_CHECK=true
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

if [[ "${assets_dir_explicit}" == "false" ]]; then
  ASSETS_DIR="${MAILU_ASSETS_DIR:-${RUNTIME_DIR}/assets}"
fi
if [[ "${env_file_explicit}" == "false" ]]; then
  ENV_FILE="${MAILU_ENV_FILE:-${RUNTIME_DIR}/env/mailu.env}"
fi
if [[ "${credentials_file_explicit}" == "false" ]]; then
  CREDENTIALS_FILE="${MAILU_CREDENTIALS_FILE:-${RUNTIME_DIR}/credentials.env}"
fi
if [[ "${compose_file_explicit}" == "false" && ! -f "${COMPOSE_FILE}" && -f "${ASSETS_DIR}/docker-compose.mailu.yml" ]]; then
  COMPOSE_FILE="${ASSETS_DIR}/docker-compose.mailu.yml"
fi
if [[ "${example_env_explicit}" == "false" && ! -f "${EXAMPLE_ENV}" && -f "${ASSETS_DIR}/mailu.env.example" ]]; then
  EXAMPLE_ENV="${ASSETS_DIR}/mailu.env.example"
fi
if [[ "${smoke_script_explicit}" == "false" && ! -f "${SMOKE_SCRIPT}" && -f "${ASSETS_DIR}/mailu-smoke.sh" ]]; then
  SMOKE_SCRIPT="${ASSETS_DIR}/mailu-smoke.sh"
fi

if [[ "${INIT_ENV}${INSTALL_ASSETS}${PULL}${UP}${SEED}${SMOKE}${DRY_RUN}" == "falsefalsefalsefalsefalsefalsefalse" ]]; then
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

env_value() {
  local value="$1"
  if [[ "${value}" =~ ^[A-Za-z0-9_./:@,%+=-]+$ ]]; then
    printf '%s' "${value}"
  else
    printf "'%s'" "${value//\'/\'\\\'\'}"
  fi
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local rendered
  rendered="$(env_value "${value}")"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "${file}" ]] && grep -qE "^${key}=" "${file}"; then
    awk -v key="${key}" -v line="${key}=${rendered}" '
      BEGIN { done=0 }
      $0 ~ "^" key "=" { if (!done) { print line; done=1 }; next }
      { print }
      END { if (!done) print line }
    ' "${file}" >"${tmp}"
  else
    if [[ -f "${file}" ]]; then
      cat "${file}" >"${tmp}"
    fi
    printf '%s=%s\n' "${key}" "${rendered}" >>"${tmp}"
  fi
  mv "${tmp}" "${file}"
}

set_env_value_if_missing() {
  local file="$1"
  local key="$2"
  local value="$3"
  if [[ -f "${file}" ]] && grep -qE "^${key}=" "${file}"; then
    return 0
  fi
  set_env_value "${file}" "${key}" "${value}"
}

apply_cli_env_overrides() {
  local file="$1"
  local apply_defaults="${2:-false}"

  if [[ "${apply_defaults}" == "true" ]]; then
    set_env_value "${file}" "MAILU_DATA_DIR" "${data_dir_override:-${RUNTIME_DIR}/data}"
    set_env_value "${file}" "MAILU_CERTS_DIR" "${certs_dir_override:-${RUNTIME_DIR}/certs}"
    set_env_value "${file}" "MAILU_COMPOSE_PROJECT" "${project_override:-${PROJECT_NAME}}"
  fi

  [[ -n "${domain_override}" ]] && set_env_value "${file}" "DOMAIN" "${domain_override}"
  [[ -n "${hostnames_override}" ]] && set_env_value "${file}" "HOSTNAMES" "${hostnames_override}"
  [[ -n "${website_override}" ]] && set_env_value "${file}" "WEBSITE" "${website_override}"
  [[ -n "${tls_flavor_override}" ]] && set_env_value "${file}" "TLS_FLAVOR" "${tls_flavor_override}"
  [[ -n "${subnet_override}" ]] && set_env_value "${file}" "SUBNET" "${subnet_override}"
  [[ -n "${project_override}" ]] && set_env_value "${file}" "MAILU_COMPOSE_PROJECT" "${project_override}"
  [[ -n "${data_dir_override}" ]] && set_env_value "${file}" "MAILU_DATA_DIR" "${data_dir_override}"
  [[ -n "${certs_dir_override}" ]] && set_env_value "${file}" "MAILU_CERTS_DIR" "${certs_dir_override}"
  [[ -n "${http_port_override}" ]] && set_env_value "${file}" "MAILU_HTTP_PORT" "${http_port_override}"
  [[ -n "${https_port_override}" ]] && set_env_value "${file}" "MAILU_HTTPS_PORT" "${https_port_override}"
  [[ -n "${smtp_port_override}" ]] && set_env_value "${file}" "MAILU_SMTP_PORT" "${smtp_port_override}"
  [[ -n "${submission_port_override}" ]] && set_env_value "${file}" "MAILU_SUBMISSION_PORT" "${submission_port_override}"
  [[ -n "${submissions_port_override}" ]] && set_env_value "${file}" "MAILU_SUBMISSIONS_PORT" "${submissions_port_override}"
  [[ -n "${imap_port_override}" ]] && set_env_value "${file}" "MAILU_IMAP_PORT" "${imap_port_override}"
  [[ -n "${imaps_port_override}" ]] && set_env_value "${file}" "MAILU_IMAPS_PORT" "${imaps_port_override}"
  [[ -n "${pop3_port_override}" ]] && set_env_value "${file}" "MAILU_POP3_PORT" "${pop3_port_override}"
  [[ -n "${pop3s_port_override}" ]] && set_env_value "${file}" "MAILU_POP3S_PORT" "${pop3s_port_override}"
  [[ -n "${sieve_port_override}" ]] && set_env_value "${file}" "MAILU_SIEVE_PORT" "${sieve_port_override}"
  set_env_value_if_missing "${file}" "MESSAGE_SIZE_LIMIT" "50000000"
  set_env_value_if_missing "${file}" "PORTS" "25,80,443,465,587,143,993,110,995,4190"
  return 0
}

require_file() {
  local file="$1"
  local label="$2"
  if [[ ! -f "${file}" ]]; then
    echo "[mailu] ${label} missing: ${file}" >&2
    exit 2
  fi
}

download_asset() {
  local relative_path="$1"
  local target="$2"
  local url="${MAILU_ASSET_BASE_URL%/}/${relative_path}"

  mkdir -p "$(dirname "${target}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${target}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${target}" "${url}"
  else
    echo "[mailu] source assets missing and neither curl nor wget is available" >&2
    echo "[mailu] provide --source-dir or install curl/wget for remote bootstrap" >&2
    exit 2
  fi
}

source_assets_ready() {
  [[ -f "${SOURCE_MAILU_DIR}/docker-compose.mailu.yml" ]] &&
    [[ -f "${SOURCE_MAILU_DIR}/Dockerfile.mailu-admin" ]] &&
    [[ -f "${SOURCE_MAILU_DIR}/mailu.env.example" ]]
}

bootstrap_source_assets() {
  if source_assets_ready; then
    return 0
  fi

  if [[ "${source_dir_explicit}" == "true" || "${asset_base_url_explicit}" == "true" ]]; then
    echo "[mailu] source assets not found locally; bootstrapping from ${MAILU_ASSET_BASE_URL}" >&2
  else
    echo "[mailu] local repo assets not found at ${SOURCE_MAILU_DIR}; bootstrapping from ${MAILU_ASSET_BASE_URL}" >&2
  fi

  mkdir -p "${ASSETS_DIR}"
  download_asset "infra/mailu/docker-compose.mailu.yml" "${ASSETS_DIR}/docker-compose.mailu.yml"
  download_asset "infra/mailu/Dockerfile.mailu-admin" "${ASSETS_DIR}/Dockerfile.mailu-admin"
  download_asset "infra/mailu/mailu.env.example" "${ASSETS_DIR}/mailu.env.example"
  download_asset "scripts/mailu-smoke.sh" "${ASSETS_DIR}/mailu-smoke.sh"
  chmod 755 "${ASSETS_DIR}/mailu-smoke.sh" || true

  SOURCE_MAILU_DIR="${ASSETS_DIR}"
  if [[ "${compose_file_explicit}" == "false" ]]; then
    COMPOSE_FILE="${ASSETS_DIR}/docker-compose.mailu.yml"
  fi
  if [[ "${example_env_explicit}" == "false" ]]; then
    EXAMPLE_ENV="${ASSETS_DIR}/mailu.env.example"
  fi
  if [[ "${smoke_script_explicit}" == "false" ]]; then
    SMOKE_SCRIPT="${ASSETS_DIR}/mailu-smoke.sh"
  fi
  echo "[mailu] bootstrapped Mailu assets: ${ASSETS_DIR}"
}

ensure_docker_compose() {
  if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
    echo "[mailu] docker is required on the target server: ${DOCKER_BIN}" >&2
    exit 2
  fi

  if "${DOCKER_BIN}" compose version >/dev/null 2>&1; then
    COMPOSE_BIN=("${DOCKER_BIN}" compose)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE_BIN=(docker-compose)
    return 0
  fi

  if "${DOCKER_BIN}" info >/dev/null 2>&1; then
    echo "[mailu] docker compose plugin or docker-compose is required on the target server" >&2
  else
    echo "[mailu] docker exists but the daemon is not reachable; start Docker first" >&2
  fi
    exit 2
}

install_runtime_assets() {
  bootstrap_source_assets
  if [[ "$(cd "${SOURCE_MAILU_DIR}" && pwd -P)" == "$(mkdir -p "${ASSETS_DIR}" && cd "${ASSETS_DIR}" && pwd -P)" ]]; then
    chmod 755 "${ASSETS_DIR}/mailu-smoke.sh" || true
    echo "[mailu] installed runtime assets: ${ASSETS_DIR}"
    return 0
  fi
  require_file "${SOURCE_MAILU_DIR}/docker-compose.mailu.yml" "source compose file"
  require_file "${SOURCE_MAILU_DIR}/Dockerfile.mailu-admin" "source Mailu admin Dockerfile"
  require_file "${SOURCE_MAILU_DIR}/mailu.env.example" "source env example"
  if [[ ! -f "${SMOKE_SCRIPT}" && -f "${SCRIPT_DIR}/mailu-smoke.sh" ]]; then
    SMOKE_SCRIPT="${SCRIPT_DIR}/mailu-smoke.sh"
  elif [[ ! -f "${SMOKE_SCRIPT}" ]]; then
    download_asset "scripts/mailu-smoke.sh" "${ASSETS_DIR}/mailu-smoke.sh"
    SMOKE_SCRIPT="${ASSETS_DIR}/mailu-smoke.sh"
  fi
  require_file "${SMOKE_SCRIPT}" "source smoke script"

  mkdir -p "${ASSETS_DIR}" "${RUNTIME_DIR}/env"
  cp "${SOURCE_MAILU_DIR}/docker-compose.mailu.yml" "${ASSETS_DIR}/docker-compose.mailu.yml"
  cp "${SOURCE_MAILU_DIR}/Dockerfile.mailu-admin" "${ASSETS_DIR}/Dockerfile.mailu-admin"
  cp "${SOURCE_MAILU_DIR}/mailu.env.example" "${ASSETS_DIR}/mailu.env.example"
  if [[ "$(cd "$(dirname "${SMOKE_SCRIPT}")" && pwd -P)/$(basename "${SMOKE_SCRIPT}")" != "$(cd "${ASSETS_DIR}" && pwd -P)/mailu-smoke.sh" ]]; then
    cp "${SMOKE_SCRIPT}" "${ASSETS_DIR}/mailu-smoke.sh"
  fi
  chmod 755 "${ASSETS_DIR}/mailu-smoke.sh" || true

  if [[ "${compose_file_explicit}" == "false" ]]; then
    COMPOSE_FILE="${ASSETS_DIR}/docker-compose.mailu.yml"
  fi
  if [[ "${example_env_explicit}" == "false" ]]; then
    EXAMPLE_ENV="${ASSETS_DIR}/mailu.env.example"
  fi
  if [[ "${smoke_script_explicit}" == "false" ]]; then
    SMOKE_SCRIPT="${ASSETS_DIR}/mailu-smoke.sh"
  fi
  echo "[mailu] installed runtime assets: ${ASSETS_DIR}"
}

init_env() {
  if [[ ! -f "${EXAMPLE_ENV}" ]]; then
    bootstrap_source_assets
  fi
  require_file "${EXAMPLE_ENV}" "env example"
  mkdir -p "$(dirname "${ENV_FILE}")" "${RUNTIME_DIR}" "$(dirname "${CREDENTIALS_FILE}")"
  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${EXAMPLE_ENV}" "${ENV_FILE}"
    set_env_value "${ENV_FILE}" "SECRET_KEY" "$(random_secret)"
    apply_cli_env_overrides "${ENV_FILE}" true
    chmod 600 "${ENV_FILE}" || true
    echo "[mailu] initialized env: ${ENV_FILE}"
  else
    apply_cli_env_overrides "${ENV_FILE}" false
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
    echo "[mailu] run: bash scripts/deploy-mailu.sh --install-assets --init-env" >&2
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
  if [[ "${#COMPOSE_BIN[@]}" -eq 0 ]]; then
    ensure_docker_compose
  fi
  "${COMPOSE_BIN[@]}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

host_port_number() {
  local spec="$1"
  spec="${spec%/tcp}"
  spec="${spec#\[}"
  spec="${spec%\]}"
  if [[ "${spec}" == *:* ]]; then
    spec="${spec##*:}"
  fi
  printf '%s' "${spec}"
}

port_owned_by_project() {
  local port="$1"
  local project="${MAILU_COMPOSE_PROJECT:-${PROJECT_NAME}}"
  "${DOCKER_BIN}" ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | grep -F "${project}" | grep -q "front"
}

port_in_use() {
  local port="$1"
  [[ -z "${port}" || "${port}" == "0" ]] && return 1
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

check_ports() {
  [[ "${SKIP_PORT_CHECK}" == "true" ]] && return 0
  local specs=(
    "${MAILU_HTTP_PORT:-80}"
    "${MAILU_HTTPS_PORT:-443}"
    "${MAILU_SMTP_PORT:-25}"
    "${MAILU_SUBMISSION_PORT:-587}"
    "${MAILU_SUBMISSIONS_PORT:-465}"
    "${MAILU_IMAP_PORT:-143}"
    "${MAILU_IMAPS_PORT:-993}"
    "${MAILU_POP3_PORT:-110}"
    "${MAILU_POP3S_PORT:-995}"
    "${MAILU_SIEVE_PORT:-4190}"
  )
  local spec port
  local seen=" "
  for spec in "${specs[@]}"; do
    port="$(host_port_number "${spec}")"
    [[ -z "${port}" || "${port}" == "0" || "${seen}" == *" ${port} "* ]] && continue
    seen+="${port} "
    if port_owned_by_project "${port}"; then
      continue
    fi
    if port_in_use "${port}"; then
      echo "[mailu] host port ${spec} is already in use" >&2
      echo "[mailu] choose another --http-port/--https-port value, use nginx proxy, or pass --skip-port-check if this is expected" >&2
      exit 1
    fi
  done
}

render_config() {
  ensure_docker_compose
  if [[ ! -f "${ENV_FILE}" && -f "${EXAMPLE_ENV}" ]]; then
    ENV_FILE="${EXAMPLE_ENV}"
  elif [[ ! -f "${ENV_FILE}" && ! -f "${EXAMPLE_ENV}" ]]; then
    bootstrap_source_assets
    ENV_FILE="${EXAMPLE_ENV}"
  fi
  load_envs
  require_file "${COMPOSE_FILE}" "compose file"
  echo "[mailu] compose file: ${COMPOSE_FILE}"
  echo "[mailu] env file: ${ENV_FILE}"
  compose config >/tmp/livemask-mailu-compose-config.yml
  echo "[mailu] compose config rendered OK: /tmp/livemask-mailu-compose-config.yml"
}

pull_images() {
  ensure_docker_compose
  load_envs
  echo "[mailu] pulling Mailu images"
  compose pull
}

start_stack() {
  ensure_docker_compose
  load_envs
  require_file "${COMPOSE_FILE}" "compose file"
  mkdir -p "${MAILU_DATA_DIR:-${RUNTIME_DIR}/data}" "${MAILU_CERTS_DIR:-${RUNTIME_DIR}/certs}"
  check_ports
  echo "[mailu] starting stack ${MAILU_COMPOSE_PROJECT:-${PROJECT_NAME}}"
  compose up -d --build
}

mailu_admin_exec() {
  compose exec -T admin "$@"
}

seed_mailboxes() {
  ensure_docker_compose
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
  ensure_docker_compose
  load_envs
  require_file "${SMOKE_SCRIPT}" "smoke script"
  MAILU_ENV_FILE="${ENV_FILE}" MAILU_COMPOSE_FILE="${COMPOSE_FILE}" bash "${SMOKE_SCRIPT}"
}

if [[ "${INSTALL_ASSETS}" == "true" ]]; then
  install_runtime_assets
fi
if [[ "${INIT_ENV}" == "true" ]]; then
  init_env
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  render_config
  exit 0
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
