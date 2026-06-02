#!/usr/bin/env python3
"""Readable real-time CLI panel for the LiveMask autonomous engine."""

from __future__ import annotations

import argparse
import contextlib
import curses
import glob
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
from collections import Counter, deque
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover - Python without zoneinfo.
    ZoneInfo = None


ANSI_RE = re.compile(r"\033\[[0-9;]*m")
COLORS = {
    "red": "\033[31m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "magenta": "\033[35m",
    "cyan": "\033[36m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "reset": "\033[0m",
}

CURSES_COLOR_PAIRS = {
    31: 1,
    32: 2,
    33: 3,
    34: 4,
    35: 5,
    36: 6,
}


class Dashboard:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.root = pathlib.Path(os.environ.get("LIVEMASK_ROOT", "/Users/sammytan/Developer/LiveMask"))
        self.docs = pathlib.Path(os.environ.get("DOCS_DIR", str(self.root / "livemask-docs")))
        self.ci_cd = pathlib.Path(os.environ.get("CI_CD_DIR", str(self.root / "livemask-ci-cd")))
        self.cache = pathlib.Path(os.environ.get("ROLE_CACHE_DIR", str(pathlib.Path.home() / ".claude/role-cache")))
        self.pid_file = pathlib.Path(os.environ.get("PID_FILE", str(self.cache / "autonomous-loop.pid")))
        self.loop_log = pathlib.Path(os.environ.get("LOOP_LOG", "/tmp/claude/autonomous-loop.log"))
        self.event_log = pathlib.Path(os.environ.get("EVENT_LOG", str(self.cache / "events/event-log.jsonl")))
        self.agent_state_path = pathlib.Path(os.environ.get("AGENT_STATE", str(self.root / ".claude/agent-state.json")))
        self.audit_file = pathlib.Path(os.environ.get("AUDIT_FILE", str(self.cache / "closed-loop-audit.json")))
        self.display_tz_name = os.environ.get("LIVEMASK_DISPLAY_TZ", "Asia/Shanghai")
        self.use_color = not args.no_color and os.environ.get("NO_COLOR", "false").lower() != "true"
        self.width = max(96, min(shutil.get_terminal_size((120, 40)).columns, 150))
        self.display_tz = self.load_tz()
        self.parent_watch_without_color = self.detect_parent_watch_without_color()

    def load_tz(self):
        if ZoneInfo is None:
            self.display_tz_name = "UTC"
            return timezone.utc
        try:
            return ZoneInfo(self.display_tz_name)
        except Exception:
            self.display_tz_name = "UTC"
            return timezone.utc

    @staticmethod
    def detect_parent_watch_without_color() -> bool:
        try:
            proc = subprocess.run(
                ["ps", "-p", str(os.getppid()), "-o", "args="],
                text=True,
                capture_output=True,
                timeout=2,
            )
        except Exception:
            return False
        args = proc.stdout.strip()
        if not args or "watch" not in pathlib.Path(args.split()[0]).name:
            return False
        return " -c" not in f" {args} " and " --color" not in f" {args} "

    def c(self, text: object, color: str) -> str:
        text = str(text)
        if not self.use_color:
            return text
        return f"{COLORS.get(color, '')}{text}{COLORS['reset']}"

    @staticmethod
    def visible_len(text: object) -> int:
        return len(ANSI_RE.sub("", str(text)))

    def trunc(self, text: object, size: int) -> str:
        clean = str(text or "").replace("\n", " ").strip()
        if self.visible_len(clean) <= size:
            return clean
        return clean[: max(0, size - 3)] + "..."

    def pad(self, text: object, size: int) -> str:
        text = str(text)
        return text + (" " * max(0, size - self.visible_len(text)))

    def fit_cell(self, text: object, size: int) -> str:
        text = str(text)
        if self.visible_len(text) <= size:
            return self.pad(text, size)
        return self.pad(self.trunc(ANSI_RE.sub("", text), size), size)

    def line(self, char: str = "-") -> None:
        print(self.c(char * self.width, "dim"))

    def section(self, title: str) -> None:
        print()
        print(self.c(title.upper(), "bold"))
        self.line("-")

    def table(self, headers: list[str], rows: list[tuple[object, ...]], widths: list[int]) -> None:
        print("  ".join(self.c(self.pad(h, w), "dim") for h, w in zip(headers, widths)))
        print(self.c("  ".join("-" * w for w in widths), "dim"))
        for row in rows:
            print("  ".join(self.fit_cell(row[idx] if idx < len(row) else "", w) for idx, w in enumerate(widths)))

    def pill(self, label: str, state: str) -> str:
        palette = {"ok": "green", "warn": "yellow", "bad": "red", "info": "blue", "idle": "dim"}
        return self.c(self.pad(label, 6), palette.get(state, "dim"))

    def status(self, severity: str) -> str:
        return {
            "bad": self.pill("BLOCK", "bad"),
            "warn": self.pill("WARN", "warn"),
            "ok": self.pill("OK", "ok"),
            "idle": self.pill("IDLE", "idle"),
        }.get(severity, self.pill("INFO", "info"))

    def bullet(self, text: str, severity: str = "info") -> None:
        markers = {
            "ok": self.c("✓", "green"),
            "warn": self.c("!", "yellow"),
            "bad": self.c("x", "red"),
            "idle": self.c("-", "dim"),
            "info": self.c("•", "blue"),
        }
        print(f"  {markers.get(severity, markers['info'])} {text}")

    def now_utc(self) -> datetime:
        return datetime.now(timezone.utc)

    def now_display(self) -> datetime:
        return self.now_utc().astimezone(self.display_tz)

    def tz_label(self) -> str:
        return self.now_display().strftime("%Z") or self.display_tz_name

    def localize_loop_line(self, row: str) -> str:
        match = re.match(r"^\[(\d{2}):(\d{2}):(\d{2})\](.*)$", row)
        if not match:
            return row
        hh, mm, ss, rest = match.groups()
        base = self.now_utc().replace(hour=int(hh), minute=int(mm), second=int(ss), microsecond=0)
        if base > self.now_utc() and (base - self.now_utc()).total_seconds() > 12 * 3600:
            base -= timedelta(days=1)
        return f"[{base.astimezone(self.display_tz).strftime('%H:%M:%S')} {self.tz_label()}]{rest}"

    def age_text(self, ts: object) -> str:
        if not ts:
            return "unknown"
        try:
            if isinstance(ts, (int, float)):
                dt = datetime.fromtimestamp(float(ts), tz=timezone.utc)
            else:
                dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            sec = max(0, int((self.now_utc() - dt).total_seconds()))
        except Exception:
            return "unknown"
        if sec < 60:
            return f"{sec}s ago"
        if sec < 3600:
            return f"{sec // 60}m ago"
        if sec < 86400:
            return f"{sec // 3600}h ago"
        return f"{sec // 86400}d ago"

    @staticmethod
    def read_json(path: pathlib.Path, default=None):
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return {} if default is None else default

    @staticmethod
    def run(cmd: list[str], cwd: pathlib.Path | None = None, timeout: int = 4) -> tuple[int, str, str]:
        try:
            proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, timeout=timeout)
            return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
        except Exception as exc:
            return 1, "", str(exc)

    @staticmethod
    def ok_pid(pid: str) -> bool:
        if not pid or pid == "NONE":
            return False
        try:
            os.kill(int(pid), 0)
            return True
        except Exception:
            return False

    @staticmethod
    def load_tail(path: pathlib.Path, limit: int = 80) -> list[str]:
        if not path.exists():
            return []
        rows: deque[str] = deque(maxlen=limit)
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for row in handle:
                    if row.strip():
                        rows.append(row.rstrip("\n"))
        except Exception:
            return []
        return list(rows)

    def load_events(self, limit: int = 30) -> list[dict]:
        events = []
        for row in self.load_tail(self.event_log, limit):
            try:
                events.append(json.loads(row))
            except Exception:
                continue
        return events

    @staticmethod
    def task_lookup(ledger: dict) -> tuple[list[dict], dict[str, dict]]:
        tasks = []
        by_id = {}
        for module in ledger.get("modules", []):
            for task in module.get("tasks", []):
                item = {**task, "_module_id": module.get("module_id", "")}
                tasks.append(item)
                if item.get("task_id"):
                    by_id[item["task_id"]] = item
        return tasks, by_id

    def planner_summary(self) -> dict:
        script = self.docs / "scripts/plan-next-tasks.py"
        if not script.exists():
            return {"available": False}
        rc, out, _ = self.run(["python3", str(script), "--format", "json"], timeout=8)
        if rc != 0 or not out:
            return {"available": False}
        try:
            data = json.loads(out)
        except Exception:
            return {"available": False}
        return {"available": True, "summary": data.get("summary", {}), "top": data.get("global_next", [])[:5]}

    def git_state(self, repo_path: pathlib.Path) -> dict:
        rc_b, branch, _ = self.run(["git", "branch", "--show-current"], cwd=repo_path)
        rc_h, head, _ = self.run(["git", "rev-parse", "--short", "HEAD"], cwd=repo_path)
        rc_s, status, _ = self.run(["git", "status", "--porcelain"], cwd=repo_path)
        dirty = len([row for row in status.splitlines() if row.strip()]) if rc_s == 0 else "?"
        return {"branch": branch if rc_b == 0 else "?", "head": head if rc_h == 0 else "?", "dirty": dirty}

    def role_statuses(self, agent: dict, events: list[dict], reviews: list[pathlib.Path], audit: dict) -> list[tuple[str, str, str, str]]:
        current = agent.get("current_task") or {}
        phase = agent.get("phase", "idle")
        task_id = current.get("task_id") or ""
        repo = current.get("target_repo") or current.get("repo") or ""
        last_by_type = {ev.get("type", ""): ev for ev in events}

        under_review = []
        qa_waiting = []
        leader_waiting = []
        for path in reviews:
            data = self.read_json(path, {})
            tid = data.get("task_id") or path.name.removesuffix("-review.json")
            state = data.get("state", "")
            next_actor = data.get("next_required_actor", "")
            if state == "under_review" or next_actor == "leader":
                leader_waiting.append(tid)
            rounds = data.get("rounds") or []
            last = rounds[-1] if rounds else {}
            if state == "under_review" and not last.get("qa"):
                qa_waiting.append(tid)
            if state in {"under_review", "changes_requested"}:
                under_review.append(tid)

        summary = audit.get("summary", {})
        active_blockers = summary.get("active_blocker_count", 0)
        completion_debt = summary.get("completion_debt_count", 0)
        return [
            ("PM", "coordinating" if active_blockers else "watching queue", f"active blockers={active_blockers}; completion debt={completion_debt}", "bad" if active_blockers else ("warn" if completion_debt else "ok")),
            ("Product", "roadmap scan", "creates tasks only when MVP/requirements gaps have context", "ok"),
            ("Tech", "contract drift", f"last code event={self.age_text(last_by_type.get('code_committed', {}).get('emitted_at'))}", "info"),
            ("QA", "evidence gate" if qa_waiting else "idle", f"waiting={', '.join(qa_waiting[:2]) if qa_waiting else 'none'}", "warn" if qa_waiting else "ok"),
            ("TaskReview", "closure audit", f"open reviews={len(under_review)}; last completion={self.age_text(last_by_type.get('task_completed', {}).get('emitted_at'))}", "warn" if under_review else "ok"),
            ("Leader", "reviewing" if leader_waiting else "idle", f"waiting={', '.join(leader_waiting[:2]) if leader_waiting else 'none'}", "warn" if leader_waiting else "ok"),
            ("Executor", phase, f"{task_id or 'no active task'} {repo}".strip(), "ok" if phase in {"implementing", "revising", "merging"} else "idle"),
            ("Monitor", "observing events", f"events tail={len(events)}; last={events[-1].get('type') if events else 'none'}", "ok" if events else "warn"),
            ("Codex", "manual supervisor", "edits only when explicitly requested", "info"),
        ]

    def collect(self) -> dict:
        pid = self.pid_file.read_text().strip() if self.pid_file.exists() else ""
        agent = self.read_json(self.agent_state_path, {"phase": "unknown", "current_task": {}})
        ledger = self.read_json(self.docs / "docs/development/task-state-ledger.json", {"modules": []})
        tasks, tasks_by_id = self.task_lookup(ledger)
        events = self.load_events()
        reviews = sorted((self.docs / "docs/development/review-contracts").glob("*-review.json"))
        rc, out, _ = self.run(["bash", str(self.ci_cd / "scripts/autonomy-closed-loop-audit.sh"), "--output", str(self.audit_file)], timeout=12)
        if rc == 0 and out:
            try:
                audit = json.loads(out)
            except Exception:
                audit = self.read_json(self.audit_file, {})
        else:
            audit = self.read_json(self.audit_file, {})
        return {
            "pid": pid,
            "daemon_running": self.ok_pid(pid),
            "agent": agent,
            "tasks": tasks,
            "tasks_by_id": tasks_by_id,
            "events": events,
            "reviews": reviews,
            "audit": audit,
            "planner": self.planner_summary(),
            "dispatch_packets": [p for p in glob.glob(str(self.docs / "docs/development/dispatch-packets/*.json")) if not p.endswith(".gitkeep")],
            "loop_lines": self.load_tail(self.loop_log, 120),
            "ci_state": self.git_state(self.ci_cd),
            "docs_state": self.git_state(self.docs),
        }

    def render(self) -> None:
        data = self.collect()
        agent = data["agent"]
        current = agent.get("current_task") or {}
        current_task_id = current.get("task_id") or ""
        tasks_by_id = data["tasks_by_id"]
        current_task = tasks_by_id.get(current_task_id, {})
        ledger_counts = Counter(task.get("status", "unknown") for task in data["tasks"])
        done = ledger_counts.get("completed", 0) + ledger_counts.get("completed_with_skip", 0)
        total = len(data["tasks"])
        progress = int(done * 100 / max(total, 1))
        bar_width = 22
        bar_fill = int(progress * bar_width / 100)
        bar = "#" * bar_fill + "." * (bar_width - bar_fill)
        audit_summary = data["audit"].get("summary", {})
        issue_counts = audit_summary.get("issue_type_counts", {})
        last_loop_mtime = self.loop_log.stat().st_mtime if self.loop_log.exists() else None
        heartbeat_age = self.age_text(last_loop_mtime)
        log_fresh = bool(last_loop_mtime and (time.time() - last_loop_mtime) < 180)
        cycle = "0"
        for row in reversed(data["loop_lines"]):
            match = re.search(r"CYCLE#(\d+)", row)
            if match:
                cycle = match.group(1)
                break

        print(self.c("LiveMask Autonomous Engine Dashboard", "bold"))
        self.line("=")
        print(f"{self.c('Time', 'cyan')} {self.display_tz_name}: {self.now_display().strftime('%Y-%m-%d %H:%M:%S')} {self.tz_label()}   {self.c('Refresh', 'cyan')} bash scripts/engine-dashboard.sh --watch 3")
        print(f"{self.c('Repos', 'cyan')} ci-cd {data['ci_state']['branch']}@{data['ci_state']['head']} dirty={data['ci_state']['dirty']} | docs {data['docs_state']['branch']}@{data['docs_state']['head']} dirty={data['docs_state']['dirty']}")
        if self.parent_watch_without_color:
            print(self.c("Color note", "yellow") + ": external watch needs color mode: watch -c -n 3 bash scripts/engine-dashboard.sh")

        self.render_engine(data, audit_summary, cycle, heartbeat_age, log_fresh)
        self.render_active_task(data, current_task_id, current_task)
        self.render_roles(data)
        self.render_queue(data, ledger_counts, done, total, progress, bar, bar_fill, issue_counts)
        self.render_activity(data)
        self.render_actions(data, current_task_id, audit_summary)

        print()
        self.line("=")
        print(f"{self.c('One-shot', 'cyan')}: bash {self.ci_cd}/scripts/engine-dashboard.sh")
        print(f"{self.c('Recommended watch', 'cyan')}: bash {self.ci_cd}/scripts/engine-dashboard.sh --watch 3")
        print(f"{self.c('External watch', 'cyan')}: watch -c -n 3 bash {self.ci_cd}/scripts/engine-dashboard.sh")

    def render_watch_frame(self) -> None:
        print("\033[H\033[2J", end="")
        self.render()
        sys.stdout.flush()

    def render_text(self) -> str:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            self.render()
        return buffer.getvalue()

    def curses_watch(self) -> None:
        curses.wrapper(self._curses_watch)

    def _curses_watch(self, screen) -> None:
        curses.curs_set(0)
        screen.keypad(True)
        screen.nodelay(True)
        screen.timeout(max(1, int((self.args.watch or 3) * 1000)))
        if curses.has_colors():
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_RED, -1)
            curses.init_pair(2, curses.COLOR_GREEN, -1)
            curses.init_pair(3, curses.COLOR_YELLOW, -1)
            curses.init_pair(4, curses.COLOR_BLUE, -1)
            curses.init_pair(5, curses.COLOR_MAGENTA, -1)
            curses.init_pair(6, curses.COLOR_CYAN, -1)

        scroll_offset = 0
        while True:
            height, width = screen.getmaxyx()
            self.width = max(80, min(width - 1, 150))
            text = self.render_text()
            max_scroll = max(0, len(text.splitlines()) - max(1, height - 1))
            scroll_offset = min(scroll_offset, max_scroll)
            self.draw_ansi_text(screen, text, scroll_offset)
            key = screen.getch()
            if key in (ord("q"), ord("Q"), 27):
                break
            if key in (curses.KEY_DOWN, ord("j")):
                scroll_offset = min(max_scroll, scroll_offset + 1)
            elif key in (curses.KEY_UP, ord("k")):
                scroll_offset = max(0, scroll_offset - 1)
            elif key in (curses.KEY_NPAGE, ord(" ")):
                scroll_offset = min(max_scroll, scroll_offset + max(1, height - 4))
            elif key == curses.KEY_PPAGE:
                scroll_offset = max(0, scroll_offset - max(1, height - 4))
            elif key == curses.KEY_HOME:
                scroll_offset = 0
            elif key == curses.KEY_END:
                scroll_offset = max_scroll

    @staticmethod
    def ansi_attr(code: str, current: int) -> int:
        attr = current
        values = [int(part) for part in code.removeprefix("\033[").removesuffix("m").split(";") if part]
        if not values:
            values = [0]
        for value in values:
            if value == 0:
                attr = 0
            elif value == 1:
                attr |= curses.A_BOLD
            elif value == 2:
                attr |= curses.A_DIM
            elif value in CURSES_COLOR_PAIRS and curses.has_colors():
                attr &= ~curses.A_COLOR
                attr |= curses.color_pair(CURSES_COLOR_PAIRS[value])
        return attr

    def draw_ansi_text(self, screen, text: str, scroll_offset: int = 0) -> None:
        screen.erase()
        height, width = screen.getmaxyx()
        body_height = max(1, height - 1)
        lines = text.splitlines()
        y = 0
        for raw_line in lines[scroll_offset:]:
            if y >= body_height:
                break
            x = 0
            attr = 0
            pos = 0
            for match in ANSI_RE.finditer(raw_line):
                x = self.add_curses_segment(screen, y, x, raw_line[pos:match.start()], attr, width)
                attr = self.ansi_attr(match.group(0), attr)
                pos = match.end()
                if x >= width - 1:
                    break
            if x < width - 1:
                self.add_curses_segment(screen, y, x, raw_line[pos:], attr, width)
            y += 1
        footer = f" q/Esc exit | ↑↓/j/k scroll | PgUp/PgDn page | Home/End | row {scroll_offset + 1}/{max(1, len(lines))} "
        try:
            screen.addstr(height - 1, 0, footer[: max(0, width - 1)], curses.A_REVERSE)
        except curses.error:
            pass
        screen.refresh()

    def add_curses_segment(self, screen, y: int, x: int, segment: str, attr: int, width: int) -> int:
        if not segment or x >= width - 1:
            return x
        visible = segment[: max(0, width - 1 - x)]
        if visible:
            try:
                screen.addstr(y, x, visible, attr)
            except curses.error:
                pass
            x += len(visible)
        return x

    def render_engine(self, data: dict, audit_summary: dict, cycle: str, heartbeat_age: str, log_fresh: bool) -> None:
        self.section("1. Engine")
        daemon_sev = "ok" if data["daemon_running"] else ("warn" if log_fresh else "bad")
        daemon_label = "RUNNING" if data["daemon_running"] else ("PID STALE / LOG FRESH" if log_fresh else "STOPPED")
        audit_state = data["audit"].get("status", "unknown")
        audit_sev = "bad" if audit_state == "fail" else ("warn" if audit_state == "warn" else "ok")
        rows = [
            (self.status(daemon_sev), "Daemon", daemon_label, f"pid={data['pid'] or 'none'}  cycle=#{cycle}  log={heartbeat_age}"),
            (self.status(audit_sev), "Closed Loop", audit_state, f"active_blockers={audit_summary.get('active_blocker_count', '?')}  completion_debt={audit_summary.get('completion_debt_count', '?')}"),
        ]
        planner = data["planner"]
        if planner.get("available"):
            s = planner["summary"]
            rows.append((self.status("ok"), "Planner", "available", f"candidates={s.get('candidate_count', 0)}  blocked={s.get('blocked_open_count', 0)}  dispatch_packets={len(data['dispatch_packets'])}"))
        else:
            rows.append((self.status("warn"), "Planner", "unavailable", f"dispatch_packets={len(data['dispatch_packets'])}"))
        self.table(["State", "Part", "Status", "Detail"], rows, [6, 14, 22, min(78, self.width - 50)])

    def render_active_task(self, data: dict, current_task_id: str, current_task: dict) -> None:
        self.section("2. Active Task")
        current = data["agent"].get("current_task") or {}
        if current_task_id:
            repo = current.get("target_repo") or current_task.get("repo") or "?"
            branch = f"task/{current_task_id}"
            repo_dir = self.root / repo
            branch_exists = False
            if repo_dir.exists():
                rc, _, _ = self.run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=repo_dir)
                branch_exists = rc == 0
            plan = repo_dir / ".cursor-worker/current-task.json"
            rows = [
                (self.status("ok"), "Task", current_task_id, f"repo={repo}  ledger={current_task.get('status', '?')}"),
                (self.status("info"), "Phase", data["agent"].get("phase", "?"), f"task_phase={current.get('task_phase', '?')}"),
                (self.status("ok" if branch_exists else "warn"), "Branch", branch, f"exists={'yes' if branch_exists else 'no'}  handoff={'yes' if plan.exists() else 'no'}"),
                (self.status("info"), "Issue", current_task.get("issue") or "none", ""),
            ]
        else:
            top = data["planner"].get("top", []) if data["planner"].get("available") else []
            if top:
                rows = [(self.status("info"), "No Active", top[0].get("task_id"), f"repo={top[0].get('repo')}  readiness={top[0].get('readiness')}")]
            else:
                rows = [(self.status("idle"), "No Active", "planner queue empty", "no runnable task reported")]
        self.table(["State", "Field", "Value", "Detail"], rows, [6, 12, 28, min(78, self.width - 52)])

    def render_roles(self, data: dict) -> None:
        self.section("3. Roles")
        rows = [(self.status(sev), role, state, detail) for role, state, detail, sev in self.role_statuses(data["agent"], data["events"], data["reviews"], data["audit"])]
        self.table(["State", "Role", "Doing", "Detail"], rows, [6, 12, 22, min(88, self.width - 48)])

    def render_queue(self, data: dict, ledger_counts: Counter, done: int, total: int, progress: int, bar: str, bar_fill: int, issue_counts: dict) -> None:
        self.section("4. Queue And Evidence")
        bar_color = "green" if progress >= 95 else ("yellow" if progress >= 65 else "blue")
        print(f"{self.c('Progress', 'cyan')} {done}/{total} ({progress}%) [{self.c(bar[:bar_fill], bar_color)}{self.c(bar[bar_fill:], 'dim')}]")
        rows = []
        for name, count in ledger_counts.most_common(8):
            sev = "ok" if name in {"completed", "completed_with_skip"} else ("warn" if name in {"blocked", "changes_requested"} else "info")
            rows.append((self.status(sev), name, str(count)))
        if rows:
            self.table(["State", "Ledger Status", "Count"], rows, [6, 32, 8])
        print()
        self.bullet(f"Dispatch packets: {len(data['dispatch_packets'])} active", "ok" if data["dispatch_packets"] else "idle")
        planner = data["planner"]
        if planner.get("available") and planner.get("top"):
            print(self.c("Planner top", "cyan"))
            for item in planner["top"][:5]:
                self.bullet(f"{item.get('task_id')}  repo={item.get('repo')}  readiness={item.get('readiness')}  priority={item.get('priority', '?')}", "info")
        else:
            self.bullet("Planner top: none", "idle")
        if issue_counts:
            print(self.c("Audit issue counts", "cyan"))
            for name, count in sorted(issue_counts.items(), key=lambda kv: (-kv[1], kv[0]))[:6]:
                self.bullet(f"{name}: {count}", "bad" if count and "missing" in name else "warn")

    def render_activity(self, data: dict) -> None:
        self.section("5. Recent Activity")
        activity = []
        for row in reversed(data["loop_lines"]):
            if "CYCLE#" in row:
                activity.append(row)
            if len(activity) >= 7:
                break
        activity = list(reversed(activity))
        if not activity:
            self.bullet("No autonomous-loop activity found.", "idle")
        else:
            rows = []
            for row in activity:
                low = row.lower()
                sev = "bad" if any(x in low for x in ["fail", "error", "dead", "blocked", "rejected"]) else ("idle" if any(x in low for x in ["sleep", "waiting"]) else ("ok" if any(x in low for x in ["accept", "complete", "pass"]) else "info"))
                localized = self.localize_loop_line(row)
                match = re.match(r"^\[([^\]]+)\]\s+(CYCLE#\d+)\s+(.*)$", localized)
                when, cyc, message = match.groups() if match else ("", "", localized)
                rows.append((self.status(sev), when, cyc, message))
            self.table(["State", "Time", "Cycle", "Message"], rows, [6, 16, 10, min(100, self.width - 40)])

        if data["events"]:
            print()
            print(self.c("Event tail", "cyan"))
            for ev in data["events"][-6:]:
                self.bullet(f"{ev.get('type', '?'):<18} task={ev.get('task_id') or '-'} age={self.age_text(ev.get('emitted_at'))}", "info")

    def render_actions(self, data: dict, current_task_id: str, audit_summary: dict) -> None:
        self.section("6. Next Actions")
        actions = []
        if not data["daemon_running"]:
            actions.append("Start or restart autonomous loop if it should be running.")
        if audit_summary.get("active_blocker_count", 0):
            actions.append("Resolve active closed-loop blockers before creating more tasks.")
        if audit_summary.get("completion_debt_count", 0):
            actions.append("Run closure audit/backfill review evidence for completed tasks with missing QA/review proof.")
        current = data["agent"].get("current_task") or {}
        if current_task_id and current.get("target_repo"):
            actions.append(f"Inspect target repo handoff: {self.root / current['target_repo']}/.cursor-worker/current-task.json")
        planner = data["planner"]
        if planner.get("available") and planner.get("summary", {}).get("candidate_count", 0) == 0 and len(data["dispatch_packets"]) == 0:
            actions.append("Queue has no active candidates; run product/PM role only if MVP audit shows gaps.")
        if not actions:
            actions.append("No immediate action. Monitor event tail and closed-loop audit.")
        for idx, action in enumerate(actions[:6], 1):
            color = "red" if idx == 1 and (not data["daemon_running"] or audit_summary.get("active_blocker_count", 0)) else ("yellow" if idx <= 2 else "blue")
            print(f"  {self.c(str(idx).rjust(2), color)}  {action}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Readable LiveMask autonomous engine dashboard.",
        epilog="Color tip: prefer '--watch 3'. If using external watch, run 'watch -c -n 3 bash scripts/engine-dashboard.sh'.",
    )
    parser.add_argument("--watch", type=float, metavar="SECONDS", help="refresh continuously every N seconds")
    parser.add_argument("--no-color", "--plain", action="store_true", dest="no_color", help="disable ANSI colors")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if sys.stdout.isatty() and os.environ.get("TERM", "dumb") in {"", "dumb", "unknown"}:
        os.environ["TERM"] = "xterm-256color"
    dashboard = Dashboard(args)
    if args.watch:
        if sys.stdout.isatty() and not args.no_color:
            try:
                dashboard.curses_watch()
                return 0
            except KeyboardInterrupt:
                return 130
            except Exception:
                pass
        print("\033[?1049h\033[?25l", end="")
        try:
            while True:
                dashboard.render_watch_frame()
                time.sleep(args.watch)
        except KeyboardInterrupt:
            return 130
        finally:
            print("\033[?25h\033[?1049l", end="")
            sys.stdout.flush()
    dashboard.render()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
