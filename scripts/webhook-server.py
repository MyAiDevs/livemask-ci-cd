#!/usr/bin/env python3
"""Webhook v5 — GitHub Issue + CI + Lark receive server with auto-reload.

Auto-reload: server monitors its own source file for mtime changes and
restarts itself gracefully (draining active connections). Also supports
POST /reload for manual/CI-triggered restart.

Endpoints:
  POST /github-issue  — GitHub Issue webhook (issues, issue_comment, push, ping)
  POST /github-ci     — GitHub workflow_run webhook
  POST /reload        — Graceful self-restart (requires token auth)
  POST /lark          — Lark bot messages -> inbox
  GET  /health        — Status

Run: WEBHOOK_TOKEN=xxx python3 webhook-server.py --port 10086
"""
import json, pathlib, time, os, hmac, hashlib, argparse, threading
from http.server import HTTPServer, BaseHTTPRequestHandler

EVENT_DIR = pathlib.Path(os.path.expanduser("~/.claude/role-cache/webhook-events"))
EVENT_DIR.mkdir(parents=True, exist_ok=True)
INBOX_FILE = EVENT_DIR / "inbox.jsonl"
TOKEN = os.environ.get("WEBHOOK_TOKEN", "livemask-webhook-2026")
GH_SECRET = os.environ.get("GH_WEBHOOK_SECRET", "").encode() if os.environ.get("GH_WEBHOOK_SECRET") else None
# Self path for auto-reload monitoring
SELF_PATH = os.path.abspath(__file__)
POLL_INTERVAL = int(os.environ.get("WATCH_POLL_SECONDS", "30"))

# Global server reference for graceful restart
_server: HTTPServer = None
_reload_requested = False


def write_event(evt):
    with open(INBOX_FILE, "a") as f:
        f.write(json.dumps(evt, ensure_ascii=False) + "\n")


def verify_auth(headers):
    auth = headers.get("Authorization", headers.get("X-Webhook-Token", ""))
    return auth.replace("Bearer ", "").replace("token ", "").strip() == TOKEN


def verify_gh_sig(body, sig_header):
    if not GH_SECRET:
        return True
    if not sig_header:
        return False
    expected = "sha256=" + hmac.new(GH_SECRET, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig_header)


def _file_watchdog():
    """Background thread: poll self mtime, request reload on change."""
    global _reload_requested
    last_mtime = os.path.getmtime(SELF_PATH)
    while not _reload_requested:
        time.sleep(POLL_INTERVAL)
        try:
            mtime = os.path.getmtime(SELF_PATH)
            if mtime != last_mtime:
                print(f"[watchdog] source changed ({mtime}), requesting reload", flush=True)
                _reload_requested = True
                if _server:
                    _server.shutdown()
                break
        except OSError:
            pass


def _reload():
    """Trigger graceful self-restart from a request handler."""
    global _reload_requested
    _reload_requested = True
    if _server:
        threading.Thread(target=_server.shutdown, daemon=True).start()


