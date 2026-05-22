"""Streamlit chat UI for the multi-agent API (local dev)."""

from __future__ import annotations

import sys
from pathlib import Path

import streamlit as st

_ui_root = Path(__file__).resolve().parent
if str(_ui_root) not in sys.path:
    sys.path.insert(0, str(_ui_root))

from lib.brand_css import inject_brand_css
from lib.chat_panel import handle_chat_input, render_message_history
from lib.cognito_gate import ensure_api_bearer_token, render_cognito_logout
from lib.config import load_settings
from lib.metrics_sidebar import render_metrics_block
from lib.session_state import ensure_defaults
from lib.sidebar import render_session_and_agent_sidebar
from lib.suggested_prompts import render_suggested_prompts
from lib.trace_css import inject_trace_css

st.set_page_config(page_title="Multi-Agent Chat", layout="wide")
inject_trace_css()
inject_brand_css()

settings = load_settings()
api_token = ensure_api_bearer_token(settings)

st.title("Multi-agent chat")
_auth_hint = (
    "API calls use **Cognito** access tokens (`STREAMLIT_COGNITO_*`). "
    if settings.cognito
    else "**Cognito is not configured on the UI** — set `STREAMLIT_COGNITO_POOL_ID` + "
    "`STREAMLIT_COGNITO_CLIENT_ID` so the app can mint Bearer tokens for the API. "
    "(The API itself refuses to boot without `AUTH_JWKS_URI` + `AUTH_ISSUER`.)"
)
st.caption(
    f"API: `{settings.api_base}` — {_auth_hint}"
    "Use **Sessions** in the sidebar for a full list."
)

ensure_defaults()

with st.sidebar:
    agent_id = render_session_and_agent_sidebar(settings.api_base, api_token)
    render_suggested_prompts(settings.api_base, api_token)
    st.markdown("---")
    render_metrics_block(settings.api_base, api_token)
    render_cognito_logout(settings)

render_message_history()
handle_chat_input(settings.api_base, api_token, agent_id)

_xt = st.session_state.get("last_x_trace_id")
if _xt:
    st.caption(f"**X-Trace-Id** (support / CloudWatch): `{_xt}`")
