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

seed_auth_roles() {
  pg_exec <<'SQL'
INSERT INTO roles (role_key, description)
VALUES
  ('user', 'Normal end user'),
  ('subscriber', 'User with active subscription entitlement'),
  ('sponsor_ambassador', 'Sponsor node / sponsor revenue self-service'),
  ('promotion_ambassador', 'Referral and promotion revenue self-service'),
  ('support_agent', 'User support and ticket handling'),
  ('ops_operator', 'Node/config/operations management'),
  ('finance_operator', 'Payments, invoices, settlement review'),
  ('auditor', 'Read-only audit access'),
  ('admin', 'Full system administration'),
  ('super_admin', 'Break-glass owner; can manage roles')
ON CONFLICT (role_key) DO UPDATE
SET description = EXCLUDED.description;
SQL
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

seed_nodeagent_release() {
  local version="$1"
  local version_sql

  version_sql="$(sql_escape "${version}")"
  if [[ -z "${version_sql}" ]]; then
    return 0
  fi

  pg_exec <<SQL
INSERT INTO nodeagent_releases (
  version, platform, arch, channel, artifact_url, sha256,
  min_config_schema, max_config_schema, status, release_notes, created_by,
  published_at
)
VALUES (
  '${version_sql}',
  'linux',
  'amd64',
  'dev',
  'https://dev.livemask-vpn.com/nodeagent/${version_sql}/nodeagent-linux-amd64.tar.gz',
  '0000000000000000000000000000000000000000000000000000000000000000',
  '1.0',
  '9.9',
  'published',
  'DEV compatibility seed for protocol assignment version checks.',
  'seed-dev-test-data.sh',
  NOW()
)
ON CONFLICT (version, platform, arch) DO UPDATE
SET channel = 'dev',
    artifact_url = EXCLUDED.artifact_url,
    sha256 = EXCLUDED.sha256,
    min_config_schema = EXCLUDED.min_config_schema,
    max_config_schema = EXCLUDED.max_config_schema,
    status = 'published',
    release_notes = EXCLUDED.release_notes,
    created_by = EXCLUDED.created_by,
    published_at = COALESCE(nodeagent_releases.published_at, NOW()),
    revoked_at = NULL;
SQL
}

echo "[seed-dev-test-data] seeding auth role catalog"
seed_auth_roles

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

echo "[seed-dev-test-data] seeding dev billing plans and subscriptions"
pg_exec <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO billing_plans (
  plan_id, name, price_cents, currency, billing_period, device_limit, node_access, features
)
VALUES (
  'free', 'Free', 0, 'USD', 'monthly', 1, 'basic', '["1 device","Basic nodes"]'::jsonb
),
(
  'premium_monthly', 'Premium', 999, 'USD', 'monthly', 5, 'all', '["5 devices","All nodes","Priority speed"]'::jsonb
),
(
  'enterprise_monthly', 'Enterprise', 2999, 'USD', 'monthly', 20, 'all', '["20 devices","All nodes","Priority speed","Dedicated support"]'::jsonb
)
ON CONFLICT (plan_id) DO UPDATE
SET name = EXCLUDED.name,
    price_cents = EXCLUDED.price_cents,
    currency = EXCLUDED.currency,
    billing_period = EXCLUDED.billing_period,
    device_limit = EXCLUDED.device_limit,
    node_access = EXCLUDED.node_access,
    features = EXCLUDED.features;

WITH seed_users AS (
  SELECT
    id AS user_id,
    email,
    CASE
      WHEN email = '${dev_subscriber_email_sql}' THEN 'premium_monthly'
      WHEN email = '${dev_sponsor_email_sql}' THEN 'enterprise_monthly'
      WHEN email = '${dev_ambassador_email_sql}' THEN 'premium_monthly'
      ELSE 'free'
    END AS plan_id
  FROM users
  WHERE email IN (
    '${dev_user_email_sql}',
    '${dev_subscriber_email_sql}',
    '${dev_sponsor_email_sql}',
    '${dev_ambassador_email_sql}'
  )
)
INSERT INTO user_subscriptions (
  user_id, plan_id, status, current_period_start, current_period_end, cancel_at_period_end
)
SELECT
  seed_users.user_id,
  seed_users.plan_id,
  'active',
  NOW(),
  NOW() + INTERVAL '30 days',
  FALSE
FROM seed_users
ON CONFLICT (user_id) DO UPDATE
SET plan_id = EXCLUDED.plan_id,
    status = 'active',
    current_period_start = EXCLUDED.current_period_start,
    current_period_end = EXCLUDED.current_period_end,
    cancel_at_period_end = FALSE,
    updated_at = NOW();
SQL

echo "[seed-dev-test-data] seeding dev NodeAgent release compatibility labels"
dev_nodeagent_versions="${DEV_NODEAGENT_RELEASE_VERSIONS:-dev dev-prod-docker}"
for dev_nodeagent_version in ${dev_nodeagent_versions}; do
  seed_nodeagent_release "${dev_nodeagent_version}"
done

echo "[seed-dev-test-data] complete"
