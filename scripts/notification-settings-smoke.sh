#!/usr/bin/env bash
# TASK-INTK-CI-CD-REQU-ADD-NOTIFICATION-SETTINGS-20260605140104
# Notification Settings Smoke — provider schema, redaction, i18n, and test-send.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVEMASK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ADMIN_DIR="${ADMIN_DIR:-${LIVEMASK_ROOT}/livemask-admin}"
BACKEND_DIR="${BACKEND_DIR:-${LIVEMASK_ROOT}/livemask-backend}"

echo "================================================"
echo " TASK-INTK-CI-CD-REQU-ADD-NOTIFICATION-SETTINGS-20260605140104"
echo " Notification Settings Provider Schema Smoke"
echo "================================================"

python3 - "${ADMIN_DIR}" "${BACKEND_DIR}" <<'PY'
import json
import pathlib
import re
import sys

admin = pathlib.Path(sys.argv[1])
backend = pathlib.Path(sys.argv[2])
failures = []

def read(path):
    return path.read_text(encoding="utf-8")

def require(label, condition):
    if condition:
        print(f"  PASS: {label}")
    else:
        print(f"  FAIL: {label}")
        failures.append(label)

page = read(admin / "src/app/admin/settings/notifications/page.tsx")
types = read(admin / "src/types/settings.ts")
api = read(admin / "src/lib/settings-api.ts")
backend_go = read(backend / "internal/notificationsettings/notificationsettings.go")
backend_test = read(backend / "internal/notificationsettings/notificationsettings_test.go")
openapi = read(backend / "docs/openapi.yaml")
en = json.loads(read(admin / "src/lib/i18n/locales/en-US.json"))
zh = json.loads(read(admin / "src/lib/i18n/locales/zh-CN.json"))

providers = {
    "smtp": ["host", "port", "tls_mode", "username", "password", "from_address", "reply_to", "timeout_seconds", "test_recipient"],
    "telegram": ["bot_token", "default_chat_id", "parse_mode", "webhook_url", "webhook_secret", "test_recipient"],
    "whatsapp": ["provider_type", "api_base_url", "account_id", "phone_number_id", "access_token", "webhook_url", "verify_token"],
    "lark": ["bot_webhook_url", "app_id", "app_secret", "signing_secret", "tenant_key"],
    "push": ["provider_type", "project_id", "server_key", "service_account_json", "private_key", "key_id", "team_id", "bundle_id", "vapid_public_key", "vapid_private_key", "callback_url"],
}

for provider, fields in providers.items():
    require(f"backend schema includes provider {provider}", f'"{provider}"' in backend_go and f'Provider: "{provider}"' in backend_go)
    for field in fields:
        require(f"backend schema includes {provider}.{field}", f'Key: "{field}"' in backend_go)
        require(f"admin field map includes {field}", field in page)

require("admin form is schema driven", "editing?.schema?.fields.map" in page)
require("admin no longer relies on single botToken state", "setBotToken" not in page and "const [botToken" not in page)
require("admin sends provider-specific config object", "config: formValues" in page)
require("admin sends write-only secrets object", "secrets: Object.fromEntries" in page)
require("admin exposes test-send action", "handleTestSend" in page and "testSendNotificationProvider" in api)
require("admin shows masked secret hints", "secret_hints" in page and "secret-placeholder" in page)

require("types expose provider schema", "NotificationProviderFieldSchema" in types and "NotificationProviderSchema" in types)
require("types model secrets separately from config", "secrets?: Record<string, string>" in types)

require("backend redacts raw secret config keys", "func redactConfig" in backend_go and "schemaHasSecret" in backend_go)
require("backend exposes secret_hints not raw secrets", "SecretHints" in backend_go and "secret_hints" in backend_go)
require("backend rejects generic bot_token-only SMTP config", "TestUpdateProviderRejectsGenericBotTokenOnly" in backend_test)
require("backend test proves raw secret not leaked", "super-secret-password" in backend_test and "secret leaked" in backend_test)
require("backend implements verify endpoint", 'action == "verify"' in backend_go)
require("backend implements test-send endpoint", 'action == "test-send"' in backend_go)
require("backend implements enable/disable endpoints", 'action == "enable"' in backend_go and 'action == "disable"' in backend_go)
require("backend enforces notification RBAC", "notifications:read required" in backend_go and "notifications:write required" in backend_go)
require("backend records audit events", "AuditEvent" in backend_go and "AuditLogged" in backend_go)

require("OpenAPI documents test-send", "/admin/api/v1/notification-settings/providers/{provider}/test-send" in openapi)
require("OpenAPI documents write-only secrets", "Write-only secret fields" in openapi or "write-only secrets" in openapi)
require("OpenAPI enumerates all providers", "enum: [smtp, telegram, whatsapp, lark, push]" in openapi)

for locale_name, locale in [("en-US", en), ("zh-CN", zh)]:
    section = locale["settings"]["notifications"]
    require(f"{locale_name} has provider labels", all(p in section["providers"] for p in providers))
    require(f"{locale_name} has test-send label", bool(section.get("test-send")))
    require(f"{locale_name} has write-only label", bool(section.get("write-only")))
    for field in ["host", "port", "password", "bot-token", "webhook-url", "access-token", "app-secret", "private-key", "vapid-private-key"]:
        require(f"{locale_name} translates {field}", bool(section["fields"].get(field)))

raw_i18n_keys = re.findall(r'settings\.notifications\.[A-Za-z0-9_.-]+', page)
missing_keys = []
for key in raw_i18n_keys:
    cur = en
    for part in key.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            missing_keys.append(key)
            break
require("no raw notification i18n keys are missing", not missing_keys)
if missing_keys:
    print("  Missing keys:", ", ".join(sorted(set(missing_keys))))

if failures:
    print("")
    print(f"Notification settings smoke FAILED: {len(failures)} failure(s)")
    sys.exit(1)

print("")
print("Notification settings smoke PASSED.")
PY