class WebhookHandler(BaseHTTPRequestHandler):

    def respond(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))

    def log_message(self, fmt, *args):
        pass

    def read_body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def handle_github_issue(self, body):
        event_type = self.headers.get("X-GitHub-Event", "unknown")
        delivery = self.headers.get("X-GitHub-Delivery", "")
        sig = self.headers.get("X-Hub-Signature-256", "")
        if not verify_gh_sig(body, sig):
            return self.respond(403, {"status": "denied", "signature": "invalid"})
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as e:
            return self.respond(400, {"status": "error", "message": str(e)})
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        repo_name = payload.get("repository", {}).get("full_name", "unknown")
        action = payload.get("action", "")
        print(f"[GH-{event_type}] {repo_name} action={action}", flush=True)

        if event_type == "ping":
            return self.respond(200, {"status": "pong", "hook_id": payload.get("hook_id", "")})

        if event_type == "issues":
            issue = payload.get("issue", {})
            evt = {
                "source": "github_webhook", "event": "issues",
                "delivery": delivery, "action": action, "repo": repo_name,
                "issue_number": issue.get("number"), "issue_title": issue.get("title", ""),
                "issue_body": issue.get("body", ""), "issue_url": issue.get("html_url", ""),
                "labels": [l.get("name", "") for l in issue.get("labels", [])],
                "state": issue.get("state", ""), "user": issue.get("user", {}).get("login", ""), "ts": now,
            }
            write_event(evt)
            return self.respond(200, {"status": "ok", "action": action})

        if event_type == "issue_comment":
            issue = payload.get("issue", {})
            comment = payload.get("comment", {})
            evt = {
                "source": "github_webhook", "event": "issue_comment",
                "delivery": delivery, "action": action, "repo": repo_name,
                "issue_number": issue.get("number"), "issue_title": issue.get("title", ""),
                "comment_body": comment.get("body", ""), "comment_url": comment.get("html_url", ""),
                "user": comment.get("user", {}).get("login", ""), "ts": now,
            }
            write_event(evt)
            return self.respond(200, {"status": "ok", "action": action})

        if event_type == "push":
            ref = payload.get("ref", "")
            evt = {
                "source": "github_webhook", "event": "push",
                "delivery": delivery, "repo": repo_name,
                "ref": ref, "branch": ref.replace("refs/heads/", ""),
                "pusher": payload.get("pusher", {}).get("name", ""), "ts": now,
            }
            write_event(evt)
            return self.respond(200, {"status": "ok"})

        evt = {
            "source": "github_webhook", "event": event_type,
            "delivery": delivery, "action": action, "repo": repo_name, "ts": now,
        }
        write_event(evt)
        return self.respond(200, {"status": "ignored", "event": event_type})

    def do_GET(self):
        if "/health" in self.path:
            cnt = 0
            if INBOX_FILE.exists():
                try: cnt = sum(1 for _ in open(INBOX_FILE))
                except: pass
            return self.respond(200, {
                "status": "healthy", "version": "v5",
                "uptime": time.time() - getattr(self.server, "_start_time", time.time()),
                "events": cnt,
                "self_mtime": os.path.getmtime(SELF_PATH),
                "endpoints": ["POST /github-issue", "POST /github-ci", "POST /reload", "POST /lark", "GET /health"],
            })
        return self.respond(200, {"status": "webhook v5", "endpoints": [
            "POST /github-issue", "POST /github-ci", "POST /reload", "POST /lark", "GET /health"]})

    def do_POST(self):
        body = self.read_body()
        path = self.path
        if "/health" in path:
            return self.respond(200, {"status": "healthy"})
        # /reload doesn't need external auth (it's server-internal)
        if "/reload" in path:
            print("[reload] triggered via POST", flush=True)
            _reload()
            return self.respond(200, {"status": "reloading", "message": "server will restart momentarily"})
        if not verify_auth(dict(self.headers)):
            return self.respond(403, {"status": "denied"})
        if "/github-issue" in path:
            return self.handle_github_issue(body)
        if "/github-ci" in path or "/github" in path:
            try:
                data = json.loads(body)
                wr = data.get("workflow_run", {})
                evt = {
                    "source": "github_webhook", "event": "workflow_run",
                    "delivery": self.headers.get("X-GitHub-Delivery", ""),
                    "repo": data.get("repository", {}).get("full_name", ""),
                    "workflow": wr.get("name", ""), "conclusion": wr.get("conclusion", ""),
                    "url": wr.get("html_url", ""),
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                }
                write_event(evt)
                tag = "OK" if evt["conclusion"] == "success" else "FAIL" if evt["conclusion"] == "failure" else "?"
                print(f"[GH-CI] {tag} {evt['repo']}: {evt['workflow']} -> {evt['conclusion']}", flush=True)
                return self.respond(200, {"status": "ok"})
            except Exception as e:
                return self.respond(400, {"status": "error", "message": str(e)})
        if "/lark" in path:
            try:
                data = json.loads(body)
                if "challenge" in data:
                    return self.respond(200, {"challenge": data["challenge"]})
                text, user = "", "unknown"
                if "event" in data:
                    evt_data = data["event"]
                    mc = evt_data.get("message", {}).get("content", "{}")
                    try: text = json.loads(mc).get("text", "")
                    except: text = mc
                    user = (evt_data.get("sender", {}).get("sender_id", {}).get("open_id", "")
                            or evt_data.get("operator_id", {}).get("open_id", "") or "unknown")
                else:
                    text = data.get("text", data.get("content", ""))
                    user = data.get("user_name", data.get("sender", {}).get("name", "unknown"))
                t = text.strip()
                mt = ("requirement" if t.startswith("\u9700\u6c42:") else
                      "bug_report" if t.startswith("Bug:") or t.startswith("bug:") else
                      "improvement" if t.startswith("\u6539\u8fdb:") else
                      "status_query" if t in ("\u72b6\u6001", "status") else "message")
                evt = {"source": "lark_webhook", "msg_type": mt, "message": text, "user": user,
                       "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                write_event(evt)
                print(f"[LARK] {user}: {text[:80]}", flush=True)
                return self.respond(200, {"status": "ok", "type": mt})
            except Exception as e:
                return self.respond(400, {"status": "error", "message": str(e)})
        return self.respond(404, {"status": "unknown"})


def serve(host, port):
    """Run server with auto-reload loop."""
    global _server, _reload_requested
    # Track restart count for /health
    restarts = 0
    while True:
        _reload_requested = False
        _server = HTTPServer((host, port), WebhookHandler)
        _server._start_time = time.time()
        print(f"Webhook v5 (restart #{restarts}): http://{host}:{port}", flush=True)
        print(f"  Token: {TOKEN[:4]}***{' + GH_SECRET' if GH_SECRET else ' (no GH_SECRET)'}", flush=True)
        print(f"  Watchdog: poll every {POLL_INTERVAL}s for file changes", flush=True)
        print(f"  POST /github-issue  -> inbox.jsonl", flush=True)
        print(f"  POST /github-ci     -> inbox.jsonl", flush=True)
        print(f"  POST /reload        -> graceful restart", flush=True)
        print(f"  POST /lark          -> inbox.jsonl", flush=True)
        print(f"  GET  /health        -> status", flush=True)

        # Start watchdog thread
        watcher = threading.Thread(target=_file_watchdog, daemon=True)
        watcher.start()

        try:
            _server.serve_forever()
        except KeyboardInterrupt:
            print("\nShutdown.", flush=True)
            _server.server_close()
            return

        # serve_forever() returned due to shutdown() — check if reload
        _server.server_close()
        if _reload_requested:
            restarts += 1
            print(f"[reload] restarting #{restarts}...", flush=True)
            time.sleep(0.5)  # brief drain window
            continue
        else:
            print("[exit] server stopped (not requested reload)", flush=True)
            return


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=10086)
    p.add_argument("--host", default="0.0.0.0")
    a = p.parse_args()
    serve(a.host, a.port)
