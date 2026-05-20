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


def session_neighbors(
    session_traces: list[dict],
    *,
    current_trace_id: str,
) -> tuple[dict | None, dict | None, int, int]:
    """Compute prev / next trace + position for the in-session nav strip.

    `session_traces` is the unfiltered list returned by
    `list_recent_traces(session_id=...)` ordered newest-first. We sort
    oldest-first so "prev" = earlier turn, "next" = later turn, then locate
    the current trace.

    Returns `(prev_trace, next_trace, position_1based, total)`. If the
    current trace is not in the list (e.g. dev fetched a stale projection),
    `(None, None, 0, total)` is returned and the caller should hide the nav.
    """
    ordered = sorted(
        [t for t in session_traces if isinstance(t, dict) and t.get("traceId")],
        key=lambda t: t.get("createdAt") or "",
    )
    total = len(ordered)
    index = next(
        (i for i, t in enumerate(ordered) if t.get("traceId") == current_trace_id),
        None,
    )
    if index is None:
        return None, None, 0, total
    prev_trace = ordered[index - 1] if index > 0 else None
    next_trace = ordered[index + 1] if index + 1 < total else None
    return prev_trace, next_trace, index + 1, total


def render_session_nav(settings, api_token: str | None, trace: dict) -> None:
    """Render the prev / next-turn-in-session nav strip.

    Hidden when only one turn exists in the session or the trace is opened
    without a `sessionId` we can list against. Failures listing the session
    degrade silently — the nav strip just doesn't render.
    """
    from lib.api_client import list_recent_traces  # local import keeps tests light

    session_id = trace.get("sessionId")
    trace_id = trace.get("traceId")
    if not (session_id and trace_id):
        return

    try:
        session_traces = list_recent_traces(
            settings.api_base,
            session_id=str(session_id),
            limit=50,
            access_token=api_token,
        )
    except Exception:
        return

    prev_trace, next_trace, position, total = session_neighbors(
        session_traces, current_trace_id=str(trace_id)
    )
    if total <= 1 or position == 0:
        return

    cols = st.columns([1, 3, 1])
    with cols[0]:
        if prev_trace and st.button(
            "← prev turn",
            key=f"nav_prev_{trace_id}",
            use_container_width=True,
        ):
            open_trace_viewer(str(prev_trace.get("traceId") or ""))
    with cols[1]:
        st.markdown(
            f"<div style='text-align:center; color:var(--text-muted,#B1B5BA); font-size:0.85em;'>"
            f"trace <strong>{position}</strong> of <strong>{total}</strong> in session"
            f"</div>",
            unsafe_allow_html=True,
        )
    with cols[2]:
        if next_trace and st.button(
            "next turn →",
            key=f"nav_next_{trace_id}",
            use_container_width=True,
        ):
            open_trace_viewer(str(next_trace.get("traceId") or ""))

