#!/usr/bin/env bash
set -euo pipefail

RESULT="${1:-${WORKFLOW_RESULT:-unknown}}"

if [[ -z "${LARK_BOT_WEBHOOK:-}" ]]; then
  echo "LARK_BOT_WEBHOOK is not configured; skip Lark notification."
  exit 0
fi

python3 - "$RESULT" <<'PY'
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

result = sys.argv[1] if len(sys.argv) > 1 else os.getenv("WORKFLOW_RESULT", "unknown")
webhook = os.environ["LARK_BOT_WEBHOOK"]
secret = os.getenv("LARK_BOT_SECRET", "")
repo = os.getenv("GITHUB_REPOSITORY", "unknown")
workflow = os.getenv("GITHUB_WORKFLOW", "unknown")
run_id = os.getenv("GITHUB_RUN_ID", "")
run_number = os.getenv("GITHUB_RUN_NUMBER", "")
server_url = os.getenv("GITHUB_SERVER_URL", "https://github.com")
ref_name = os.getenv("GITHUB_REF_NAME", "")
actor = os.getenv("GITHUB_ACTOR", "")
sha = os.getenv("GITHUB_SHA", "")
run_url = f"{server_url}/{repo}/actions/runs/{run_id}" if run_id else server_url

template = {
    "success": "green",
    "failure": "red",
    "cancelled": "yellow",
    "skipped": "grey",
}.get(result, "blue")

payload = {
    "msg_type": "interactive",
    "card": {
        "config": {"wide_screen_mode": True},
        "header": {
            "template": template,
            "title": {
                "tag": "plain_text",
                "content": f"LiveMask CI/CD {result.upper()}",
            },
        },
        "elements": [
            {
                "tag": "div",
                "text": {
                    "tag": "lark_md",
                    "content": (
                        f"**Repository:** {repo}\n"
                        f"**Workflow:** {workflow} #{run_number}\n"
                        f"**Ref:** {ref_name}\n"
                        f"**Actor:** {actor}\n"
                        f"**Commit:** {sha[:12]}\n"
                        f"**Result:** {result}"
                    ),
                },
            },
            {
                "tag": "action",
                "actions": [
                    {
                        "tag": "button",
                        "text": {"tag": "plain_text", "content": "Open GitHub Run"},
                        "url": run_url,
                        "type": "primary",
                    }
                ],
            },
        ],
    },
}

if secret:
    timestamp = str(int(time.time()))
    string_to_sign = f"{timestamp}\n{secret}"
    sign = base64.b64encode(
        hmac.new(secret.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha256).digest()
    ).decode("utf-8")
    payload["timestamp"] = timestamp
    payload["sign"] = sign

request = urllib.request.Request(
    webhook,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read().decode("utf-8")
        print(f"Lark notification sent: HTTP {response.status} {body}")
except (urllib.error.URLError, TimeoutError) as exc:
    print(f"Lark notification failed but will not fail workflow: {exc}", file=sys.stderr)
PY
