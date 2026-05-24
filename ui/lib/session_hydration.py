"""Rehydrate chat session state from the API (refresh-safe)."""

from __future__ import annotations

import streamlit as st

from lib import log as ui_log
from lib.api_client import get_session
from lib.session_messages import (
    any_need_trace_enrichment,
    enrich_messages_with_traces,
    load_session_messages,
)

HYDRATED_SESSION_KEY = "_hydrated_session_id"
SESSION_ID_QP = "sessionId"


def _qp_value(key: str) -> str | None:
    raw = st.query_params.get(key)
    if isinstance(raw, list):
        raw = raw[0] if raw else None
    text = str(raw or "").strip()
    return text or None


def query_session_id() -> str | None:
    return _qp_value(SESSION_ID_QP)


def sync_session_id_query_param(session_id: str | None) -> None:
    """Keep the active session id in the URL so a browser refresh can reload it."""
    sid = str(session_id or "").strip()
    if sid:
        st.query_params[SESSION_ID_QP] = sid
    elif SESSION_ID_QP in st.query_params:
        del st.query_params[SESSION_ID_QP]


def clear_session_id_query_param() -> None:
    if SESSION_ID_QP in st.query_params:
        del st.query_params[SESSION_ID_QP]


def _clear_hydrated_marker() -> None:
    if hasattr(st.session_state, HYDRATED_SESSION_KEY):
        delattr(st.session_state, HYDRATED_SESSION_KEY)


def mark_session_hydrated(session_id: str) -> None:
    setattr(st.session_state, HYDRATED_SESSION_KEY, session_id)


def _fetch_session_messages(
    api_base: str,
    session_id: str,
    access_token: str | None,
) -> list[dict]:
    data = get_session(api_base, session_id, access_token)
    return load_session_messages(
        api_base,
        session_id,
        data.get("messages", []),
        access_token,
    )


def ensure_chat_session_hydrated(api_base: str, access_token: str | None) -> None:
    """Load or enrich session messages when opening or refreshing an old chat."""
    qp_sid = query_session_id()
    state_sid = str(st.session_state.get("session_id") or "").strip()

    if qp_sid and qp_sid != state_sid:
        st.session_state.session_id = qp_sid
        st.session_state.prev_session_pick = qp_sid
        st.session_state.messages = []
        _clear_hydrated_marker()
        state_sid = qp_sid

    sid = str(st.session_state.get("session_id") or "").strip()
    if not sid:
        return

    messages: list[dict] = st.session_state.get("messages") or []

    if not messages:
        # Refresh with ?sessionId=… — reload transcript from API.
        if qp_sid == sid:
            try:
                st.session_state.messages = _fetch_session_messages(
                    api_base, sid, access_token
                )
                mark_session_hydrated(sid)
                sync_session_id_query_param(sid)
            except Exception as exc:
                ui_log.warn(
                    "session hydrate fetch failed",
                    session_id=sid,
                    error=str(exc),
                )
        return

    if any_need_trace_enrichment(messages):
        try:
            enrich_messages_with_traces(api_base, sid, messages, access_token)
        except Exception as exc:
            ui_log.warn(
                "session trace enrich failed",
                session_id=sid,
                error=str(exc),
            )

    if getattr(st.session_state, HYDRATED_SESSION_KEY, None) != sid:
        mark_session_hydrated(sid)

    sync_session_id_query_param(sid)
