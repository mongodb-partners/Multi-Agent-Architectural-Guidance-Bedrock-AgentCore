"""Tests for Trace Viewer derived summary tiles."""

from __future__ import annotations

import ast
from contextlib import contextmanager
import inspect
import sys
from pathlib import Path
from typing import Any

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib import trace_view as trace_view_module  # noqa: E402
from lib.trace_view import (  # noqa: E402
    _VECTOR_SCORE_BINS,
    _nearest_vector_result_payload,
    _render_jsonish,
    _trace_events_dropped,
    _trace_is_truncated,
    _vector_document_previews,
    render_agentcore,
    render_developer_details,
    render_mongo_dashboard,
    render_mock_banner,
    render_summary_header,
    render_tool_calls,
    summary_tiles,
)


def _ev(t: str, payload: dict) -> dict:
    return {"type": t, "payload": payload, "id": f"{t}-1", "ts": 0}


class _StreamlitRecorder:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    def _record(self, name: str, *args: Any, **kwargs: Any) -> None:
        self.calls.append((name, args, kwargs))

    def json(self, *args: Any, **kwargs: Any) -> None:
        self._record("json", *args, **kwargs)

    def code(self, *args: Any, **kwargs: Any) -> None:
        self._record("code", *args, **kwargs)

    def info(self, *args: Any, **kwargs: Any) -> None:
        self._record("info", *args, **kwargs)

    def error(self, *args: Any, **kwargs: Any) -> None:
        self._record("error", *args, **kwargs)

    def warning(self, *args: Any, **kwargs: Any) -> None:
        self._record("warning", *args, **kwargs)

    def caption(self, *args: Any, **kwargs: Any) -> None:
        self._record("caption", *args, **kwargs)

    def markdown(self, *args: Any, **kwargs: Any) -> None:
        self._record("markdown", *args, **kwargs)

    def write(self, *args: Any, **kwargs: Any) -> None:
        self._record("write", *args, **kwargs)

    @contextmanager
    def expander(self, *args: Any, **kwargs: Any):
        self._record("expander", *args, **kwargs)
        yield self


def _json_values(recorder: _StreamlitRecorder) -> list[Any]:
    return [args[0] for name, args, _kwargs in recorder.calls if name == "json"]


def _info_values(recorder: _StreamlitRecorder) -> list[str]:
    return [args[0] for name, args, _kwargs in recorder.calls if name == "info"]


def _caption_values(recorder: _StreamlitRecorder) -> list[str]:
    return [args[0] for name, args, _kwargs in recorder.calls if name == "caption"]


