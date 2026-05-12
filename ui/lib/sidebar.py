"""Session and agent controls in the sidebar."""

from __future__ import annotations

import uuid

import requests
import streamlit as st

from lib.api_client import get_health, get_http_tools, get_session, list_agents, list_sessions

_STATUS_ICONS = {
    "ok": "🟢",
    "connected": "🟢",
    "dev_mock": "🟡",
    "degraded": "🔴",
    "unreachable": "🔴",
    "not_configured": "⚪",
    "no_agents": "⚪",
}


def _status_icon(status: str) -> str:
    return _STATUS_ICONS.get(status, "⚪")


def _session_label(server_sessions: list[dict], sid: str) -> str:
    info = next((x for x in server_sessions if x.get("sessionId") == sid), None)
    n = info.get("messageCount", 0) if info else 0
    short = sid if len(sid) <= 28 else f"{sid[:25]}…"
    return f"{short} ({n} msgs)" if info else f"{short} (new)"


def render_session_and_agent_sidebar(api_base: str, token: str | None) -> str:
    """Render sidebar widgets; returns selected ``agent_id``."""
    st.subheader("Session")

    try:
        server_sessions = list_sessions(api_base, token)
    except Exception as e:
        st.warning(f"Could not list sessions: {e}")
        server_sessions = []

    ordered_ids: list[str] = [st.session_state.session_id]
    for row in server_sessions:
        sid = row.get("sessionId")
        if isinstance(sid, str) and sid not in ordered_ids:
            ordered_ids.append(sid)

    pick = st.selectbox(
        "Active session",
        options=ordered_ids,
        format_func=lambda sid: _session_label(server_sessions, sid),
    )
    if pick != st.session_state.prev_session_pick:
        st.session_state.prev_session_pick = pick
        st.session_state.session_id = pick
        try:
            data = get_session(api_base, pick, token)
            st.session_state.messages = [
                {"role": m["role"], "content": m["content"]}
                for m in data.get("messages", [])
                if m.get("role") in ("user", "assistant")
            ]
        except requests.exceptions.HTTPError as ex:
            if ex.response is not None and ex.response.status_code == 404:
                st.session_state.messages = []
            else:
                st.session_state.messages = []
                st.error(str(ex))
        st.rerun()

    c_new, c_refresh = st.columns(2)
    with c_new:
        if st.button("New", use_container_width=True):
            st.session_state.session_id = f"sess_{uuid.uuid4().hex[:16]}"
            st.session_state.prev_session_pick = st.session_state.session_id
            st.session_state.messages = []
            st.rerun()
    with c_refresh:
        if st.button("Refresh", use_container_width=True):
            st.rerun()
    st.caption(f"`{st.session_state.session_id}`")

    try:
        agents = list_agents(api_base, token)
        agent_ids = [a["id"] for a in agents]
        default_idx = agent_ids.index("orchestrator") if "orchestrator" in agent_ids else 0
    except Exception as e:
        st.warning(f"Could not load agents: {e}")
        agents = []
        agent_ids = ["orchestrator"]
        default_idx = 0

    pick_agent = st.selectbox("Target agent", options=agent_ids, index=default_idx)

    meta = next((a for a in agents if a.get("id") == pick_agent), None)
    if meta:
        with st.expander("About this agent", expanded=False):
            st.markdown(f"**{meta.get('name', pick_agent)}**")
            desc = meta.get("description")
            if desc:
                st.caption(str(desc))

    with st.expander("HTTP tools (API)", expanded=False):
        try:
            ht = get_http_tools(api_base, token)
            merged = ht.get("tools") or []
            st.caption(f"{len(merged)} configured (`GET /http-tools`).")
            for row in merged[:20]:
                name = row.get("name", "?")
                url_ok = row.get("urlConfigured")
                st.markdown(f"- `{name}`" + (" ✓ URL" if url_ok else " (URL env unset)"))
            if len(merged) > 20:
                st.caption(f"… and {len(merged) - 20} more.")
        except Exception as e:
            st.caption(f"Could not load: {e}")

    with st.expander("API health", expanded=False):
        try:
            health = get_health(api_base, token)
            overall = health.get("status", "unknown")
            icon = _status_icon(overall)
            st.markdown(f"**{icon} {overall.upper()}**")
            deps = health.get("dependencies") or {}
            for dep_name, dep_status in deps.items():
                dep_icon = _status_icon(str(dep_status))
                label = dep_name.replace("_", " ").title()
                st.caption(f"{dep_icon} {label}: `{dep_status}`")
            ts = health.get("timestamp")
            if ts:
                st.caption(f"Checked: {ts}")
        except Exception as e:
            st.caption(f"Could not reach API: {e}")

    return pick_agent
