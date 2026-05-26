"""Fixture-driven smoke tests for the debug-grade LTM trace section.

These run `render_memory(events)` against each of the four LTM trace fixtures
under `ui/tests/fixtures/` with a Streamlit mock and assert that the new
telemetry (header tiles, redaction banner, per-collection table, write
outcome, skip reason, related-context links) lands in the expected
Streamlit call surface.

The goal is to catch shape/format regressions without booting Streamlit.
"""

from __future__ import annotations

import json
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import pytest

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib import client_trace_view as trace_view_module  # noqa: E402
from lib import developer_trace_view as developer_view_module  # noqa: E402
from lib import trace_view_helpers as helpers_module  # noqa: E402
from lib.client_trace_view import (  # noqa: E402
    render_memory,
    summary_tiles,
)
from lib.developer_trace_view import _dev_memory_internals  # noqa: E402
from lib.trace_view_helpers import (  # noqa: E402
    _any_redacted,
    _human_skip_reason,
    _is_redacted,
    _resolve_user_message_for_write,
)


def _patch_st(monkeypatch, recorder) -> None:
    """Patch streamlit on the client-facing module, the developer module,
    and the helpers module so memory renderers and their underlying
    `_render_jsonish` / `_redaction_banner` helpers all route calls
    through the recorder.

    `_dev_memory_internals` lives in `developer_trace_view`; the per-
    collection table, candidates table, extractor diagnostics, and live
    `MEMORY_*` env knobs that this test asserts on now render through that
    module after the PR2 memory split.
    """
    monkeypatch.setattr(trace_view_module, "st", recorder)
    monkeypatch.setattr(developer_view_module, "st", recorder)
    monkeypatch.setattr(helpers_module, "st", recorder)


_FIXTURES = Path(__file__).resolve().parent / "fixtures"


class _Recorder:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    def _record(self, name: str, *args: Any, **kwargs: Any) -> None:
        self.calls.append((name, args, kwargs))

    def __getattr__(self, name: str):
        def _proxy(*args: Any, **kwargs: Any) -> None:
            self._record(name, *args, **kwargs)
        return _proxy

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        return None

    def columns(self, spec, **_kwargs):
        count = spec if isinstance(spec, int) else len(spec)
        return [self for _ in range(count)]

    @contextmanager
    def expander(self, *args: Any, **kwargs: Any):
        self._record("expander", *args, **kwargs)
        yield self


def _all_text(recorder: _Recorder) -> str:
    chunks: list[str] = []
    for name, args, _kwargs in recorder.calls:
        for a in args:
            if isinstance(a, str):
                chunks.append(a)
    return "\n".join(chunks)


def _load(name: str) -> dict:
    return json.loads((_FIXTURES / name).read_text())


# ── pure helpers ────────────────────────────────────────────────────────────


def test_is_redacted_handles_only_exact_placeholder() -> None:
    assert _is_redacted("<redacted>")
    assert not _is_redacted("<redacted!>")
    assert not _is_redacted("")
    assert not _is_redacted(None)
    assert not _is_redacted(["<redacted>"])


def test_any_redacted_detects_facts_query_candidates_and_extracted() -> None:
    assert _any_redacted([
        {"type": "memory.scoped_read", "payload": {"queryText": "<redacted>"}},
    ])
    assert _any_redacted([
        {"type": "memory.scoped_read", "payload": {"facts": ["ok", "<redacted>"]}},
    ])
    assert _any_redacted([
        {"type": "memory.long_term_write", "payload": {"factCandidates": [{"text": "<redacted>"}]}},
    ])
    assert _any_redacted([
        {"type": "memory.long_term_write", "payload": {"factsExtracted": ["<redacted>"]}},
    ])
    assert not _any_redacted([
        {"type": "memory.scoped_read", "payload": {"queryText": "hi"}},
    ])


def test_human_skip_reason_covers_known_reasons_and_falls_back() -> None:
    assert "long-term memory writes require a JWT" in _human_skip_reason("no_user_id")
    assert "Agent has `memory.longTerm: false`" in _human_skip_reason("agent_memory_disabled")
    assert "MongoDB was unreachable" in _human_skip_reason("mongodb_unavailable")
    assert "extractor model errored" in _human_skip_reason("llm_extractor_failed")
    assert "Write skipped — `unheard_of`" in _human_skip_reason("unheard_of")


def test_resolve_user_message_prefers_model_request_before_write_ts() -> None:
    events = [
        {"type": "model.request", "ts": 100, "payload": {"userMessage": "earlier prompt"}},
        {"type": "model.request", "ts": 200, "payload": {"userMessage": "right before write"}},
        {"type": "memory.long_term_write", "ts": 250, "payload": {}},
        {"type": "model.request", "ts": 300, "payload": {"userMessage": "after — should be ignored"}},
    ]
    write = events[2]
    label, source = _resolve_user_message_for_write(events, write)
    assert "right before write" in label
    assert "model.request.userMessage" in source


def test_resolve_user_message_falls_back_to_read_query_text_when_not_redacted() -> None:
    events = [
        {"type": "memory.scoped_read", "ts": 50, "payload": {"queryText": "my real query"}},
        {"type": "memory.long_term_write", "ts": 100, "payload": {}},
    ]
    label, source = _resolve_user_message_for_write(events, events[1])
    assert "my real query" in label
    assert "fallback" in source


