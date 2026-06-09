#!/usr/bin/env python3
"""
Seed site config privacy policy and terms of service via Admin API.
Reads seed text files from livemask-backend/internal/siteconfig/seed_*.txt,
merges into existing config, and publishes via Admin API.
"""
import json
import os
import sys
import urllib.error
import urllib.request


def info(msg):
    print(f"[seed-site-config] {msg}")


def post(api_base, path, body=None, token=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(f"{api_base}{path}", data=data, headers=headers,
                                 method="POST" if body else "GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"error": raw}
        return err.code, payload


def put(api_base, path, body, token):
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(f"{api_base}{path}", data=data, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"error": raw}
        return err.code, payload


def read_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def main():
    api_base = os.environ.get("LIVEMASK_STAGING_BACKEND_URL", "http://127.0.0.1:18080")
    admin_email = os.environ.get("ADMIN_EMAIL", "admin@livemask.dev")
    admin_password = os.environ.get("ADMIN_PASSWORD", "AdminPass123!")

    # Auto-detect seed text directory
    seed_txt_dir = os.environ.get("SEED_TXT_DIR", "")
    if not seed_txt_dir:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        repo_dir = os.path.dirname(script_dir)
        monorepo_dir = os.path.dirname(repo_dir)
        candidate = os.path.join(monorepo_dir, "livemask-backend", "internal", "siteconfig")
        if os.path.isdir(candidate):
            seed_txt_dir = candidate
        else:
            info("ERROR: Cannot find seed text files. Set SEED_TXT_DIR env var.")
            sys.exit(1)

    info(f"Backend: {api_base}")
    info(f"Seed text dir: {seed_txt_dir}")

    # ── 1. Verify seed files ────────────────────────────────────────
    required = {
        "privacy_zh": os.path.join(seed_txt_dir, "seed_privacy_zh.txt"),
        "privacy_en": os.path.join(seed_txt_dir, "seed_privacy_en.txt"),
        "terms_zh": os.path.join(seed_txt_dir, "seed_terms_zh.txt"),
        "terms_en": os.path.join(seed_txt_dir, "seed_terms_en.txt"),
    }
    for name, path in required.items():
        if not os.path.isfile(path):
            info(f"ERROR: Missing {name} at {path}")
            sys.exit(1)
    info("All seed text files found")

    # ── 2. Health check ─────────────────────────────────────────────
    try:
        urllib.request.urlopen(f"{api_base}/health", timeout=10)
        info("Backend reachable")
    except Exception:
        info("ERROR: Backend unreachable")
        sys.exit(1)

    # ── 3. Admin login ──────────────────────────────────────────────
    status, data = post(api_base, "/admin/api/v1/auth/login", {
        "request_id": "seed-site-config",
        "email": admin_email,
        "password": admin_password,
        "client_type": "admin",
    })
    if status != 200:
        info(f"ERROR: Admin login failed HTTP {status}: {data}")
        sys.exit(1)
    token = data["access_token"]
    info("Admin authenticated")

    # ── 4. Read existing config ─────────────────────────────────────
    status, data = post(api_base, "/admin/api/v1/site-config", token=token)
    existing_cfg = {}
    if status == 200:
        row = data
        if isinstance(row, dict) and "config" in row:
            existing_json = row["config"]
            if isinstance(existing_json, str):
                existing_cfg = json.loads(existing_json)
            else:
                existing_cfg = existing_json
    info(f"Existing config has {len(existing_cfg)} fields")

    # ── 5. Merge privacy/terms ──────────────────────────────────────
    privacy_zh = read_file(required["privacy_zh"])
    privacy_en = read_file(required["privacy_en"])
    terms_zh = read_file(required["terms_zh"])
    terms_en = read_file(required["terms_en"])

    existing_cfg["privacy_policy"] = {"zh-CN": privacy_zh, "en-US": privacy_en}
    existing_cfg["terms_of_service"] = {"zh-CN": terms_zh, "en-US": terms_en}
    existing_cfg.setdefault("default_locale", "zh-CN")
    existing_cfg.setdefault("supported_locales", ["zh-CN", "en-US"])
    existing_cfg.setdefault("site_domain", "livemask-vpn.com")
    existing_cfg.setdefault("site_name", "LiveMask")
    info("Content merged into site config")

    # ── 6. Update ───────────────────────────────────────────────────
    status, data = put(api_base, "/admin/api/v1/site-config", existing_cfg, token)
    if status != 200:
        info(f"ERROR: Update failed HTTP {status}: {data}")
        sys.exit(1)
    version = data.get("version", "?")
    info(f"Site config updated (version {version})")

    # ── 7. Publish ──────────────────────────────────────────────────
    status, data = post(api_base, "/admin/api/v1/site-config/publish", token=token)
    if status != 200:
        info(f"ERROR: Publish failed HTTP {status}: {data}")
        sys.exit(1)
    pub_status = data.get("status", "?")
    info(f"Site config published (status: {pub_status})")

    # ── 8. Verify public API ────────────────────────────────────────
    try:
        with urllib.request.urlopen(f"{api_base}/api/v1/site-config", timeout=10) as resp:
            public = json.loads(resp.read().decode("utf-8"))
        pp = public.get("privacy_policy", {})
        tos = public.get("terms_of_service", {})
        if pp.get("zh-CN") and tos.get("en-US"):
            info("Public API verified: privacy_policy and terms_of_service present")
        else:
            info("ERROR: Public API missing privacy/terms content")
            sys.exit(1)
    except Exception as e:
        info(f"ERROR: Public API verification failed: {e}")
        sys.exit(1)

    # ── 9. Secret leak scan ─────────────────────────────────────────
    forbidden = ["password", "token", "private_key", "api_key", "secret"]
    public_str = json.dumps(public)
    for f in forbidden:
        if f in public_str.lower():
            info(f"ERROR: Leak detected: '{f}' in public response")
            sys.exit(1)
    info("No secrets leaked in public response")

    info("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
