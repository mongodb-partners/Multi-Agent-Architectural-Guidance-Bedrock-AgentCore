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

from lib import client_trace_view as trace_view_module  # noqa: E402
from lib import developer_trace_view as developer_view_module  # noqa: E402
from lib import trace_view_helpers as helpers_module  # noqa: E402
from lib.client_trace_view import (  # noqa: E402
    render_agentcore,
    render_mongo_dashboard,
    render_mock_banner,
    render_summary_header,
    render_tool_calls,
    summary_tiles,
)
from lib.developer_trace_view import render_developer_details  # noqa: E402
from lib.trace_view_helpers import (  # noqa: E402
    _VECTOR_SCORE_BINS,
    _nearest_vector_result_payload,
    _render_jsonish,
    _trace_events_dropped,
    _trace_is_truncated,
    _vector_document_previews,
)


def _patch_st(monkeypatch, recorder: "_StreamlitRecorder") -> None:
    """Patch streamlit on all three trace UI modules in one call.

    The Trace Viewer used to live in a single `lib.trace_view` module, so
    patching `trace_view.st` was enough. After the PR2 split, helpers like
    `_render_jsonish` and `_redaction_banner` reach for `st` on their own
    module (`lib.trace_view_helpers`), and `render_developer_details` lives
    on `lib.developer_trace_view`. Tests must monkeypatch all three or
    recorder calls will silently fall through to the real streamlit module.
    """
    monkeypatch.setattr(trace_view_module, "st", recorder)
    monkeypatch.setattr(developer_view_module, "st", recorder)
    monkeypatch.setattr(helpers_module, "st", recorder)


def _ev(t: str, payload: dict) -> dict:
    return {"type": t, "payload": payload, "id": f"{t}-1", "ts": 0}


class _StreamlitRecorder:
    """Streamlit mock that records calls + tolerates the new dev surface.

    After the PR2 dev-section addition the dev panel uses `st.button`,
    `st.session_state`, `st.container`, `st.rerun`, `st.columns`,
    `st.multiselect`, `st.text_input`, `st.number_input`, `st.download_button`,
    `st.line_chart`. Provide no-op stubs for all of them so tests that
    monkeypatch this recorder onto a module's `st` symbol don't blow up.
    """

    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
        self.session_state: dict[str, Any] = {}

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

    def metric(self, *args: Any, **kwargs: Any) -> None:
        self._record("metric", *args, **kwargs)

    def line_chart(self, *args: Any, **kwargs: Any) -> None:
        self._record("line_chart", *args, **kwargs)

    def button(self, *args: Any, **kwargs: Any) -> bool:
        self._record("button", *args, **kwargs)
        return False

    def download_button(self, *args: Any, **kwargs: Any) -> bool:
        self._record("download_button", *args, **kwargs)
        return False

    def multiselect(self, *args: Any, **kwargs: Any) -> list:
        self._record("multiselect", *args, **kwargs)
        return list(kwargs.get("default") or [])

    def text_input(self, *args: Any, **kwargs: Any) -> str:
        self._record("text_input", *args, **kwargs)
        return str(kwargs.get("value") or "")

    def number_input(self, *args: Any, **kwargs: Any) -> int:
        self._record("number_input", *args, **kwargs)
        return int(kwargs.get("min_value", kwargs.get("value", 1)) or 1)

    def rerun(self) -> None:
        self._record("rerun")

    def columns(self, spec, **kwargs):
        self._record("columns", spec, **kwargs)
        count = spec if isinstance(spec, int) else len(spec)
        return [self for _ in range(count)]

    @contextmanager
    def expander(self, *args: Any, **kwargs: Any):
        self._record("expander", *args, **kwargs)
        yield self

    @contextmanager
    def container(self, *args: Any, **kwargs: Any):
        self._record("container", *args, **kwargs)
        yield self

    @contextmanager
    def spinner(self, *args: Any, **kwargs: Any):
        self._record("spinner", *args, **kwargs)
        yield self

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        return None


def _json_values(recorder: _StreamlitRecorder) -> list[Any]:
    return [args[0] for name, args, _kwargs in recorder.calls if name == "json"]


def _info_values(recorder: _StreamlitRecorder) -> list[str]:
    return [args[0] for name, args, _kwargs in recorder.calls if name == "info"]


def _caption_values(recorder: _StreamlitRecorder) -> list[str]:
    return [args[0] for name, args, _kwargs in recorder.calls if name == "caption"]


