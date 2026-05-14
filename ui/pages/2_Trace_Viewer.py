"""Trace Viewer — full trace dashboard for one assistant turn.

Open with `?traceId=…` or `?sessionId=…&messageId=…`.
"""

from __future__ import annotations

import sys
from pathlib import Path

import streamlit as st

_ui_root = Path(__file__).resolve().parent.parent
if str(_ui_root) not in sys.path:
    sys.path.insert(0, str(_ui_root))

from lib.api_client import get_trace, list_recent_traces  # noqa: E402
from lib.cognito_gate import ensure_api_bearer_token, render_cognito_logout  # noqa: E402
from lib.config import load_settings  # noqa: E402
from lib.demo_narratives import narrate  # noqa: E402
from lib.trace_css import inject_trace_css  # noqa: E402
from lib.trace_navigation import (  # noqa: E402
    SELECTED_TRACE_ID_KEY,
    open_trace_viewer,
    query_trace_id,
    select_trace,
)
from lib.trace_view import (  # noqa: E402
    render_agentcore,
    render_context,
    render_developer_details,
    render_errors,
    render_memory,
    render_model_activity,
    render_mock_banner,
    render_mongo_dashboard,
    render_prompt_and_skills,
    render_routing,
    render_summary_header,
    render_timeline,
    render_tool_calls,
    render_trace_meta,
)


st.set_page_config(page_title="Trace Viewer", layout="wide")
inject_trace_css()

settings = load_settings()
api_token = ensure_api_bearer_token(settings)

with st.sidebar:
    render_cognito_logout(settings)
    st.page_link("app.py", label="← Chat")
    st.page_link("pages/1_Sessions.py", label="Sessions")
    st.markdown("---")
    st.caption("Recent traces")
    try:
        recent = list_recent_traces(settings.api_base, limit=10, access_token=api_token)
    except Exception as exc:
        st.caption(f"_(could not load recent traces: {exc})_")
        recent = []
    for r in recent:
        tid = r.get("traceId", "")
        if not tid:
            continue
        label = f"{tid[:8]}… · {r.get('agentId', '')}"
        if st.button(label, key=f"recent_trace_{tid}", use_container_width=True):
            open_trace_viewer(tid)


# ── Locate the trace from query params ──────────────────────────────────────
qp = st.query_params
trace_id = query_trace_id()
session_id = qp.get("sessionId")
message_id = qp.get("messageId")

if trace_id:
    select_trace(trace_id)
elif not (session_id and message_id):
    trace_id = st.session_state.get(SELECTED_TRACE_ID_KEY)
    if trace_id:
        select_trace(trace_id)

st.title("Trace Viewer")

if not trace_id and not (session_id and message_id):
    st.info(
        "Open this page from the inline summary's **View full trace →** link, "
        "or pick a trace from the sidebar."
    )
    st.stop()

with st.spinner("Loading trace…"):
    try:
        trace = get_trace(
            settings.api_base,
            trace_id=trace_id,
            session_id=session_id,
            message_id=message_id,
            access_token=api_token,
        )
    except Exception as exc:
        st.error(f"Could not fetch trace: {exc}")
        st.stop()

if not trace:
    st.warning("Trace not found. It may have expired or you may not have access.")
    st.stop()


# ── Render in priority order ────────────────────────────────────────────────
st.markdown(
    '<div class="trace-brand-strip">'
    '<span class="trace-brand-pill">MongoDB Atlas</span>'
    '<span class="trace-brand-pill">AWS Bedrock</span>'
    '<span style="opacity:0.7">multi-agent trace</span>'
    '</div>',
    unsafe_allow_html=True,
)

render_trace_meta(trace)
render_mock_banner(trace.get("events") or [])
render_summary_header(trace)

events = trace.get("events") or []
narrative_lines = narrate(events)
if narrative_lines:
    st.markdown('<div class="trace-section-title">What happened</div>', unsafe_allow_html=True)
    for line in narrative_lines:
        st.markdown(f"- {line}", unsafe_allow_html=True)

st.divider()
render_timeline(events)
render_context(events)
render_prompt_and_skills(events)
render_model_activity(events)
render_routing(events)
render_mongo_dashboard(events)
render_tool_calls(events)
render_agentcore(events)
render_memory(events)
render_errors(events)
render_developer_details(trace)