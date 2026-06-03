#!/usr/bin/env python3
"""debug_utils.py — Shared debug/trace support for all LiveMask Python tools.

Usage:
    from debug_utils import Debug, traced

    Debug.setup()
    log = Debug.logger(__name__)

    @traced
    def my_function(arg1):
        log.debug("processing %s", arg1)
        ...

Enables CLAUDE_DEBUG env var propagation from shell to Python.
"""

import os
import sys
import functools
import traceback
from datetime import datetime, timezone

_LEVEL = int(os.environ.get("CLAUDE_DEBUG", "0"))


def setup(level: int | None = None) -> None:
    """Initialize debug system from env or explicit level."""
    global _LEVEL
    if level is not None:
        _LEVEL = level
    else:
        _LEVEL = int(os.environ.get("CLAUDE_DEBUG", "0"))


class _Logger:
    """Lightweight logger that respects CLAUDE_DEBUG level."""

    def __init__(self, name: str):
        self.name = name

    def debug(self, msg: str, *args, **kwargs):
        if _LEVEL >= 1:
            self._write("DEBUG", msg, args, kwargs)

    def trace(self, msg: str, *args, **kwargs):
        if _LEVEL >= 2:
            self._write("TRACE", msg, args, kwargs)

    def _write(self, level: str, msg: str, args, kwargs):
        ts = datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:12]
        formatted = msg % args if args else msg
        if kwargs:
            extra = " ".join(f"{k}={v}" for k, v in kwargs.items())
            formatted = f"{formatted} | {extra}"
        line = f"[{ts}] [{level}] [{self.name}] {formatted}"
        print(line, file=sys.stderr, flush=True)


_loggers: dict[str, _Logger] = {}


def logger(name: str) -> _Logger:
    """Get or create a debug logger for the given module name."""
    if name not in _loggers:
        _loggers[name] = _Logger(name)
    return _loggers[name]


def traced(func):
    """Decorator: log function entry/exit when CLAUDE_DEBUG >= 1.

    At DEBUG=1: logs "→ func(args...)" on entry, "← func → result" on exit.
    At DEBUG=2: also logs argument values and elapsed time.

    Usage:
        @traced
        def my_func(a, b):
            ...
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        if _LEVEL >= 1:
            log = logger(func.__module__)
            arg_str = _format_args(func, args, kwargs) if _LEVEL >= 2 else _count_args(args, kwargs)
            log.debug("→ %s(%s)", func.__name__, arg_str)
            t0 = datetime.now(timezone.utc) if _LEVEL >= 2 else None

        try:
            result = func(*args, **kwargs)
        except Exception as e:
            if _LEVEL >= 1:
                log = logger(func.__module__)
                tb = traceback.format_exc() if _LEVEL >= 2 else str(e)
                log.debug("← %s ✗ EXCEPTION: %s", func.__name__, tb)
            raise

        if _LEVEL >= 1:
            log = logger(func.__module__)
            if _LEVEL >= 2:
                elapsed = (datetime.now(timezone.utc) - t0).total_seconds()
                result_str = _short_str(result)
                log.debug("← %s ✓ %s (%.3fs)", func.__name__, result_str, elapsed)
            else:
                log.debug("← %s ✓", func.__name__)
        return result
    return wrapper


def _format_args(func, args, kwargs) -> str:
    """Format function arguments for tracing (DEBUG=2)."""
    import inspect
    sig = inspect.signature(func)
    bound = sig.bind(*args, **kwargs)
    bound.apply_defaults()
    parts = []
    for name, value in bound.arguments.items():
        if name == "self":
            continue
        parts.append(f"{name}={_short_str(value)}")
    return ", ".join(parts)


def _count_args(args, kwargs) -> str:
    """Count arguments (DEBUG=1)."""
    parts = []
    if args:
        skip = 1 if any(
            hasattr(a, '__class__') and 'self' in str(a.__class__).lower()
            for a in args[:1]
        ) else 0
        real_args = args[skip:]
        if real_args:
            parts.append(f"{len(real_args)} positional")
    if kwargs:
        parts.append(f"{len(kwargs)} keyword")
    return ", ".join(parts) if parts else ""


def _short_str(obj, max_len: int = 80) -> str:
    """Short string representation for logging."""
    s = repr(obj)
    if len(s) > max_len:
        s = s[:max_len - 3] + "..."
    return s


# ── Convenience: check debug level from any module ────────────────────
def is_debug() -> bool:
    return _LEVEL >= 1


def is_trace() -> bool:
    return _LEVEL >= 2


def get_level() -> int:
    return _LEVEL