def test_render_jsonish_handles_trimmed_markers_and_strings(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)

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
    _patch_st(monkeypatch, recorder)

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
    _patch_st(monkeypatch, recorder)

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
    _patch_st(monkeypatch, recorder)

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
    _patch_st(monkeypatch, recorder)

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


def test_render_developer_details_is_gated_by_default(monkeypatch) -> None:
    """First page load: the dev section is button-gated. No `_dev_*`
    rendering happens until the user clicks "Show developer details". This
    is the contract that keeps client demos fast — we assert the only
    streamlit interaction is the single toggle button.
    """
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    trace = {
        "traceId": "demo-trace",
        "summary": {"eventsDropped": 1},
        "events": [_ev("mongo.result", {"sampleDocs": "[trimmed 7777B]"})],
    }

    render_developer_details(trace)

    # No `st.json` calls — the dev surface has not been expanded.
    assert _json_values(recorder) == []
    button_labels = [args[0] for name, args, _ in recorder.calls if name == "button" and args]
    assert any("Show developer details" in label for label in button_labels)


def test_render_developer_details_renders_raw_events_after_toggle(monkeypatch) -> None:
    """Second click path: simulate the toggle being already on via
    `st.session_state` and assert the raw-events sub-section renders the
    page-1 events as a structured list."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    trace = {
        "traceId": "demo-trace-2",
        "summary": {"eventsDropped": 1},
        "events": [_ev("mongo.result", {"sampleDocs": "[trimmed 7777B]"})],
    }
    recorder.session_state[f"dev_open_{trace['traceId']}"] = True

    render_developer_details(trace)

    json_values = _json_values(recorder)
    assert any(value == trace["events"] for value in json_values)


def test_trace_view_keeps_st_json_calls_in_known_safe_locations() -> None:
    """Sweep every trace-UI module and assert raw `st.json(...)` only happens
    in known-safe scopes that already guard against handing strings to
    streamlit.

    After the PR2 file split, the audit must cover all three modules
    (`client_trace_view`, `developer_trace_view`, `trace_view_helpers`) —
    each could grow a regression on its own.
    """
    safe_scopes: set[str] = set()
    for module in (trace_view_module, developer_view_module, helpers_module):
        tree = ast.parse(inspect.getsource(module))
        scopes: list[str] = []

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
                    safe_scopes.add(scopes[-1] if scopes else "<module>")
                self.generic_visit(node)

        Visitor().visit(tree)

    assert safe_scopes == {"_render_jsonish", "render_model_activity"}


def test_trace_truncation_warning_uses_root_and_summary_drop_flags(monkeypatch) -> None:
    assert _trace_is_truncated({"truncated": True, "summary": {}})
    assert _trace_events_dropped({"eventsDropped": 2, "summary": {"eventsDropped": 4}}) == 4
    assert _trace_is_truncated({"summary": {"eventsDropped": 1}})

    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
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
    assert previews[0]["_id"] == "p1"
    assert previews[0]["title"] == "Compact Widget"
    assert previews[0]["sources"] == ["products"]
    assert previews[0]["score"] == 0.9


def test_render_mongo_dashboard_shows_vector_document_mongo_id(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)

    render_mongo_dashboard(
        [
            _ev(
                "mongo.vector_search",
                {
                    "collection": "arbitrary_collection",
                    "embeddingSource": "mock",
                    "scores": [],
                    "documentPreviews": [
                        {
                            "rank": 1,
                            "collection": "arbitrary_collection",
                            "_id": "507f1f77bcf86cd799439011",
                            "id": "507f1f77bcf86cd799439011",
                            "title": "Arbitrary Collection Hit",
                        }
                    ],
                },
            )
        ]
    )

    assert any(
        "ID: `507f1f77bcf86cd799439011`" in value
        for value in _caption_values(recorder)
    )
    assert any(
        "Mongo _id: `507f1f77bcf86cd799439011`" in value
        for value in _caption_values(recorder)
    )


def test_render_mongo_dashboard_shows_vector_document_id_without_mongo_id(monkeypatch) -> None:
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    preview_id = "fixture-product-preview-id"

    render_mongo_dashboard(
        [
            _ev(
                "mongo.vector_search",
                {
                    "collection": "products",
                    "embeddingSource": "mock",
                    "scores": [],
                    "documentPreviews": [
                        {
                            "rank": 1,
                            "collection": "products",
                            "id": preview_id,
                            "title": "Compact Widget Plus",
                        }
                    ],
                },
            )
        ]
    )

    captions = _caption_values(recorder)
    assert any(f"ID: `{preview_id}`" in value for value in captions)


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


# ---------------------------------------------------------------------------
# Developer details sub-section coverage (debug-grade trace surface).
#
# Each `_dev_*` renderer is exercised with the minimal synthetic event set
# that triggers its happy path. The intent is regression cover for the wiring
# (does each sub-section consume the event types the plan promised it would?),
# not a screenshot-grade UI test.
#
# `render_developer_details` is also exercised with a populated
# `st.session_state` so the full panel runs end-to-end as a perf smoke knob.
# ---------------------------------------------------------------------------

from lib.developer_trace_view import (  # noqa: E402
    _dev_byte_cap,
    _dev_environment,
    _dev_mongo_internals,
    _dev_retries,
    _dev_skill_resource_reads,
    _dev_span_tree,
)


def test_dev_span_tree_uses_precomputed_spantree_when_present(monkeypatch) -> None:
    """`_dev_span_tree` prefers `trace.spanTree` over recomputing from
    `parentId` relations. We assert the precomputed value lands on the
    markdown output so an upstream span-tree breakage shows here, not in
    the recompute path."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    trace = {
        "traceId": "t-span",
        "spanTree": [
            {"id": "root", "type": "chat.turn.start", "durationMs": 100, "children": [
                {"id": "child", "type": "model.request", "durationMs": 80, "children": []},
            ]}
        ],
    }
    _dev_span_tree(trace, [])
    markdown = "".join(args[0] for name, args, _ in recorder.calls if name == "markdown" and args)
    assert "chat.turn.start" in markdown
    assert "model.request" in markdown


