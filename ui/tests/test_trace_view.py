"""Tests for Trace Viewer derived summary tiles."""

from __future__ import annotations

import sys
from pathlib import Path

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.trace_view import render_mock_banner, summary_tiles  # noqa: E402


def _ev(t: str, payload: dict) -> dict:
    return {"type": t, "payload": payload, "id": f"{t}-1", "ts": 0}


def test_summary_tiles_derive_chat_level_values_from_events() -> None:
    tiles = summary_tiles(
        {
            "summary": {
                "agentcoreHops": 1,
                "totalTokens": 42,
                "inputTokens": 30,
                "outputTokens": 12,
                "estimatedCostUsd": 0.0012,
                "costEstimateComplete": True,
            },
            "events": [
                _ev("chat.turn.end", {"durationMs": 20540}),
                _ev("agentcore.invoke", {"latencyMs": 0}),
                _ev("agentcore.invoke", {"latencyMs": 20539}),
                _ev("memory.long_term_write", {"docsInserted": 1, "primaryOutcome": "persisted"}),
                _ev("mongo.result", {"status": "ok", "docCount": 3}),
            ],
        }
    )
    html = "".join(tiles)

    assert "Latency" in html
    assert "20.54s" in html
    assert "AgentCore" in html
    assert "2 hops" in html
    assert "Memory" in html
    assert "1 stored" in html
    assert "MongoDB" in html
    assert "1/1 ok" in html
    assert "Tokens" in html
    assert "42" in html
    assert "Cost" in html


def test_summary_tiles_show_memory_skip_and_errors() -> None:
    tiles = summary_tiles(
        {
            "summary": {},
            "events": [
                _ev("memory.long_term_skip", {"reason": "no_fact_candidates"}),
                _ev("agentcore.invoke", {"errorMessage": "boom"}),
                _ev("error", {"message": "boom"}),
            ],
        }
    )
    html = "".join(tiles)

    assert "Skipped" in html
    assert "no_fact_candidates" in html
    assert "Errors" in html
    assert "2" in html


def test_summary_tiles_show_vector_search_only_mongodb_activity() -> None:
    tiles = summary_tiles(
        {
            "summary": {},
            "events": [
                _ev("mongo.vector_search", {"embeddingSource": "mock", "scores": [0.9, 0.7]}),
            ],
        }
    )
    html = "".join(tiles)

    assert "MongoDB" in html
    assert "1 vector search" in html
    assert "2 hit(s)" in html


def test_render_mock_banner_is_exported() -> None:
    assert callable(render_mock_banner)

