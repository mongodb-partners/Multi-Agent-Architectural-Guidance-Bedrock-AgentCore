"""Unit tests for api_client.py — SSE trace parsing + trace fetch helpers."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest  # noqa: F401

# Ensure ui/ root is on sys.path so `lib.api_client` resolves correctly.
_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.api_client import (  # noqa: E402
    AgentActiveEvent,
    DoneEvent,
    TokenEvent,
    TraceEvent,
    get_trace,
    get_trace_mongo,
    list_recent_traces,
    stream_chat_events,
)


# ---------------------------------------------------------------------------
# Helpers — fake requests.post / requests.get
# ---------------------------------------------------------------------------

def _sse_blob(*chunks: tuple[str, dict]) -> bytes:
    """Build a chunked SSE response body from (event, payload) pairs."""
    lines: list[str] = []
    for event, data in chunks:
        lines.append(f"event: {event}")
        lines.append("data: " + json.dumps(data))
        lines.append("")
    return ("\n".join(lines) + "\n").encode("utf-8")


class _FakeResp:
    def __init__(self, body: bytes, status: int = 200) -> None:
        self.status_code = status
        self._body = body
        self.encoding = "utf-8"

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def iter_lines(self, decode_unicode: bool = False):
        for line in self._body.decode("utf-8").split("\n"):
            yield line

    def __enter__(self) -> "_FakeResp":
        return self

    def __exit__(self, *_: object) -> None:
        return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestStreamChatTraceParsing:
    def test_emits_TraceEvent_for_event_trace(self) -> None:
        body = _sse_blob(
            (
                "trace",
                {
                    "type": "model.usage",
                    "id": "ev-1",
                    "ts": 1717100000000,
                    "parentId": None,
                    "agentId": "order-management",
                    "payload": {
                        "modelId": "anthropic.claude-haiku-4-5",
                        "inputTokens": 10,
                        "outputTokens": 20,
                        "totalTokens": 30,
                    },
                },
            ),
            ("token", {"text": "ok"}),
            ("done", {"sessionId": "s1", "messageId": "m1", "traceId": "trc-1"}),
        )

        with patch("lib.api_client.requests.post", return_value=_FakeResp(body)):
            events = list(stream_chat_events("http://api", "hi", "s1"))

        traces = [e for e in events if isinstance(e, TraceEvent)]
        assert len(traces) == 1
        t = traces[0]
        assert t.type == "model.usage"
        assert t.payload["inputTokens"] == 10
        assert t.agent_id == "order-management"

        done_events = [e for e in events if isinstance(e, DoneEvent)]
        assert len(done_events) == 1
        assert done_events[0].trace_id == "trc-1"

    def test_skips_trace_events_without_type(self) -> None:
        body = _sse_blob(
            ("trace", {"id": "ev-1", "ts": 1, "payload": {}}),
            ("token", {"text": "ok"}),
            ("done", {"sessionId": "s1"}),
        )
        with patch("lib.api_client.requests.post", return_value=_FakeResp(body)):
            events = list(stream_chat_events("http://api", "hi", "s1"))
        assert not any(isinstance(e, TraceEvent) for e in events)
        assert any(isinstance(e, TokenEvent) for e in events)

    def test_emits_agent_active_for_agent_info(self) -> None:
        body = _sse_blob(
            ("agent_info", {"agentId": "order-management", "agentName": "Order Management"}),
            ("token", {"text": "ok"}),
            ("done", {"sessionId": "s1"}),
        )
        with patch("lib.api_client.requests.post", return_value=_FakeResp(body)):
            events = list(stream_chat_events("http://api", "hi", "s1"))

        active = [e for e in events if isinstance(e, AgentActiveEvent)]
        assert len(active) == 1
        assert active[0].agent_id == "order-management"
        assert active[0].agent_name == "Order Management"


class TestGetTrace:
    def test_returns_payload_on_200(self) -> None:
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"traceId": "trc-1", "events": []}
        mock_resp.raise_for_status.return_value = None
        with patch("lib.api_client.requests.get", return_value=mock_resp):
            out = get_trace("http://api", trace_id="trc-1")
        assert out == {"traceId": "trc-1", "events": []}

    def test_returns_none_on_404(self) -> None:
        mock_resp = MagicMock()
        mock_resp.status_code = 404
        mock_resp.raise_for_status.return_value = None
        with patch("lib.api_client.requests.get", return_value=mock_resp):
            out = get_trace("http://api", trace_id="missing")
        assert out is None

    def test_uses_session_message_when_no_trace_id(self) -> None:
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"traceId": "trc-2"}
        mock_resp.raise_for_status.return_value = None
        with patch("lib.api_client.requests.get", return_value=mock_resp) as g:
            get_trace("http://api", session_id="s1", message_id="m1")
        url_called = g.call_args.args[0]
        assert "sessionId=s1" in url_called
        assert "messageId=m1" in url_called


class TestGetTraceMongo:
    def test_returns_payload_on_200(self) -> None:
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"traceId": "trc-1", "events": []}
        mock_resp.raise_for_status.return_value = None
        with patch("lib.api_client.requests.get", return_value=mock_resp) as g:
            out = get_trace_mongo("http://api", trace_id="trc-1")
        assert out is not None
        assert "trace/mongo" in g.call_args.args[0]


class TestListRecentTraces:
    def test_returns_traces_list(self) -> None:
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"traces": [{"traceId": "a"}, {"traceId": "b"}]}
        mock_resp.raise_for_status.return_value = None
        with patch("lib.api_client.requests.get", return_value=mock_resp):
            out = list_recent_traces("http://api", limit=10)
        assert [t["traceId"] for t in out] == ["a", "b"]