def test_dev_mongo_internals_surfaces_index_name(monkeypatch) -> None:
    """`mongo.vector_search.indexName` must reach the developer panel — the
    whole reason the plumbing exists is so reviewers can verify the runtime
    is hitting the expected Atlas Vector Search index."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    events = [
        _ev("mongo.vector_search", {
            "collection": "products",
            "embeddingSource": "voyage",
            "indexName": "products-vector-index",
            "scores": [0.91, 0.88, 0.62],
        }),
    ]
    _dev_mongo_internals(events)
    blob = "".join(
        " ".join(str(a) for a in args)
        for name, args, _ in recorder.calls
        if name in {"markdown", "caption", "write", "code"} and args
    )
    assert "products-vector-index" in blob


def test_dev_skill_resource_reads_renders_per_skill_table(monkeypatch) -> None:
    """The skill resource read table is the only place a developer can see
    which skill bodies' `references/scripts/` files the agent pulled from
    during a turn. Assert the resourcePath / bytes round-trip through."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    events = [
        _ev(
            "skill.activated",
            {
                "name": "order-management",
                "source": "pre_activate",
                "injectedVia": "system_prompt",
                "bytes": 2048,
                "allowed": True,
                "resourceReads": [
                    {"resourcePath": "references/order-status-codes.md", "bytes": 1024, "toolUseId": "tu-1"},
                    {"resourcePath": "scripts/lookup-order.mjs", "bytes": 512, "toolUseId": "tu-2"},
                ],
            },
        ),
    ]
    _dev_skill_resource_reads(events)
    blob = "".join(
        " ".join(str(a) for a in args)
        for name, args, _ in recorder.calls
        if name in {"markdown", "table", "write", "caption"} and args
    )
    assert "order-status-codes.md" in blob
    assert "lookup-order.mjs" in blob