def test_render_jsonish_handles_trimmed_markers_and_strings(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    monkeypatch.setattr(trace_view_module, "st", recorder)

    _render_jsonish({"a": 1})
    _render_jsonish([{"b": 2}])
    _render_jsonish('{"ok": true}')
    _render_jsonish('[{"x": 1}]')
    _render_jsonish("[trimmed 1234B]")
    _render_jsonish("plain text")
    _render_jsonish(42)

    json_values = _json_values(recorder)
    assert {"a": 1} in json_values
    assert [{"b": 2}] in json_values
    assert {"ok": True} in json_values
    assert [{"x": 1}] in json_values
    assert "[trimmed 1234B]" not in json_values

    caption_values = _caption_values(recorder)
    assert any("Large raw trace detail was shortened for display" in value and "1,234 bytes" in value for value in caption_values)

    code_values = [args[0] for name, args, _kwargs in recorder.calls if name == "code"]
    assert "plain text" in code_values
    assert "42" in code_values


def test_render_mongo_dashboard_does_not_json_parse_trimmed_sample_docs(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    monkeypatch.setattr(trace_view_module, "st", recorder)

    render_mongo_dashboard(
        [
            _ev("mongo.query", {"op": "find", "collection": "orders"}),
            _ev(
                "mongo.result",
                {
                    "status": "ok",
                    "docCount": 8,
                    "latencyMs": 14,
                    "sampleDocs": "[trimmed 2048B]",
                },
            ),
        ]
    )

    assert "[trimmed 2048B]" not in _json_values(recorder)

    assert any("Large raw trace detail was shortened for display" in value and "2,048 bytes" in value for value in _caption_values(recorder))


def test_render_tool_calls_does_not_json_parse_trimmed_payload_fields(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    monkeypatch.setattr(trace_view_module, "st", recorder)

    render_tool_calls(
        [
            {
                "type": "tool.call",
                "id": "tool-start",
                "ts": 0,
                "payload": {"phase": "start", "toolName": "lookup", "input": "[trimmed 1111B]"},
            },
            {
                "type": "tool.call",
                "id": "tool-end",
                "parentId": "tool-start",
                "ts": 1,
                "durationMs": 8,
                "payload": {"phase": "end", "toolName": "lookup", "result": "[trimmed 2222B]"},
            },
            _ev("tool.http", {"method": "POST", "url": "https://example.com", "status": 200, "body": "[trimmed 3333B]"}),
            _ev(
                "tool.mcp",
                {
                    "toolName": "mongodb_query",
                    "server": "mongodb-mcp",
                    "transport": "http",
                    "args": "[trimmed 4444B]",
                    "result": "[trimmed 5555B]",
                },
            ),
        ]
    )

    for marker in ("[trimmed 1111B]", "[trimmed 2222B]", "[trimmed 3333B]", "[trimmed 4444B]", "[trimmed 5555B]"):
        assert marker not in _json_values(recorder)
    for size in ("1,111 bytes", "2,222 bytes", "3,333 bytes", "4,444 bytes", "5,555 bytes"):
        assert any("Large raw trace detail was shortened for display" in value and size in value for value in _caption_values(recorder))


def test_render_agentcore_does_not_json_parse_trimmed_payload(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    monkeypatch.setattr(trace_view_module, "st", recorder)

    render_agentcore(
        [
            _ev(
                "agentcore.invoke",
                {
                    "mode": "api_to_runtime",
                    "targetAgentId": "product-recommendation",
                    "latencyMs": 12,
                    "responseBytes": 4096,
                    "payload": "[trimmed 6666B]",
                },
            )
        ]
    )

    assert "[trimmed 6666B]" not in _json_values(recorder)
    assert any("Large raw trace detail was shortened for display" in value and "6,666 bytes" in value for value in _caption_values(recorder))


def test_render_mongo_dashboard_handles_trimmed_vector_search_fields(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    monkeypatch.setattr(trace_view_module, "st", recorder)

    render_mongo_dashboard(
        [
            _ev(
                "mongo.vector_search",
                {
                    "collection": "products",
                    "embeddingSource": "voyage",
                    "scores": "[trimmed 1000B]",
                    "queryVectorPreview": "[trimmed 2000B]",
                    "filter": "[trimmed 3000B]",
                    "scoreSummary": "[trimmed 4000B]",
                    "histogram": "[trimmed 5000B]",
                },
            )
        ]
    )

    for marker in ("[trimmed 1000B]", "[trimmed 2000B]", "[trimmed 3000B]", "[trimmed 4000B]", "[trimmed 5000B]"):
        assert marker not in _json_values(recorder)
    for size in ("2,000 bytes", "3,000 bytes", "4,000 bytes", "5,000 bytes"):
        assert any("Large raw trace detail was shortened for display" in value and size in value for value in _caption_values(recorder))


def test_render_developer_details_passes_raw_events_as_structured_list(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    monkeypatch.setattr(trace_view_module, "st", recorder)
    trace = {
        "summary": {"eventsDropped": 1},
        "events": [_ev("mongo.result", {"sampleDocs": "[trimmed 7777B]"})],
    }

    render_developer_details(trace)

    json_values = _json_values(recorder)
    assert json_values == [trace["events"]]
    assert isinstance(json_values[0], list)


def test_trace_view_keeps_st_json_calls_in_known_safe_locations() -> None:
    tree = ast.parse(inspect.getsource(trace_view_module))
    scopes: list[str] = []
    calls: list[str] = []

    class Visitor(ast.NodeVisitor):
        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            scopes.append(node.name)
            self.generic_visit(node)
            scopes.pop()

        def visit_Call(self, node: ast.Call) -> None:
            if (
                isinstance(node.func, ast.Attribute)
                and node.func.attr == "json"
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "st"
            ):
                calls.append(scopes[-1] if scopes else "<module>")
            self.generic_visit(node)

    Visitor().visit(tree)

    assert calls == ["_render_jsonish", "_render_jsonish", "render_model_activity"]


def test_trace_truncation_warning_uses_root_and_summary_drop_flags(monkeypatch) -> None:
    assert _trace_is_truncated({"truncated": True, "summary": {}})
    assert _trace_events_dropped({"eventsDropped": 2, "summary": {"eventsDropped": 4}}) == 4
    assert _trace_is_truncated({"summary": {"eventsDropped": 1}})

    recorder = _StreamlitRecorder()
    monkeypatch.setattr(trace_view_module, "st", recorder)
    render_summary_header({"summary": {"eventsDropped": 2}, "events": []})

    warnings = [args[0] for name, args, _kwargs in recorder.calls if name == "warning"]
    assert any("byte-capped" in value and "2 event(s) dropped" in value for value in warnings)


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


def test_vector_document_previews_fall_back_to_nearest_result_sample_docs() -> None:
    vector_event = _ev(
        "mongo.vector_search",
        {"collection": "products", "embeddingSource": "mock", "scores": [0.9]},
    )
    events = [
        _ev(
            "mongo.result",
            {
                "status": "ok",
                "docCount": 1,
                "sampleDocs": [
                    {
                        "_id": "p1",
                        "sku": "SKU-1",
                        "name": "Compact Widget",
                        "source": "products",
                        "_score": 0.9,
                    }
                ],
            },
        ),
        vector_event,
    ]

    result_payload = _nearest_vector_result_payload(events, vector_event)
    previews = _vector_document_previews(vector_event["payload"], result_payload)

    assert previews[0]["collection"] == "products"
    assert previews[0]["title"] == "Compact Widget"
    assert previews[0]["sources"] == ["products"]
    assert previews[0]["score"] == 0.9


def test_vector_score_bins_have_explicit_titles() -> None:
    assert _VECTOR_SCORE_BINS == [
        "0.00-0.19",
        "0.20-0.39",
        "0.40-0.59",
        "0.60-0.79",
        "0.80-1.00",
    ]


def test_render_mock_banner_is_exported() -> None:
    assert callable(render_mock_banner)

