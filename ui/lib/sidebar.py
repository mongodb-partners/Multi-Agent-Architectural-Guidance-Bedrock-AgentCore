"""Session and agent controls in the sidebar."""

from __future__ import annotations

import uuid

import streamlit as st

from lib.api_client import get_health, list_agents

_STATUS_CLASS = {
    "ok": "ok",
    "connected": "ok",
    "dev_mock": "warn",
    "degraded": "err",
    "unreachable": "err",
    "inactive": "warn",
    "not_configured": "muted",
    "no_agents": "muted",
}


def _status_icon(status: str) -> str:
    cls = _STATUS_CLASS.get(status, "muted")
    return f'<span class="brand-status brand-status--{cls}"></span>'


def render_session_and_agent_sidebar(api_base: str, token: str | None) -> str:
    """Render sidebar widgets; returns selected ``agent_id``."""

    try:
        agents = list_agents(api_base, token)
        agent_ids = [a["id"] for a in agents]
        default_idx = agent_ids.index("orchestrator") if "orchestrator" in agent_ids else 0
    except Exception as e:
        st.warning(f"Could not load agents: {e}")
        agent_ids = ["orchestrator"]
        default_idx = 0

    pick_agent = st.selectbox("Target agent", options=agent_ids, index=default_idx)

    if st.button("New Session", use_container_width=True):
        st.session_state.session_id = f"sess_{uuid.uuid4().hex[:16]}"
        st.session_state.prev_session_pick = st.session_state.session_id
        st.session_state.messages = []
        st.rerun()

    return pick_agent


def render_api_health(api_base: str, token: str | None) -> None:
    """Render the API health expander."""
    with st.expander("API health", expanded=False):
        try:
            health = get_health(api_base, token)
            overall = health.get("status", "unknown")
            icon = _status_icon(overall)
            st.markdown(f"**{icon} {overall.upper()}**", unsafe_allow_html=True)
            deps = health.get("dependencies") or {}
            for dep_name, dep_status in deps.items():
                dep_icon = _status_icon(str(dep_status))
                label = dep_name.replace("_", " ").title()
                st.markdown(f"{dep_icon} {label}: `{dep_status}`", unsafe_allow_html=True)
            ts = health.get("timestamp")
            if ts:
                st.caption(f"Checked: {ts}")
        except Exception as e:
            st.caption(f"Could not reach API: {e}")