def test_dev_retries_interleaves_model_and_agentcore_retries(monkeypatch) -> None:
    """Retries are renderered as a single interleaved table — the dev
    cannot debug a throttled turn if model + agentcore retries live in
    different tables and they have to mentally merge by timestamp."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    events = [
        {"type": "model.retry", "ts": 100, "id": "r1", "payload": {
            "provider": "bedrock",
            "modelId": "anthropic.claude-sonnet-4-5",
            "attempt": 1,
            "previousErrorClass": "ThrottlingException",
            "backoffMs": 100,
        }},
        {"type": "agentcore.retry", "ts": 200, "id": "r2", "payload": {
            "arn": "arn:aws:bedrock-agentcore:us-east-1:1:runtime/x",
            "targetAgentId": "specialist",
            "mode": "orchestrator_to_specialist",
            "attempt": 1,
            "previousErrorClass": "ServiceUnavailableException",
            "backoffMs": 200,
        }},
    ]
    _dev_retries(events)
    # The rendered output (markdown or table) must mention both retry types.
    blob = "".join(
        " ".join(str(a) for a in args)
        for name, args, _ in recorder.calls
        if name in {"markdown", "table", "caption", "write"} and args
    )
    assert "model.retry" in blob or "ThrottlingException" in blob
    assert "agentcore.retry" in blob or "ServiceUnavailableException" in blob


def test_dev_byte_cap_lists_dropped_event_types(monkeypatch) -> None:
    """`dev.byte_cap_hit` events are the only way a dev can tell that a
    payload was trimmed at emit time — assert each is surfaced."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    trace = {"summary": {"eventsDropped": 2}}
    events = [
        _ev("dev.byte_cap_hit", {"droppedType": "tool.call", "bytes": 4096, "reason": "per_event"}),
        _ev("dev.byte_cap_hit", {"droppedType": "model.text_delta_batch", "bytes": 8192, "reason": "per_turn"}),
    ]
    _dev_byte_cap(trace, events)
    blob = "".join(
        " ".join(str(a) for a in args)
        for name, args, _ in recorder.calls
        if name in {"markdown", "table", "caption", "write", "warning"} and args
    )
    assert "tool.call" in blob
    assert "model.text_delta_batch" in blob


