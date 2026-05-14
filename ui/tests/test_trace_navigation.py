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

