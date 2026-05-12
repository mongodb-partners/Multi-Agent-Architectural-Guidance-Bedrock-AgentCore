"""Tests for demo_narratives.narrate — pure narrative generation."""

from __future__ import annotations

import sys
from pathlib import Path

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.demo_narratives import narrate  # noqa: E402


class TestNarrate:
    def test_empty_input_returns_empty(self) -> None:
        assert narrate([]) == []

    def test_routing_line_mentions_target_agent_and_trigger(self) -> None:
        events = [
            {
                "type": "handoff.decision",
                "payload": {
                    "toAgentId": "order-management",
                    "fromAgentId": "orchestrator",
                    "triggerSpans": [{"text": "order"}],
                },
            }
        ]
        lines = narrate(events)
        assert any("order-management" in line for line in lines)
        assert any("order" in line for line in lines)

    def test_mongo_line_mentions_counts(self) -> None:
        events = [
            {"type": "mongo.result", "payload": {"status": "ok"}},
            {"type": "mongo.result", "payload": {"status": "empty"}},
        ]
        lines = narrate(events)
        assert any("MongoDB" in line for line in lines)
        # Should mention 1 ok / 1 empty in some form (we just check totals).
        assert any("1" in line for line in lines)

    def test_error_line_emitted(self) -> None:
        events = [{"type": "error", "payload": {"class": "X", "message": "boom"}}]
        lines = narrate(events)
        assert any("error" in line.lower() for line in lines)

    def test_html_escape_on_trigger_text(self) -> None:
        events = [
            {
                "type": "handoff.decision",
                "payload": {
                    "toAgentId": "order-management",
                    "triggerSpans": [{"text": "<script>"}],
                },
            }
        ]
        lines = narrate(events)
        assert any("&lt;script&gt;" in line for line in lines)
        assert not any("<script>" in line for line in lines)
