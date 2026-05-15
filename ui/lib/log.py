"""Structured JSON logging for the Streamlit UI (stdout, one JSON object per line)."""

from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timezone
from typing import Any, TextIO


def _level_rank(level: str) -> int:
    return {"error": 0, "warn": 1, "warning": 1, "info": 2, "debug": 3}.get(level.lower(), 2)


def _min_level() -> int:
    raw = (os.environ.get("LOG_LEVEL_UI") or os.environ.get("LOG_LEVEL") or "info").lower().strip()
    return _level_rank(raw)


def _emit(level: str, msg: str, fields: dict[str, Any] | None = None, stream: TextIO | None = None) -> None:
    if _level_rank(level) > _min_level():
        return
    entry: dict[str, Any] = {
        "level": level.lower(),
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "msg": msg,
        "service": os.environ.get("OTEL_SERVICE_NAME", "mongodb-multiagent-ui"),
        "channel": "app",
    }
    if fields:
        entry.update(fields)
    line = json.dumps(entry, default=str)
    out = stream or (sys.stderr if level.lower() in ("error", "warn", "warning") else sys.stdout)
    out.write(line + "\n")
    out.flush()


def new_request_id() -> str:
    return f"req_{uuid.uuid4().hex[:12]}"


def debug(msg: str, **fields: Any) -> None:
    _emit("debug", msg, fields)


def info(msg: str, **fields: Any) -> None:
    _emit("info", msg, fields)


def warn(msg: str, **fields: Any) -> None:
    _emit("warn", msg, fields)


def error(msg: str, **fields: Any) -> None:
    _emit("error", msg, fields)
