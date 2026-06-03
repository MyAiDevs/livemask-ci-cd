#!/usr/bin/env python3
"""
lark_send.py — Send notifications to Lark (Feishu) via webhook.

Supports HMAC-SHA256 signed webhooks.
Supports plain text and interactive卡片 messages.

Usage:
    lark_send.py text <webhook_url> <message-text>
    lark_send.py card <webhook_url> <title> <content> [--sign-key KEY]
    lark_send.py notify <webhook_url> <event_type> <payload>

Pure Python. Dependencies: requests (optional, uses urllib as fallback).
"""

import hashlib
import hmac
import json
import os
import sys
import time
import base64
import urllib.request
import urllib.error


def _gen_sign(timestamp: int, secret: str) -> str:
    """Generate HMAC-SHA256 signature for Lark webhook."""
    string_to_sign = f"{timestamp}\n{secret}"
    h = hmac.new(secret.encode("utf-8"), string_to_sign.encode("utf-8"),
                 hashlib.sha256)
    return base64.b64encode(h.digest()).decode("utf-8")


def _send(url: str, payload: dict) -> dict:
    """Send HTTP POST with JSON payload. Supports both requests and urllib."""
    data = json.dumps(payload).encode("utf-8")

    # Try requests first
    try:
        import requests
        r = requests.post(url, json=payload, timeout=15)
        return {"status": r.status_code, "response": r.text[:500]}
    except ImportError:
        pass
    except Exception as e:
        return {"status": 0, "error": str(e)}

    # Fallback to urllib
    try:
        req = urllib.request.Request(
            url, data=data,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8")
            return {"status": resp.status, "response": body[:500]}
    except urllib.error.HTTPError as e:
        return {"status": e.code, "error": e.read().decode("utf-8")[:500]}
    except Exception as e:
        return {"status": 0, "error": str(e)}


def cmd_text(args: list[str]) -> int:
    """Send plain text message."""
    url = args[0] if len(args) > 0 else ""
    message = args[1] if len(args) > 1 else ""

    if not url or not message:
        print(json.dumps({"error": "usage: text <webhook_url> <message>"}), file=sys.stderr)
        return 1

    payload = {
        "msg_type": "text",
        "content": {"text": message},
    }
    result = _send(url, payload)
    print(json.dumps(result))
    return 0


def cmd_card(args: list[str]) -> int:
    """Send interactive card message."""
    url = args[0] if len(args) > 0 else ""
    title = args[1] if len(args) > 1 else ""
    content = args[2] if len(args) > 2 else ""

    sign_key = ""
    for i in range(3, len(args)):
        if args[i] == "--sign-key" and i + 1 < len(args):
            sign_key = args[i + 1]

    if not url or not title:
        print(json.dumps({"error": "usage: card <url> <title> <content> [--sign-key KEY]"}),
              file=sys.stderr)
        return 1

    ts = int(time.time())
    card_data = {
        "header": {
            "title": {"tag": "plain_text", "content": title},
            "template": "blue",
        },
        "elements": [
            {"tag": "markdown", "content": content},
        ],
    }

    payload = {
        "msg_type": "interactive",
        "card": card_data,
        "timestamp": str(ts),
    }

    if sign_key:
        payload["sign"] = _gen_sign(ts, sign_key)

    result = _send(url, payload)
    print(json.dumps(result))
    return 0


EVENT_TEMPLATES = {
    "task_accepted": {
        "header": "✅ Task Accepted",
        "template": "green",
        "format": "**Task**: {{task_id}}\n**Repo**: {{repo}}\n**Phase**: {{phase}}\n*Auto-notification*",
    },
    "task_completed": {
        "header": "✅ Task Completed",
        "template": "green",
        "format": "**Task**: {{task_id}}\n**Merge**: {{merge_sha}}\n**Issue**: {{issue_url}}\n*Auto-notification*",
    },
    "task_blocked": {
        "header": "⛔ Task Blocked",
        "template": "red",
        "format": "**Task**: {{task_id}}\n**Reason**: {{reason}}\n**Phase**: {{phase}}\n*Auto-notification*",
    },
    "task_repair": {
        "header": "🔧 Auto-Repair",
        "template": "yellow",
        "format": "**Task**: {{task_id}}\n**Log**: {{log_file}}\n**Fix Applied**: {{fix}}\n*Auto-notification*",
    },
    "task_bug": {
        "header": "🐛 Bug Report",
        "template": "red",
        "format": "**Task**: {{task_id}}\n**Description**: {{description}}\n**Source**: {{source}}\n*Auto-notification*",
    },
    "task_created": {
        "header": "📋 Task Created",
        "template": "blue",
        "format": "**Task ID**: {{task_id}}\n**Source**: {{source}}\n**Contract**: {{contract}}\n**GitHub Issue**: {{issue_url}}\n*Auto-created by planner*",
    },
    "system_error": {
        "header": "⚠️ System Error",
        "template": "red",
        "format": "**Error**: {{error}}\n**Context**: {{context}}\n*System notification*",
    },
}


def cmd_notify(args: list[str]) -> int:
    """Send event-specific notification."""
    url = args[0] if len(args) > 0 else ""
    event_type = args[1] if len(args) > 1 else ""
    payload_raw = args[2] if len(args) > 2 else "{}"

    if not url or not event_type:
        print(json.dumps({"error": "usage: notify <url> <event_type> <json_payload>"}),
              file=sys.stderr)
        return 1

    try:
        event_data = json.loads(payload_raw)
    except json.JSONDecodeError:
        event_data = {}

    template = EVENT_TEMPLATES.get(event_type)
    if not template:
        print(json.dumps({"error": f"unknown event type: {event_type}"}), file=sys.stderr)
        return 1

    # Render template
    body = template["format"]
    for k, v in event_data.items():
        body = body.replace("{{" + k + "}}", str(v))

    ts = int(time.time())
    card_data = {
        "header": {
            "title": {"tag": "plain_text", "content": template["header"]},
            "template": template.get("template", "blue"),
        },
        "elements": [{"tag": "markdown", "content": body}],
    }

    sign_key = ""
    for i in range(3, len(args)):
        if args[i] == "--sign-key" and i + 1 < len(args):
            sign_key = args[i + 1]

    payload = {
        "msg_type": "interactive",
        "card": card_data,
        "timestamp": str(ts),
    }

    if sign_key:
        payload["sign"] = _gen_sign(ts, sign_key)

    result = _send(url, payload)
    result["event_type"] = event_type
    print(json.dumps(result))
    return 0


def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  lark_send.py text <webhook_url> <message>")
        print("  lark_send.py card <webhook_url> <title> <content> [--sign-key KEY]")
        print("  lark_send.py notify <webhook_url> <event_type> <json_payload>")
        print("")
        print("Event types: " + ", ".join(EVENT_TEMPLATES.keys()))
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "text": cmd_text,
        "card": cmd_card,
        "notify": cmd_notify,
    }

    if command not in cmds:
        print(f"unknown command: {command}", file=sys.stderr)
        sys.exit(1)

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
