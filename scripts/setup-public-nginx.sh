#!/usr/bin/env bash
# Install nginx + certbot and proxy public domains to LiveMask dev runtime ports.
#
# Run ONLY on the self-hosted staging runner host (see .github/workflows/public-nginx-bootstrap.yml).
# Do not run from a developer laptop with scp — runtime deploy is owned by dev-runtime-deploy.yml.
set -euo pipefail

PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-livemask-vpn.com}"
MIRROR_DOMAINS="${MIRROR_DOMAINS:-vpn-mirrors.xyz,vpn-mirrors.cfd}"
WEBSITE_PORT="${WEBSITE_PORT:-64000}"
ADMIN_PORT="${ADMIN_PORT:-64001}"
JOB_PORT="${JOB_PORT:-64002}"
BACKEND_PORT="${BACKEND_PORT:-64003}"
EMAIL="${CERTBOT_EMAIL:-admin@${PRIMARY_DOMAIN}}"

info() { echo "[setup-public-nginx] $*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root on the server" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
if ! command -v nginx >/dev/null; then
  apt-get update
  apt-get install -y nginx certbot python3-certbot-nginx
fi

write_site() {
  local name="$1"
  local server_names="$2"
  local upstream_port="$3"
  cat >"/etc/nginx/sites-available/${name}" <<EOF
server {
    listen 80;
    server_name ${server_names};

    location / {
        proxy_pass http://127.0.0.1:${upstream_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
  ln -sf "/etc/nginx/sites-available/${name}" "/etc/nginx/sites-enabled/${name}"
}

API_NAMES="api.${PRIMARY_DOMAIN}"
WWW_NAMES="www.${PRIMARY_DOMAIN} ${PRIMARY_DOMAIN}"
IFS=',' read -r -a _mirrors <<< "${MIRROR_DOMAINS}"
for _m in "${_mirrors[@]}"; do
  API_NAMES+=" api.${_m}"
  WWW_NAMES+=" www.${_m} ${_m}"
done

write_site livemask-api "${API_NAMES}" "${BACKEND_PORT}"
write_site livemask-www "${WWW_NAMES}" "${WEBSITE_PORT}"
write_site livemask-admin "admin.${PRIMARY_DOMAIN}" "${ADMIN_PORT}"
write_site livemask-job "job.${PRIMARY_DOMAIN}" "${JOB_PORT}"

nginx -t
systemctl enable nginx
systemctl reload nginx

CERT_DOMAINS=(
  -d "api.${PRIMARY_DOMAIN}"
  -d "${PRIMARY_DOMAIN}"
  -d "www.${PRIMARY_DOMAIN}"
  -d "admin.${PRIMARY_DOMAIN}"
  -d "job.${PRIMARY_DOMAIN}"
)
IFS=',' read -r -a mirrors <<< "${MIRROR_DOMAINS}"
for m in "${mirrors[@]}"; do
  CERT_DOMAINS+=(-d "api.${m}" -d "${m}" -d "www.${m}")
done

certbot --nginx "${CERT_DOMAINS[@]}" --non-interactive --agree-tos -m "${EMAIL}" --redirect || true

info "nginx ready — verify: curl -fsS https://api.${PRIMARY_DOMAIN}/api/v1/health"
