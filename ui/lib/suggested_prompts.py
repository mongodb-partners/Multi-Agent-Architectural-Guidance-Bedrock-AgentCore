"""Sidebar block: Try-a-prompt buttons backed by the API.

The prompts themselves live in ``config/demo-prompts.yaml`` on the API side
and are exposed via ``GET /demo-prompts`` (public endpoint). Clicking a
button writes the prompt into ``st.session_state.pending_chat_input`` so the
next rerun's ``handle_chat_input`` picks it up and submits it without the
user having to retype.
"""

from __future__ import annotations

import streamlit as st

from lib.api_client import get_demo_prompts


@st.cache_data(ttl=60, show_spinner=False)
def _load_prompts(api_base: str) -> list[dict]:
    """Cache the API response briefly so each rerun isn't a fresh GET."""
    return get_demo_prompts(api_base)


def render_suggested_prompts(api_base: str) -> None:
    groups = _load_prompts(api_base)
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