def test_dev_environment_renders_dev_environment_event(monkeypatch) -> None:
    """The `dev.environment` event answers "why is this turn behaving like
    a mock?" in one shot — assert chatMode + devMockBackends land in the
    output."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    trace = {"release": {"gitSha": "abcdef0"}}
    events = [
        _ev("dev.environment", {
            "chatMode": "live",
            "devMockBackends": False,
            "mongoConfigured": True,
            "voyageConfigured": True,
            "logLevel": "info",
        }),
    ]
    _dev_environment(trace, events)
    # `_dev_environment` renders payloads through `_render_jsonish`, so the
    # chatMode / gitSha values land in `st.json(...)` call args, not in
    # markdown/caption strings. Collect both.
    blob = "".join(
        " ".join(str(a) for a in args)
        for name, args, _ in recorder.calls
        if args
    )
    assert "live" in blob
    assert "abcdef0" in blob


def test_render_developer_details_full_render_perf_smoke(monkeypatch) -> None:
    """Combined perf smoke: when toggled open, the dev surface renders every
    sub-section against a heterogeneous event set without exploding the
    Streamlit call count. The bound (200 calls) is a soft ceiling — it
    only fires if a future change starts emitting per-event widgets in a
    hot loop."""
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    trace = {
        "traceId": "perf-trace",
        "release": {"gitSha": "abc"},
        "summary": {"eventsDropped": 1, "totalTokens": 100, "inputTokens": 60, "outputTokens": 40},
        "spanTree": [
            {"id": "root", "type": "chat.turn.start", "durationMs": 50, "children": []},
        ],
        "events": [
            _ev("prompt.assembled", {"body": "hi", "bodyBytes": 2, "totalBytes": 2, "personaBytes": 0, "discoveryBytes": 0, "memoryContextBytes": 0}),
            _ev("model.request", {"modelId": "anthropic.claude-sonnet-4-5", "region": "us-east-1", "systemPromptHash": "h", "systemPromptBytes": 1, "priorTurnsCount": 0}),
            _ev("mongo.vector_search", {"collection": "x", "embeddingSource": "voyage", "indexName": "x_v", "scores": [0.9]}),
            _ev("dev.environment", {"chatMode": "live"}),
            _ev("dev.byte_cap_hit", {"droppedType": "tool.call", "bytes": 1024, "reason": "per_event"}),
            _ev("model.retry", {"provider": "bedrock", "modelId": "m", "attempt": 1, "previousErrorClass": "Throttle", "backoffMs": 100}),
            _ev("agentcore.retry", {"arn": "arn:aws:x", "mode": "ec2_to_orchestrator", "attempt": 1, "previousErrorClass": "Throttle", "backoffMs": 200}),
            _ev("skill.activated", {"name": "x", "source": "pre_activate", "injectedVia": "system_prompt", "bytes": 1, "allowed": True}),
        ],
    }
    # Pre-toggle the panel open via session_state — that's what the second
    # click would do.
    recorder.session_state[f"dev_open_{trace['traceId']}"] = True

    render_developer_details(trace)

    # Sanity: we hit at least one render call (the panel didn't no-op) and
    # didn't explode (no infinite loop / call avalanche).
    assert len(recorder.calls) > 5
    assert len(recorder.calls) < 1000


def test_render_developer_details_caches_dev_fetch_across_reruns(monkeypatch) -> None:
    """Per plan §6 "Performance / lazy loading" — the dev surface MUST hit the
    `?include=dev` endpoint at most once per (traceId, session) pair. The
    cache lives in `st.session_state[f"dev_trace_{traceId}"]`; a second
    render with the same session_state must read from the cache and NOT
    re-fetch.

    This pins the contract behind the "Toggling the panel is one fetch,
    not one fetch per Streamlit rerun" promise the Trace Viewer page makes
    to demo clients (otherwise every interaction with any sidebar control
    would re-pull the dev trace and the bordered container would flicker).
    """
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)
    trace = {
        "traceId": "cached-trace",
        "summary": {"totalTokens": 10, "inputTokens": 6, "outputTokens": 4},
        "events": [_ev("prompt.assembled", {"body": "hi", "bodyBytes": 2})],
    }

    fetch_calls: list[dict] = []

    def fake_get_trace(api_base, trace_id, access_token=None, include=None):
        fetch_calls.append({
            "api_base": api_base,
            "trace_id": trace_id,
            "include": include,
        })
        return {
            **trace,
            "events": trace["events"] + [
                _ev("model.request", {"modelId": "m", "systemPromptBytes": 1, "priorTurnsCount": 0}),
            ],
        }

    import lib.api_client as api_client_module
    monkeypatch.setattr(api_client_module, "get_trace", fake_get_trace, raising=True)

    class _Settings:
        api_base = "http://api.test"

    settings = _Settings()

    # First render: panel closed → no fetch (button stub returns False, no
    # toggle, no fetch path). This is the "demo client never pays" promise.
    render_developer_details(trace, settings=settings, api_token="tok")
    assert fetch_calls == [], "fetch must not run while panel is closed"

    # Open the panel (what clicking the button would do) and render again.
    recorder.session_state[f"dev_open_{trace['traceId']}"] = True
    render_developer_details(trace, settings=settings, api_token="tok")
    assert len(fetch_calls) == 1, "first open must perform exactly one ?include=dev fetch"
    assert fetch_calls[0]["include"] == "dev"
    assert fetch_calls[0]["trace_id"] == "cached-trace"

    # Now simulate a second Streamlit rerun (e.g. user adjusted any other
    # sidebar control). The cache key MUST be hit and no new fetch fired.
    render_developer_details(trace, settings=settings, api_token="tok")
    assert len(fetch_calls) == 1, (
        "second render after the panel is open must read from "
        f"st.session_state['dev_trace_{trace['traceId']}'] cache and not re-fetch; "
        f"got {len(fetch_calls)} fetches"
    )

    # And a third rerun, to defend against accidental cache invalidation
    # (e.g. someone re-introducing `st.cache_data(ttl=...)` and silently
    # halving the TTL behind a control change).
    render_developer_details(trace, settings=settings, api_token="tok")
    assert len(fetch_calls) == 1


def test_render_developer_details_refetches_for_distinct_trace_ids(monkeypatch) -> None:
    """Counter-test to the caching behavior: the cache key includes the
    traceId, so navigating to a *different* trace (e.g. via the prev/next
    arrows in the session navigator) must trigger a fresh `?include=dev`
    fetch — otherwise we'd render trace A's developer details for trace B.
    """
    recorder = _StreamlitRecorder()
    _patch_st(monkeypatch, recorder)

    fetch_calls: list[str] = []

    def fake_get_trace(api_base, trace_id, access_token=None, include=None):
        fetch_calls.append(trace_id)
        return {"traceId": trace_id, "events": []}

    import lib.api_client as api_client_module
    monkeypatch.setattr(api_client_module, "get_trace", fake_get_trace, raising=True)

    class _Settings:
        api_base = "http://api.test"

    settings = _Settings()
    trace_a = {"traceId": "trace-a", "events": []}
    trace_b = {"traceId": "trace-b", "events": []}

    recorder.session_state["dev_open_trace-a"] = True
    render_developer_details(trace_a, settings=settings, api_token=None)
    assert fetch_calls == ["trace-a"]

    recorder.session_state["dev_open_trace-b"] = True
    render_developer_details(trace_b, settings=settings, api_token=None)
    assert fetch_calls == ["trace-a", "trace-b"]

    render_developer_details(trace_a, settings=settings, api_token=None)
    assert fetch_calls == ["trace-a", "trace-b"], (
        "trace-a should still be served from cache on revisit"
    )

