"""Tests for Trace Viewer navigation helpers."""

from __future__ import annotations

import sys
from pathlib import Path

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib import trace_navigation as nav  # noqa: E402


def test_trace_id_from_url_reads_legacy_viewer_link() -> None:
    assert nav.trace_id_from_url("/Trace_Viewer?traceId=trc-123") == "trc-123"
    assert nav.trace_id_from_url("pages/2_Trace_Viewer.py?traceId=trc-456") == "trc-456"
    assert nav.trace_id_from_url("/Trace_Viewer") is None


def test_select_trace_persists_query_and_session_state(monkeypatch) -> None:
    session_state: dict[str, str] = {}
    query_params: dict[str, str] = {}
    monkeypatch.setattr(nav.st, "session_state", session_state)
    monkeypatch.setattr(nav.st, "query_params", query_params)

    assert nav.select_trace(" trc-123 ") == "trc-123"
    assert session_state[nav.SELECTED_TRACE_ID_KEY] == "trc-123"
    assert query_params["traceId"] == "trc-123"


def test_open_trace_viewer_switches_with_selected_trace(monkeypatch) -> None:
    session_state: dict[str, str] = {}
    query_params: dict[str, str] = {}
    switched_to: list[str] = []
    monkeypatch.setattr(nav.st, "session_state", session_state)
    monkeypatch.setattr(nav.st, "query_params", query_params)
    monkeypatch.setattr(nav.st, "switch_page", switched_to.append)

    nav.open_trace_viewer("trc-123")

    assert session_state[nav.SELECTED_TRACE_ID_KEY] == "trc-123"
    assert query_params["traceId"] == "trc-123"
    assert switched_to == [nav.TRACE_VIEWER_PAGE]


# ---------------------------------------------------------------------------
# session_neighbors
# ---------------------------------------------------------------------------


def _trace(trace_id: str, created_at: str) -> dict:
    return {"traceId": trace_id, "createdAt": created_at}


def test_session_neighbors_sorts_oldest_first_and_returns_position() -> None:
    """Server returns newest-first; the helper must sort oldest-first so
    "prev" = earlier turn, "next" = later turn, and the 1-based position
    reflects chronological order."""
    traces = [
        _trace("t3", "2026-05-20T08:02:00Z"),
        _trace("t1", "2026-05-20T08:00:00Z"),
        _trace("t2", "2026-05-20T08:01:00Z"),
    ]
    prev_t, next_t, position, total = nav.session_neighbors(traces, current_trace_id="t2")
    assert prev_t is not None and prev_t["traceId"] == "t1"
    assert next_t is not None and next_t["traceId"] == "t3"
    assert position == 2
    assert total == 3


def test_session_neighbors_handles_first_and_last_turn() -> None:
    traces = [_trace("t1", "2026-05-20T08:00:00Z"), _trace("t2", "2026-05-20T08:01:00Z")]
    prev_t, next_t, position, total = nav.session_neighbors(traces, current_trace_id="t1")
    assert prev_t is None
    assert next_t is not None and next_t["traceId"] == "t2"
    assert position == 1 and total == 2

    prev_t, next_t, position, total = nav.session_neighbors(traces, current_trace_id="t2")
    assert prev_t is not None and prev_t["traceId"] == "t1"
    assert next_t is None
    assert position == 2 and total == 2


def test_session_neighbors_returns_sentinel_when_trace_not_in_list() -> None:
    traces = [_trace("t1", "2026-05-20T08:00:00Z")]
    prev_t, next_t, position, total = nav.session_neighbors(traces, current_trace_id="stale-id")
    assert prev_t is None and next_t is None
    assert position == 0
    assert total == 1

