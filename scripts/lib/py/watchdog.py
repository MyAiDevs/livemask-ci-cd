#!/usr/bin/env python3
"""watchdog.py — Shared auto-reload watchdog for long-running daemons.

Usage:
  from watchdog import Watchdog
  w = Watchdog(poll_interval=30)
  w.watch(__file__)
  w.watch("/path/to/lib.py")
  while True:
      if w.changed():
          os.execv(sys.executable, [sys.executable] + sys.argv)
      ... do work ...
"""
import os, sys, time

from debug_utils import setup as _debug_setup, traced, logger as _logger


class Watchdog:
    def __init__(self, poll_interval: int = 30):
        self._interval = poll_interval
        self._files: dict[str, float] = {}
        self._reload_requested = False

    def watch(self, path: str) -> None:
        abspath = os.path.abspath(path)
        try:
            self._files[abspath] = os.path.getmtime(abspath)
        except OSError:
            pass

    def watch_dir(self, directory: str, suffix: str = ".py") -> None:
        if not os.path.isdir(directory):
            return
        for fname in os.listdir(directory):
            if fname.endswith(suffix):
                self.watch(os.path.join(directory, fname))

    def request_reload(self) -> None:
        self._reload_requested = True

    def changed(self) -> bool:
        if self._reload_requested:
            return True
        time.sleep(self._interval)
        if self._reload_requested:
            return True
        for path, old_mtime in list(self._files.items()):
            try:
                if os.path.getmtime(path) != old_mtime:
                    print(f"[watchdog] {os.path.basename(path)} changed, reloading", flush=True)
                    return True
            except OSError:
                pass
        return False

    def restart(self) -> None:
        print(f"[watchdog] execv restart: {' '.join(sys.argv)}", flush=True)
        os.execv(sys.executable, [sys.executable] + sys.argv)
