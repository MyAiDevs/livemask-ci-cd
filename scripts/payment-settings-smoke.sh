#!/usr/bin/env bash
# TASK-INTK-CI-CD-REQU-ADD-PAYMENT-SETTINGS-20260605140435
# Payment Settings Smoke — USDT provider fields, secret redaction, i18n, and webhook tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVEMASK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ADMIN_DIR="${ADMIN_DIR:-${LIVEMASK_ROOT}/livemask-admin}"
BACKEND_DIR="${BACKEND_DIR:-${LIVEMASK_ROOT}/livemask-backend}"

echo "================================================"
echo " TASK-INTK-CI-CD-REQU-ADD-PAYMENT-SETTINGS-20260605140435"
echo " Payment Settings USDT Provider Schema Smoke"
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

page = read(admin / "src/app/admin/settings/payments/page.tsx")
types = read(admin / "src/types/settings.ts")
api = read(admin / "src/lib/settings-api.ts")
hooks = read(admin / "src/hooks/use-settings.ts")
backend_go = read(backend / "internal/paymentsettings/paymentsettings.go")
backend_test = read(backend / "internal/paymentsettings/paymentsettings_test.go")
openapi = read(backend / "docs/openapi.yaml")
en = json.loads(read(admin / "src/lib/i18n/locales/en-US.json"))
zh = json.loads(read(admin / "src/lib/i18n/locales/zh-CN.json"))

providers = {
    "nowpayments": ["mode", "merchant_id", "api_base_url", "callback_url", "settlement_wallet", "allowed_chains", "enabled_currencies", "min_amount", "max_amount", "order_expiry_minutes", "fee_display", "api_key", "api_secret", "webhook_secret"],
    "coingate": ["mode", "merchant_id", "api_base_url", "callback_url", "settlement_wallet", "allowed_chains", "enabled_currencies", "min_amount", "max_amount", "order_expiry_minutes", "fee_display", "api_key", "api_secret", "webhook_secret"],
    "coinpayments": ["mode", "merchant_id", "api_base_url", "callback_url", "settlement_wallet", "allowed_chains", "enabled_currencies", "min_amount", "max_amount", "order_expiry_minutes", "fee_display", "api_key", "api_secret", "webhook_secret"],
}

for provider, fields in providers.items():
    require(f"backend schema includes provider {provider}", f'"{provider}"' in backend_go and f'Provider: "{provider}"' in backend_go)
    require(f"admin provider label includes {provider}", provider in page)
    for field in fields:
        require(f"backend schema includes {provider}.{field}", f'Key: "{field}"' in backend_go)
        require(f"admin field map includes {field}", field in page)

require("admin page uses payment provider API hooks", "usePaymentProviders" in page and "usePaymentProvider" in hooks)
require("admin page is schema driven", "schema.fields.map" in page)
require("admin page is not a generic provider card only", "reserved-providers" not in page and "coming-soon" not in page)
require("admin sends provider-specific config", "config: formValues" in page)
require("admin sends write-only secrets", "secrets: Object.fromEntries" in page)
require("admin exposes verify action", "verifyPaymentProvider" in api and "verify(provider.provider)" in page)
require("admin exposes test-webhook action", "testWebhookPaymentProvider" in api and "testWebhook(provider.provider)" in page)
require("admin exposes enable/disable action", "togglePaymentProvider" in api and "toggle(provider.provider" in page)
require("admin renders masked secret hints", "secret_hints" in page and "secret-placeholder" in page)

require("types expose payment provider schema", "PaymentProviderFieldSchema" in types and "PaymentProviderSchema" in types)
require("types separate write-only secrets", "secrets?: Record<string, string>" in types)

require("backend redacts raw payment secrets", "func redactConfig" in backend_go and "schemaHasSecret" in backend_go)
require("backend exposes secret_hints not raw secrets", "SecretHints" in backend_go and "secret_hints" in backend_go)
require("backend rejects generic payment card payload", "TestRejectsGenericPaymentCardWithoutUSDTFields" in backend_test)
require("backend proves raw secret is not leaked", "raw-api-key" in backend_test and "raw-webhook-secret" in backend_test and "secret leaked" in backend_test)
require("backend implements verify endpoint", 'action == "verify"' in backend_go)
require("backend implements test-webhook endpoint", 'action == "test-webhook"' in backend_go)
require("backend implements enable/disable endpoints", 'action == "enable"' in backend_go and 'action == "disable"' in backend_go)
require("backend enforces payment RBAC", "payment:read required" in backend_go and "payment:write required" in backend_go)
require("backend records audit events", "AuditEvent" in backend_go and "AuditLogged" in backend_go)

require("OpenAPI documents payment provider list", "/admin/api/v1/payment-settings/providers:" in openapi)
require("OpenAPI documents payment test-webhook", "/admin/api/v1/payment-settings/providers/{provider}/test-webhook:" in openapi)
require("OpenAPI documents write-only payment secrets", "Write-only payment secret fields" in openapi)
require("OpenAPI enumerates USDT providers", "enum: [nowpayments, coingate, coinpayments]" in openapi)

for locale_name, locale in [("en-US", en), ("zh-CN", zh)]:
    section = locale["settings"]["payments"]
    require(f"{locale_name} has USDT provider labels", all(p in section["providers"] for p in providers))
    require(f"{locale_name} has test-webhook label", bool(section.get("test-webhook")))
    require(f"{locale_name} has write-only label", bool(section.get("write-only")))
    for field in ["mode", "merchant-id", "api-base-url", "callback-url", "settlement-wallet", "allowed-chains", "enabled-currencies", "api-key", "api-secret", "webhook-secret"]:
        require(f"{locale_name} translates {field}", bool(section["fields"].get(field)))

raw_i18n_keys = re.findall(r'settings\.payments\.[A-Za-z0-9_.-]+', page)
missing_keys = []
for key in raw_i18n_keys:
    cur = en
    for part in key.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            missing_keys.append(key)
            break
require("no raw payment i18n keys are missing", not missing_keys)
if missing_keys:
    print("  Missing keys:", ", ".join(sorted(set(missing_keys))))

if failures:
    print("")
    print(f"Payment settings smoke FAILED: {len(failures)} failure(s)")
    sys.exit(1)

print("")
print("Payment settings smoke PASSED.")
PY
