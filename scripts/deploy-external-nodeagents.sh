#!/usr/bin/env bash
set -euo pipefail

# TASK-CICD-EXTERNAL-NODEAGENT-DEPLOY-001
# Deploy NodeAgent source to standalone sponsor/public NodeAgent hosts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_DIR="${SOURCE_DIR:-${REPO_ROOT}/infra/_build_deps/nodeagent}"
HOSTS="${EXTERNAL_NODEAGENT_HOSTS:-}"
SSH_OPTS="${EXTERNAL_NODEAGENT_SSH_OPTS:--o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15}"
REMOTE_DIR="${EXTERNAL_NODEAGENT_REMOTE_DIR:-/data/Livemask/livemask-nodeagent}"
CONTAINER="${EXTERNAL_NODEAGENT_CONTAINER:-livemask-prod-nodeagent}"
IMAGE="${EXTERNAL_NODEAGENT_IMAGE:-livemask-nodeagent:standalone-test}"
VOLUME="${EXTERNAL_NODEAGENT_VOLUME:-livemask-prod-nodeagent-auto-rule-name}"
PORT_ARGS="${EXTERNAL_NODEAGENT_PORT_ARGS:--p 65000:65000/tcp -p 65001:65001/udp}"
RUN_ARGS="${EXTERNAL_NODEAGENT_DOCKER_RUN_ARGS:-}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-external-nodeagents.sh [--source PATH] [--hosts "root@host ..."]

Environment:
  EXTERNAL_NODEAGENT_HOSTS             Space or comma separated SSH targets.
  EXTERNAL_NODEAGENT_REMOTE_DIR        Remote source checkout directory.
  EXTERNAL_NODEAGENT_CONTAINER         Remote container name.
  EXTERNAL_NODEAGENT_IMAGE             Remote Docker image tag.
  EXTERNAL_NODEAGENT_VOLUME            Remote Docker volume for /var/lib/livemask-nodeagent.
  EXTERNAL_NODEAGENT_PORT_ARGS         Docker run port args. Defaults to 65000/tcp and 65001/udp.
  EXTERNAL_NODEAGENT_DOCKER_RUN_ARGS   Extra docker run args.
  EXTERNAL_NODEAGENT_SSH_OPTS          Extra ssh options.

The script preserves the existing container environment when the target
container exists. If no container exists, it reads /etc/livemask/nodeagent.env
when present.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --hosts)
      HOSTS="${2:-}"
      shift 2
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

if [[ -z "${HOSTS}" ]]; then
  echo "[external-nodeagent] no EXTERNAL_NODEAGENT_HOSTS configured; skip"
  exit 0
fi

if [[ ! -f "${SOURCE_DIR}/go.mod" || ! -f "${SOURCE_DIR}/Dockerfile.standalone" ]]; then
  echo "ERROR: NodeAgent source is incomplete: ${SOURCE_DIR}" >&2
  echo "Expected go.mod and Dockerfile.standalone." >&2
  exit 2
fi

normalize_hosts() {
  tr ',\n\t' '   ' <<<"$1" | xargs -n1
}

deploy_host() {
  local host="$1"
  echo "[external-nodeagent] deploying ${host}"
  tar \
    --exclude='.git' \
    --exclude='.cache' \
    --exclude='.gomodcache' \
    --exclude='tmp' \
    --exclude='dist' \
    --exclude='build' \
    -C "${SOURCE_DIR}" -cf - . | \
    ssh ${SSH_OPTS} "${host}" "mkdir -p '${REMOTE_DIR}' && find '${REMOTE_DIR}' -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -C '${REMOTE_DIR}' -xf -"

  ssh ${SSH_OPTS} "${host}" \
    "REMOTE_DIR='${REMOTE_DIR}' CONTAINER='${CONTAINER}' IMAGE='${IMAGE}' VOLUME='${VOLUME}' PORT_ARGS='${PORT_ARGS}' RUN_ARGS='${RUN_ARGS}' sh -s" <<'REMOTE'
set -eu
cd "${REMOTE_DIR}"

docker build -f Dockerfile.standalone -t "${IMAGE}" .

env_file="$(mktemp /tmp/livemask-nodeagent-env.XXXXXX)"
cleanup() {
  rm -f "${env_file}"
}
trap cleanup EXIT

if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  docker inspect "${CONTAINER}" --format '{{range .Config.Env}}{{println .}}{{end}}' > "${env_file}"
elif [ -f /etc/livemask/nodeagent.env ]; then
  cp /etc/livemask/nodeagent.env "${env_file}"
else
  : > "${env_file}"
fi

docker stop "${CONTAINER}" >/dev/null 2>&1 || true
docker rm "${CONTAINER}" >/dev/null 2>&1 || true

# shellcheck disable=SC2086
docker run -d \
  --name "${CONTAINER}" \
  --restart unless-stopped \
  --env-file "${env_file}" \
  ${PORT_ARGS} \
  -v "${VOLUME}:/var/lib/livemask-nodeagent:z" \
  ${RUN_ARGS} \
  "${IMAGE}"

probe_ok=0
for i in $(seq 1 45); do
  if wget -qO- "http://127.0.0.1:65000/app/probe" >/tmp/livemask-nodeagent-probe.json 2>/dev/null; then
    cat /tmp/livemask-nodeagent-probe.json
    probe_ok=1
    break
  fi
  sleep 2
done

if [ "${probe_ok}" != "1" ]; then
  docker logs --tail 120 "${CONTAINER}" >&2 || true
  exit 1
fi

geoip_enabled="$(awk -F= '
  $1 == "NODEAGENT_GEOIP_ENABLED" { value=$2 }
  $1 == "GEOIP_ENABLED" && value == "" { value=$2 }
  END { print value }
' "${env_file}" | tr '[:upper:]' '[:lower:]')"

if [ "${geoip_enabled}" = "true" ]; then
  control_token="$(awk -F= '$1 == "NODEAGENT_CONTROL_TOKEN" { print $2; exit }' "${env_file}")"
  if [ -z "${control_token}" ]; then
    echo "[external-nodeagent] GeoIP is enabled but NODEAGENT_CONTROL_TOKEN is missing; cannot verify /geoip/status" >&2
    docker logs --tail 120 "${CONTAINER}" >&2 || true
    exit 1
  fi

  geoip_ok=0
  for i in $(seq 1 60); do
    if wget -qO- --header "Authorization: Bearer ${control_token}" \
      "http://127.0.0.1:65000/geoip/status" >/tmp/livemask-nodeagent-geoip.json 2>/dev/null; then
      cat /tmp/livemask-nodeagent-geoip.json
      if grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"' /tmp/livemask-nodeagent-geoip.json ||
        grep -Eq '"lkg_available"[[:space:]]*:[[:space:]]*true' /tmp/livemask-nodeagent-geoip.json; then
        geoip_ok=1
        break
      fi
    fi
    sleep 2
  done

  if [ "${geoip_ok}" != "1" ]; then
    echo "[external-nodeagent] GeoIP status did not become ready and no LKG is available" >&2
    docker logs --tail 160 "${CONTAINER}" >&2 || true
    exit 1
  fi
fi

exit 0
REMOTE
}

while IFS= read -r host; do
  [[ -z "${host}" ]] && continue
  deploy_host "${host}"
done < <(normalize_hosts "${HOSTS}")

echo "[external-nodeagent] complete"
