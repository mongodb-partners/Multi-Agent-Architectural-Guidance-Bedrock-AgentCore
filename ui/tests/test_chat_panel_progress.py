"""Tests for chat_panel live progress labels."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib import chat_panel  # noqa: E402
from lib.api_client import TraceEvent  # noqa: E402
from lib.chat_panel import _trace_progress_badge  # noqa: E402


def _ev(event_type: str, payload: dict) -> TraceEvent:
    return TraceEvent(type=event_type, id="ev-1", ts=0, payload=payload)


def test_latency_checkpoint_maps_model_tool_selection() -> None:
    badge = _trace_progress_badge(
        _ev(
            "latency.checkpoint",
            {"name": "model.first_tool_call", "toolName": "mongodb_query"},
        )
    )

    assert badge is not None
    assert "MongoDB query" in badge


def test_mongo_query_maps_collection() -> None:
    badge = _trace_progress_badge(
        _ev("mongo.query", {"collection": "orders", "op": "findOne"})
    )

    assert badge is not None
    assert "`orders`" in badge


def test_mongo_result_includes_doc_count_and_latency() -> None:
    badge = _trace_progress_badge(
        _ev("mongo.result", {"status": "ok", "docCount": 1, "latencyMs": 42})
    )

    assert badge is not None
    assert "1 document" in badge
    assert "42 ms" in badge


def test_resolve_prompt_keeps_chat_input_mounted_for_queued_prompt(monkeypatch) -> None:
    session_state = {"pending_chat_input": "Where is my order #12345?"}
    calls: list[str] = []

    def chat_input(label: str) -> None:
        calls.append(label)
        return None

    monkeypatch.setattr(
        chat_panel,
        "st",
        SimpleNamespace(session_state=session_state, chat_input=chat_input),
    )

    assert chat_panel._resolve_prompt() == "Where is my order #12345?"
    assert calls == ["Message"]
    assert "pending_chat_input" not in session_state
