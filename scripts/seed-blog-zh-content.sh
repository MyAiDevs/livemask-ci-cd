#!/usr/bin/env bash
# Seed 20 Chinese blog articles via Admin API (skips slugs that already exist).
set -euo pipefail

API_BASE="${API_BASE:-http://127.0.0.1:3001/admin/api/v1}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@livemask.dev}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-AdminPass123!}"

info() { echo "[seed-blog-zh] $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$API_BASE" "$ADMIN_EMAIL" "$ADMIN_PASSWORD" "${SCRIPT_DIR}/data/seed_blog_zh_payloads.py" <<'PY'
import json
import subprocess
import sys
import urllib.error
import urllib.request

api_base, email, password, payload_py = sys.argv[1:5]

def post(path, body=None, token=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(f"{api_base}{path}", data=data, headers=headers, method="POST" if body else "GET")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"error": raw}
        return err.code, payload

login_body = {
    "request_id": "seed-blog-zh",
    "email": email,
    "password": password,
    "client_type": "admin",
}
status, data = post("/auth/login", login_body)
if status != 200:
    print(f"login failed HTTP {status}: {data}", file=sys.stderr)
    sys.exit(1)
token = data["access_token"]

created = skipped = failed = 0
proc = subprocess.run([sys.executable, payload_py], capture_output=True, text=True, check=True)
for line in proc.stdout.splitlines():
    if not line.strip():
        continue
    payload = json.loads(line)
    slug = payload["slug"]
    status, resp = post("/content", payload, token)
    if status in (200, 201):
        created += 1
        print(f"[seed-blog-zh] created {slug}")
    elif status == 409 or "duplicate key" in json.dumps(resp, ensure_ascii=False):
        skipped += 1
        print(f"[seed-blog-zh] skip {slug} (exists)")
    else:
        failed += 1
        print(f"[seed-blog-zh] FAIL {slug} HTTP {status}: {resp}", file=sys.stderr)

print(f"[seed-blog-zh] done: created={created} skipped={skipped} failed={failed}")
sys.exit(1 if failed else 0)
PY
