#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
POSTGRES_USER="${POSTGRES_USER:-livemask}"
POSTGRES_DB="${POSTGRES_DB:-livemask}"

if [[ "${COMPOSE_FILE}" != /* ]]; then
  COMPOSE_FILE="${REPO_ROOT}/${COMPOSE_FILE}"
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "[seed-dev-test-data] compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

cd "${REPO_ROOT}"

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" "$@"
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

seed_user() {
  local email="$1"
  local password="$2"
  local display_name="$3"
  shift 3
  local roles=("$@")
  local email_sql password_sql display_sql role values_sql

  email_sql="$(sql_escape "${email}")"
  password_sql="$(sql_escape "${password}")"
  display_sql="$(sql_escape "${display_name}")"

  values_sql=""
  for role in "${roles[@]}"; do
    role="$(sql_escape "${role}")"
    if [[ -n "${values_sql}" ]]; then
      values_sql+=","
    fi
    values_sql+="('${role}')"
  done

  pg_exec <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
WITH upserted AS (
  INSERT INTO users (email, password_hash, display_name, status, email_verified_at)
  VALUES ('${email_sql}', crypt('${password_sql}', gen_salt('bf', 12)), '${display_sql}', 'active', NOW())
  ON CONFLICT (email) DO UPDATE
    SET password_hash = EXCLUDED.password_hash,
        display_name = EXCLUDED.display_name,
        status = 'active',
        email_verified_at = COALESCE(users.email_verified_at, NOW()),
        updated_at = NOW()
  RETURNING id
),
role_values(role_key) AS (
  VALUES ${values_sql}
)
INSERT INTO user_roles (user_id, role_key, reason)
SELECT upserted.id, role_values.role_key, 'dev seed by seed-dev-test-data.sh'
FROM upserted, role_values
ON CONFLICT DO NOTHING;
SQL
}

echo "[seed-dev-test-data] seeding dev users"
seed_user "${DEV_ADMIN_EMAIL:-admin@livemask.dev}" "${DEV_ADMIN_PASSWORD:-AdminPass123!}" "Dev Admin" admin
seed_user "${DEV_SPONSOR_EMAIL:-sponsor@livemask.dev}" "${DEV_SPONSOR_PASSWORD:-SponsorPass123!}" "Dev Sponsor Ambassador" user sponsor_ambassador
seed_user "${DEV_AMBASSADOR_EMAIL:-ambassador@livemask.dev}" "${DEV_AMBASSADOR_PASSWORD:-AmbassadorPass123!}" "Dev Promotion Ambassador" user promotion_ambassador
seed_user "${DEV_SUBSCRIBER_EMAIL:-subscriber@livemask.dev}" "${DEV_SUBSCRIBER_PASSWORD:-SubscriberPass123!}" "Dev Subscriber" user subscriber
seed_user "${DEV_USER_EMAIL:-user@livemask.dev}" "${DEV_USER_PASSWORD:-UserPass123!}" "Dev User" user

dev_user_email_sql="$(sql_escape "${DEV_USER_EMAIL:-user@livemask.dev}")"
dev_subscriber_email_sql="$(sql_escape "${DEV_SUBSCRIBER_EMAIL:-subscriber@livemask.dev}")"
dev_sponsor_email_sql="$(sql_escape "${DEV_SPONSOR_EMAIL:-sponsor@livemask.dev}")"
dev_ambassador_email_sql="$(sql_escape "${DEV_AMBASSADOR_EMAIL:-ambassador@livemask.dev}")"

echo "[seed-dev-test-data] seeding dev traffic entitlements"
pg_exec <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO traffic_package_plans (
  id, plan_key, version, status, display_name, description, duration_key,
  duration_days, traffic_quota_bytes, bandwidth_limit_mbps, device_limit,
  points_price, points_return, usdt_price_amount, payment_methods,
  promo_discount_percent, tag_keys, sort_rank, is_recommended
)
VALUES (
  '11111111-1111-4111-8111-111111111111',
  'dev.local',
  1,
  'active',
  'Dev Local Traffic',
  'Local development traffic entitlement seeded by scripts/seed-dev-test-data.sh',
  'year',
  365,
  500::bigint * 1024 * 1024 * 1024,
  1000,
  10,
  0,
  0,
  0,
  '["points"]'::jsonb,
  0,
  '["dev"]'::jsonb,
  0,
  false
)
ON CONFLICT (id) DO UPDATE
SET status = 'active',
    traffic_quota_bytes = EXCLUDED.traffic_quota_bytes,
    bandwidth_limit_mbps = EXCLUDED.bandwidth_limit_mbps,
    device_limit = EXCLUDED.device_limit,
    updated_at = NOW();

WITH seed_users AS (
  SELECT id AS user_id
  FROM users
  WHERE email IN (
    '${dev_user_email_sql}',
    '${dev_subscriber_email_sql}',
    '${dev_sponsor_email_sql}',
    '${dev_ambassador_email_sql}'
  )
),
plan AS (
  SELECT * FROM traffic_package_plans WHERE id = '11111111-1111-4111-8111-111111111111'
),
created_orders AS (
  INSERT INTO traffic_package_orders (
    id, user_id, plan_id, plan_key, plan_version, payment_method,
    points_amount, points_return_amount, usdt_amount, traffic_quota_bytes,
    bandwidth_limit_mbps, duration_days, status, idempotency_key
  )
  SELECT
    gen_random_uuid(),
    seed_users.user_id,
    plan.id,
    plan.plan_key,
    plan.version,
    'points',
    0,
    0,
    0,
    plan.traffic_quota_bytes,
    plan.bandwidth_limit_mbps,
    plan.duration_days,
    'fulfilled',
    'dev-seed-traffic-entitlement-v1'
  FROM seed_users, plan
  ON CONFLICT (user_id, idempotency_key) DO NOTHING
  RETURNING id, user_id, plan_key, traffic_quota_bytes, bandwidth_limit_mbps, duration_days
)
INSERT INTO user_traffic_entitlements (
  id, user_id, order_id, plan_key, traffic_quota_bytes, bandwidth_limit_mbps,
  device_limit, status, starts_at, ends_at
)
SELECT
  gen_random_uuid(),
  created_orders.user_id,
  created_orders.id,
  created_orders.plan_key,
  created_orders.traffic_quota_bytes,
  created_orders.bandwidth_limit_mbps,
  10,
  'active',
  NOW(),
  NOW() + (created_orders.duration_days || ' days')::interval
FROM created_orders
WHERE NOT EXISTS (
  SELECT 1
  FROM user_traffic_entitlements e
  WHERE e.user_id = created_orders.user_id
    AND e.status = 'active'
);
SQL

echo "[seed-dev-test-data] complete"
