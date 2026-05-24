"""Tests for session message normalization and trace enrichment."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.inline_summary import TurnSummary  # noqa: E402
from lib.session_messages import (  # noqa: E402
    _needs_trace_enrichment,
    enrich_messages_with_traces,
    load_session_messages,
    messages_from_session_api,
    normalize_session_message,
)


class TestNormalizeSessionMessage:
    def test_user_message_content_only(self) -> None:
        out = normalize_session_message({"role": "user", "content": "hi"})
        assert out == {"role": "user", "content": "hi"}
        assert "trace_id" not in out

    def test_preserves_message_id(self) -> None:
        out = normalize_session_message(
            {"role": "assistant", "content": "a", "id": "msg_1", "traceId": "t1"}
        )
        assert out and out["message_id"] == "msg_1"
        assert out["trace_id"] == "t1"

    def test_assistant_with_trace_id_camel_case(self) -> None:
        out = normalize_session_message(
            {
                "role": "assistant",
                "content": "hello",
                "traceId": "trc-abc",
            }
        )
        assert out is not None
        assert out["trace_id"] == "trc-abc"
        assert out["inline_summary"]["trace_id"] == "trc-abc"
        assert out["inline_summary"]["summary"].has_signal()

    def test_assistant_with_trace_id_snake_case(self) -> None:
        out = normalize_session_message(
            {"role": "assistant", "content": "x", "trace_id": "trc-2"}
        )
        assert out and out["trace_id"] == "trc-2"

    def test_skips_unknown_roles(self) -> None:
        assert normalize_session_message({"role": "system", "content": "x"}) is None

    def test_messages_from_session_api_filters_and_orders(self) -> None:
        rows = messages_from_session_api(
            [
                {"role": "user", "content": "q"},
                {"role": "assistant", "content": "a", "traceId": "t1"},
                {"role": "tool", "content": "ignored"},
            ]
        )
        assert len(rows) == 2
        assert rows[1]["trace_id"] == "t1"


class TestTraceEnrichment:
    def test_needs_enrichment_for_minimal_inline(self) -> None:
        msg = {
            "role": "assistant",
            "trace_id": "t1",
            "inline_summary": {
                "summary": TurnSummary(trace_id="t1"),
                "trace_id": "t1",
            },
        }
        assert _needs_trace_enrichment(msg)

    def test_skips_live_chat_summary(self) -> None:
        msg = {
            "role": "assistant",
            "trace_id": "t1",
            "inline_summary": {
                "summary": TurnSummary(trace_id="t1", total_tokens=100),
                "trace_id": "t1",
            },
        }
        assert not _needs_trace_enrichment(msg)

    @patch("lib.session_messages.get_trace")
    def test_enrich_fetches_by_trace_id(self, mock_get_trace) -> None:
        mock_get_trace.return_value = {
            "traceId": "trc-99",
            "events": [
                {
                    "id": "e1",
                    "ts": 0,
                    "type": "model.usage",
                    "payload": {
                        "modelId": "anthropic.claude-sonnet-4-5",
                        "inputTokens": 10,
                        "outputTokens": 5,
                        "totalTokens": 15,
                    },
                },
            ],
        }
        messages = [
            {
                "role": "assistant",
                "content": "hi",
                "message_id": "msg_9",
                "trace_id": "trc-99",
            },
        ]
        enrich_messages_with_traces("http://api", "sess_1", messages, "token")
        assert messages[0]["trace_id"] == "trc-99"
        assert messages[0]["trace_enriched"] is True
        assert messages[0]["inline_summary"]["summary"].total_tokens == 15
        mock_get_trace.assert_called_once_with(
            "http://api", trace_id="trc-99", access_token="token"
        )

    @patch("lib.session_messages.get_trace")
    def test_enrich_does_not_fetch_by_message_id(self, mock_get_trace) -> None:
        messages = [
            {"role": "assistant", "content": "hi", "message_id": "msg_9"},
        ]
        enrich_messages_with_traces("http://api", "sess_1", messages, "token")
        mock_get_trace.assert_not_called()
        assert "inline_summary" not in messages[0]

    @patch("lib.session_messages.enrich_messages_with_traces")
    @patch("lib.session_messages.messages_from_session_api")
    def test_load_session_messages_calls_enrich(
        self, mock_normalize, mock_enrich
    ) -> None:
        mock_normalize.return_value = [{"role": "assistant", "content": "x"}]
        out = load_session_messages("http://api", "sess_1", [], "tok")
        mock_enrich.assert_called_once_with(
            "http://api", "sess_1", mock_normalize.return_value, "tok"
        )
        assert out == mock_normalize.return_value
