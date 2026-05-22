"""Sidebar block: Try-a-prompt buttons backed by the API.

The prompts themselves live in ``config/demo-prompts.yaml`` on the API side
and are exposed via authenticated ``GET /demo-prompts``. Clicking a
button writes the prompt into ``st.session_state.pending_chat_input`` so the
next rerun's ``handle_chat_input`` picks it up and submits it without the
user having to retype.
"""

from __future__ import annotations

import streamlit as st

from lib.api_client import get_demo_prompts


@st.cache_data(ttl=60, show_spinner=False)
def _load_prompts(api_base: str, auth_present: bool, _access_token: str | None) -> list[dict]:
    """Cache the API response briefly so each rerun isn't a fresh GET."""
    if not auth_present:
        return []
    return get_demo_prompts(api_base, access_token=_access_token)


def render_suggested_prompts(api_base: str, access_token: str | None) -> None:
    groups = _load_prompts(api_base, bool(access_token), access_token)
    if not groups:
        return
    st.markdown("---")
    st.markdown("**Try a prompt**")
    for gi, group in enumerate(groups):
        title = str(group.get("title") or f"Group {gi + 1}")
        with st.expander(title, expanded=gi == 0):
            for pi, prompt in enumerate(group.get("prompts") or []):
                label = str(prompt.get("label") or prompt.get("text") or "Prompt")
                text = str(prompt.get("text") or "")
                if not text:
                    continue
                if st.button(label, key=f"prompt_{gi}_{pi}", use_container_width=True):
                    st.session_state["pending_chat_input"] = text
                    st.rerun()
