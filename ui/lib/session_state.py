"""Centralized Streamlit session_state defaults."""

from __future__ import annotations

import uuid

import streamlit as st


def ensure_defaults() -> None:
    if "session_id" not in st.session_state:
        st.session_state.session_id = f"sess_{uuid.uuid4().hex[:16]}"
    if "prev_session_pick" not in st.session_state:
        st.session_state.prev_session_pick = st.session_state.session_id
    if "messages" not in st.session_state:
        st.session_state.messages = []