def test_resolve_user_message_returns_sentinel_when_only_redacted_read_present() -> None:
    events = [
        {"type": "memory.scoped_read", "ts": 50, "payload": {"queryText": "<redacted>"}},
        {"type": "memory.long_term_write", "ts": 100, "payload": {}},
    ]
    label, source = _resolve_user_message_for_write(events, events[1])
    assert "not in trace" in label
    assert source == "no source available"


# ── fixture smoke tests ─────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "fixture_name",
    [
        "ltm_trace_read_redacted.json",
        "ltm_trace_read_raw.json",
        "ltm_trace_write_success.json",
        "ltm_trace_skip_no_facts.json",
    ],
)
def test_render_memory_does_not_raise_on_fixture(monkeypatch, fixture_name: str) -> None:
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load(fixture_name)
    render_memory(trace["events"])
    section_titles = [
        args[0]
        for name, args, _kwargs in recorder.calls
        if name == "markdown" and args and isinstance(args[0], str) and "Long-term memory" in args[0]
    ]
    assert section_titles, f"section title not rendered for {fixture_name}"


def test_render_memory_emits_redaction_banner_only_when_redacted(monkeypatch) -> None:
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_read_redacted.json")
    render_memory(trace["events"])
    info_calls = [args[0] for name, args, _kwargs in recorder.calls if name == "info"]
    assert any("redacted in this trace" in s for s in info_calls)

    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_read_raw.json")
    render_memory(trace["events"])
    info_calls = [args[0] for name, args, _kwargs in recorder.calls if name == "info"]
    assert not any("redacted in this trace" in s for s in info_calls)


def test_dev_memory_internals_renders_per_collection_dev_table_with_error_column(monkeypatch) -> None:
    """Per-collection breakdown moved out of the client-facing
    `render_memory` (where it was a markdown table without latency split)
    into `_dev_memory_internals`, where it gains `Embed ms` + `Search ms`
    columns. Asserting on the dev module guarantees the table did not
    disappear when we slimmed the client panel."""
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_read_raw.json")
    _dev_memory_internals(trace["events"])
    text = _all_text(recorder)
    assert "| Collection | Vector | Lexical | Embed ms | Search ms | Error |" in text
    assert "agent_memory_facts" in text
    assert "chat_messages" in text


def test_render_memory_keeps_per_collection_pointer_caption(monkeypatch) -> None:
    """The client panel no longer renders the per-collection table itself —
    it must still point developers at the Developer details section so the
    information is discoverable from the demo surface."""
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_read_raw.json")
    render_memory(trace["events"])
    text = _all_text(recorder)
    # Old client table is gone …
    assert "| Collection | Vector | Lexical | Error |" not in text
    # … but the pointer caption tells the dev where to find it.
    assert "Developer details" in text and "Long-term memory internals" in text


def test_render_memory_write_surfaces_outcome_extractor_and_user_input(monkeypatch) -> None:
    """Client-facing write card still owns the outcome chip, extractor
    one-liner, embedding line, and user-input source. The candidates table
    + "200 Pine St" candidate text moved to `_dev_memory_internals` (see
    its own test below)."""
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_write_success.json")
    render_memory(trace["events"])
    text = _all_text(recorder)
    assert "Long-term write" in text
    assert "persisted" in text
    assert "1 inserted" in text
    assert "1 dup skipped" in text
    assert "entries 11 \u2192 12" in text
    assert "model `us.anthropic.claude-3-7-sonnet-20250219-v1:0`" in text
    assert "accepted 2/4" in text
    assert "voyage-3" in text
    # Pointer caption to the moved candidates table.
    assert "Developer details" in text and "Long-term memory internals" in text


def test_dev_memory_internals_renders_full_candidates_table_with_rejected_reasons(monkeypatch) -> None:
    """The "All candidates considered" expander moved from summary → dev.
    Assert its body (matched candidate text + rejected reasons) lands in
    the recorder when `_dev_memory_internals` is called."""
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_write_success.json")
    _dev_memory_internals(trace["events"])
    text = _all_text(recorder)
    assert "All candidates considered" in text
    assert "200 Pine St" in text


def test_render_memory_skip_surfaces_reason_and_user_excerpt(monkeypatch) -> None:
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_skip_no_facts.json")
    render_memory(trace["events"])
    text = _all_text(recorder)
    assert "Write skipped" in text
    assert "Extractor found no candidate facts" in text
    assert "hi" in text


def test_render_memory_related_expander_includes_auth_and_prompt(monkeypatch) -> None:
    recorder = _Recorder()
    _patch_st(monkeypatch, recorder)
    trace = _load("ltm_trace_read_redacted.json")
    render_memory(trace["events"])
    expander_titles = [args[0] for name, args, _kwargs in recorder.calls if name == "expander" and args]
    assert any("Related context" in t for t in expander_titles)
    text = _all_text(recorder)
    assert "Auth context" in text
    assert "Prompt assembly" in text


def test_summary_tiles_memory_includes_mode_for_reads() -> None:
    trace = _load("ltm_trace_read_raw.json")
    tiles_html = "".join(summary_tiles(trace))
    assert "Memory" in tiles_html
    assert "8 entries" in tiles_html
    assert "hybrid" in tiles_html


def test_summary_tiles_memory_includes_write_outcome_in_hint() -> None:
    trace = _load("ltm_trace_write_success.json")
    tiles_html = "".join(summary_tiles(trace))
    assert "Memory" in tiles_html
    assert "hybrid" in tiles_html
    assert "1 written" in tiles_html
