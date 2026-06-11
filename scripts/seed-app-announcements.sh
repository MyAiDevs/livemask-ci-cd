#!/usr/bin/env bash
# Seed staging App announcements and activity cards through the Admin Content API.
# Idempotent by slug: existing rows are updated and published.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

API_BASE="${LIVEMASK_STAGING_BACKEND_URL:-$(lm_backend_base_url)}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@livemask.dev}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-AdminPass123!}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
END_ISO="$(date -u -d "+45 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v+45d +"%Y-%m-%dT%H:%M:%SZ")"

info() { echo "[seed-app-announcements] $*"; }
fail() { echo "[seed-app-announcements] ERROR: $*" >&2; exit 1; }

json_get() {
  python3 -c "import json,sys; data=json.load(sys.stdin); cur=data
for part in '${1}'.split('.'):
    if isinstance(cur, dict):
        cur=cur.get(part, '')
    else:
        cur=''
print(cur if cur is not None else '')" 2>/dev/null
}

request() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  local headers=(-H "Accept: application/json" -H "Content-Type: application/json")
  if [[ -n "${token}" ]]; then headers+=(-H "Authorization: Bearer ${token}"); fi
  if [[ -n "${body}" ]]; then
    curl -sS --max-time 20 -w $'\n%{http_code}' -X "${method}" "${API_BASE}${path}" "${headers[@]}" -d "${body}"
  else
    curl -sS --max-time 20 -w $'\n%{http_code}' -X "${method}" "${API_BASE}${path}" "${headers[@]}"
  fi
}

login_body=$(cat <<JSON
{"request_id":"seed-app-announcements","email":"${ADMIN_EMAIL}","password":"${ADMIN_PASSWORD}","client_type":"admin"}
JSON
)
login_raw="$(request POST "/admin/api/v1/auth/login" "${login_body}")"
login_http="$(echo "${login_raw}" | tail -1)"
login_resp="$(echo "${login_raw}" | sed '$d')"
[[ "${login_http}" == "200" ]] || fail "Admin login failed HTTP ${login_http}: ${login_resp}"
TOKEN="$(echo "${login_resp}" | json_get "access_token")"
[[ -n "${TOKEN}" ]] || fail "Admin login response missing access_token"
info "Admin authenticated"

find_content_id() {
  local slug="$1"
  local list_raw list_http list_resp
  list_raw="$(request GET "/admin/api/v1/content?q=${slug}" "" "${TOKEN}")"
  list_http="$(echo "${list_raw}" | tail -1)"
  list_resp="$(echo "${list_raw}" | sed '$d')"
  [[ "${list_http}" == "200" ]] || return 0
  echo "${list_resp}" | python3 -c "import json,sys
data=json.load(sys.stdin)
items=data.get('items') or data.get('data', {}).get('items') or data.get('data') or []
if isinstance(items, dict):
    items=items.get('items', [])
for item in items if isinstance(items, list) else []:
    if item.get('slug') == '${slug}':
        print(item.get('id',''))
        break" 2>/dev/null || true
}

upsert_content() {
  local slug="$1" locale="$2" content_type="$3" surface="$4" placement="$5" title="$6" excerpt="$7" markdown="$8" link_target="$9" cta="${10}"
  local body id raw http resp
  body=$(python3 -c "import json,sys
payload = {
  'slug': '${slug}',
  'locale': '${locale}',
  'content_type': '${content_type}',
  'surface': '${surface}',
  'placement': '${placement}',
  'title': '${title}',
  'excerpt': '${excerpt}',
  'content_markdown': '''${markdown}''',
  'tags': ['staging-seed', 'announcement'],
  'robots': 'index,follow',
  'status': 'published',
  'visibility': 'public',
  'starts_at': '${NOW_ISO}',
  'ends_at': '${END_ISO}',
  'link_type': 'app_route',
  'link_target': '${link_target}',
  'cta_label': '${cta}',
  'dismissible': True,
  'pinned': True,
  'featured': True,
  'sort_weight': 100,
  'priority': 100,
}
print(json.dumps(payload, ensure_ascii=False))")
  id="$(find_content_id "${slug}" | xargs)"
  if [[ -n "${id}" ]]; then
    raw="$(request PUT "/admin/api/v1/content/${id}" "${body}" "${TOKEN}")"
    http="$(echo "${raw}" | tail -1)"
    resp="$(echo "${raw}" | sed '$d')"
    [[ "${http}" == "200" ]] || fail "Update ${slug} failed HTTP ${http}: ${resp}"
    info "Updated ${slug} (${id})"
  else
    raw="$(request POST "/admin/api/v1/content" "${body}" "${TOKEN}")"
    http="$(echo "${raw}" | tail -1)"
    resp="$(echo "${raw}" | sed '$d')"
    [[ "${http}" == "200" || "${http}" == "201" ]] || fail "Create ${slug} failed HTTP ${http}: ${resp}"
    info "Created ${slug}"
  fi
}

upsert_content \
  "staging-app-announcement-zh" \
  "zh-CN" \
  "announcement" \
  "app" \
  "app_notice_center" \
  "LiveMask 活动测试：收益排行上线" \
  "这是一条通过 Admin API 发布的中文 App 公告，用于验证 App 通知中心拉取和展示。" \
  "## LiveMask 活动测试\n\n收益排行活动已上线。此公告用于验证 staging 环境 App 通知中心、内容拉取和跳转链路。" \
  "/notice-center" \
  "查看"

upsert_content \
  "staging-app-announcement-en" \
  "en-US" \
  "announcement" \
  "app" \
  "app_notice_center" \
  "LiveMask Activity Test: Rewards Ranking" \
  "An English App announcement published through the Admin API for staging validation." \
  "## LiveMask Activity Test\n\nRewards ranking is live. This announcement verifies the staging App notice center, content feed, and navigation path." \
  "/notice-center" \
  "Open"

upsert_content \
  "staging-rewards-leaderboard-zh" \
  "zh-CN" \
  "campaign" \
  "all" \
  "app_activity_card" \
  "收益排行活动进行中" \
  "收益排行活动已上线，Website 公告活动页和 App 活动卡片同步展示。" \
  "## 收益排行活动\n\n通过 staging seed 启用 Website 活动列表和 App 活动卡片显示，便于回归验证收益榜单展示链路。" \
  "/notice-center" \
  "查看活动"

upsert_content \
  "staging-rewards-leaderboard-en" \
  "en-US" \
  "campaign" \
  "all" \
  "app_activity_card" \
  "Rewards Leaderboard Is Live" \
  "The rewards leaderboard campaign is visible on Website announcements and App activity cards." \
  "## Rewards Leaderboard\n\nThis staging seed enables the Website announcement activity list and the App activity card for rewards leaderboard validation." \
  "/notice-center" \
  "View"

notice_http="$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/app?placement=app_notice_center&locale=zh-CN")"
[[ "${notice_http}" == "200" ]] || fail "App notice feed verification failed HTTP ${notice_http}"
activity_http="$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/app?placement=app_activity_card&locale=zh-CN")"
[[ "${activity_http}" == "200" ]] || fail "App activity feed verification failed HTTP ${activity_http}"
website_http="$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/website?locale=zh-CN")"
[[ "${website_http}" == "200" ]] || fail "Website content feed verification failed HTTP ${website_http}"

info "App and Website announcement/activity seed enabled and verified"
