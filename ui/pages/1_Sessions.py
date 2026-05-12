"""Dedicated session list: open a session in Chat or delete it on the API."""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

import streamlit as st

_ui_root = Path(__file__).resolve().parent.parent
if str(_ui_root) not in sys.path:
    sys.path.insert(0, str(_ui_root))

from lib.api_client import delete_session, get_session, list_sessions
from lib.cognito_gate import ensure_api_bearer_token, render_cognito_logout
from lib.config import load_settings
from lib.session_state import ensure_defaults

st.set_page_config(page_title="Sessions", layout="wide")

settings = load_settings()
api_token = ensure_api_bearer_token(settings)
ensure_defaults()

with st.sidebar:
    render_cognito_logout(settings)
    st.page_link("app.py", label="← Chat")

st.title("Sessions")
st.caption(
    f"API: `{settings.api_base}` — server-side conversation records (in-memory until persistent store lands)."
)

try:
    rows = list_sessions(settings.api_base, api_token)
except Exception as e:
    st.error(f"Could not list sessions: {e}")
    st.stop()

if not rows:
    st.info("No sessions yet. Send a message from **Chat** (home) to create one.")
else:
    st.write(f"**{len(rows)}** session(s).")

    def _sort_key(r: dict) -> str:
        return str(r.get("updatedAt") or r.get("createdAt") or "")

    for i, row in enumerate(sorted(rows, key=_sort_key, reverse=True)):
        if i:
            st.divider()
        sid = row.get("sessionId")
        if not isinstance(sid, str):
            continue
        mc = row.get("messageCount", 0)
        upd = row.get("updatedAt") or row.get("createdAt") or ""
        key_base = sid.replace(".", "_")[:80]

        c1, c2, c3, c4, c5 = st.columns([4, 1, 1, 1, 1])
        with c1:
            st.code(sid, language=None)
            if upd:
                st.caption(str(upd))
        with c2:
            st.write(f"{mc} msgs")
        with c3:
            if st.button("Open in chat", key=f"open_{key_base}"):
                st.session_state.session_id = sid
                st.session_state.prev_session_pick = sid
                try:
                    data = get_session(settings.api_base, sid, api_token)
                    st.session_state.messages = [
                        {"role": m["role"], "content": m["content"]}
                        for m in data.get("messages", [])
                        if m.get("role") in ("user", "assistant")
                    ]
                except Exception:
                    st.session_state.messages = []
                st.switch_page("app.py")
        with c4:
            # View traces — find the most recent traceId on an assistant message
            # in this session and link the Trace Viewer to it. Falls back to a
            # query-by-session link when no traceId is cached on the listing.
            if st.button("View traces", key=f"trace_{key_base}"):
                try:
                    data = get_session(settings.api_base, sid, api_token)
                    asst_with_trace = [
                        m for m in data.get("messages", [])
                        if m.get("role") == "assistant" and m.get("traceId")
                    ]
                    if asst_with_trace:
                        latest = asst_with_trace[-1]
                        st.query_params["traceId"] = latest["traceId"]
                        st.switch_page("pages/2_Trace_Viewer.py")
                    else:
                        st.warning("No traces yet for this session.")
                except Exception as exc:
                    st.error(f"Could not load session: {exc}")
        with c5:
            if st.button("Delete", key=f"del_{key_base}"):
                try:
                    ok = delete_session(settings.api_base, sid, api_token)
                    if ok:
                        if st.session_state.session_id == sid:
                            st.session_state.session_id = f"sess_{uuid.uuid4().hex[:16]}"
                            st.session_state.prev_session_pick = st.session_state.session_id
                            st.session_state.messages = []
                        st.rerun()
                    else:
                        st.warning("Session not found (already removed).")
                        st.rerun()
                except Exception as ex:
                    st.error(str(ex))
