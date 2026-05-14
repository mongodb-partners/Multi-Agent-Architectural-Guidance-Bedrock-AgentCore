"""Shared Trace Viewer navigation helpers."""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import streamlit as st

TRACE_VIEWER_PAGE = "pages/2_Trace_Viewer.py"
SELECTED_TRACE_ID_KEY = "selected_trace_id"


def trace_id_from_url(trace_url: str | None) -> str | None:
    """Extract traceId from legacy Trace Viewer links."""
    if not trace_url:
        return None
    values = parse_qs(urlparse(trace_url).query).get("traceId")
    if not values:
        return None
    return values[0] or None


def query_trace_id() -> str | None:
    """Return traceId from Streamlit query params, if present."""
    raw = st.query_params.get("traceId")
    if isinstance(raw, list):
        raw = raw[0] if raw else None
    tid = str(raw or "").strip()
    return tid or None


def select_trace(trace_id: str | None) -> str | None:
    """Persist the selected trace in both URL params and session state."""
    tid = str(trace_id or "").strip()
    if not tid:
        return None
    st.session_state[SELECTED_TRACE_ID_KEY] = tid
    st.query_params["traceId"] = tid
    return tid


def open_trace_viewer(trace_id: str | None) -> None:
    """Switch to Trace Viewer without using a raw browser link."""
    if select_trace(trace_id):
        st.switch_page(TRACE_VIEWER_PAGE)

