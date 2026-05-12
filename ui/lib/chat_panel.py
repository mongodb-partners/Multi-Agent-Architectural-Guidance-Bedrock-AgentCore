"""Main chat transcript and streaming input."""

from __future__ import annotations

import streamlit as st

from lib.api_client import (
    AgentActiveEvent,
    ChatStreamError,
    DoneEvent,
    HandoffEvent,
    SkillLoadedEvent,
    ToolCallEvent,
    TokenEvent,
    TraceEvent,
    stream_chat_events,
)
from lib.inline_summary import aggregate_summary, render_inline_summary

_TOOL_ICON = "🔧"
_SKILL_ICON = "📚"
_HANDOFF_ICON = "🔀"
_AGENT_ICON = "🤖"


def render_message_history() -> None:
    for m in st.session_state.messages:
        with st.chat_message(m["role"]):
            st.markdown(m["content"])
            for badge in m.get("badges", []):
                st.caption(badge)
            inline = m.get("inline_summary")
            if inline:
                # Render the same inline summary as during streaming.
                render_inline_summary(
                    inline["summary"],
                    trace_url=inline.get("trace_url"),
                    raw_events=inline.get("events"),
                )


def _resolve_prompt() -> str | None:
    """Read the chat input, falling back to a queued prompt from the sidebar."""
    queued = st.session_state.pop("pending_chat_input", None)
    if queued:
        return str(queued)
    return st.chat_input("Message") or None


def handle_chat_input(api_base: str, token: str | None, agent_id: str) -> None:
    prompt = _resolve_prompt()
    if not prompt:
        return

    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        # Each agent gets its own (text_placeholder, status_container) pair,
        # created in order so Streamlit renders them chronologically.
        text_placeholder = st.empty()
        status_container = st.container()

        full = ""          # accumulates all text across agents (for session storage)
        current_text = ""  # text for the current agent block only
        badges: list[str] = []
        active_tools: dict[str, bool] = {}
        agent_seen = False  # track whether we've already started a block

        trace_events: list[TraceEvent] = []
        done_trace_id: str | None = None
        done_message_id: str | None = None

        def _new_agent_block() -> None:
            """Finalize current text block and create a fresh pair of placeholders."""
            nonlocal text_placeholder, status_container, current_text, active_tools
            text_placeholder.markdown(current_text)
            current_text = ""
            active_tools = {}
            text_placeholder = st.empty()
            status_container = st.container()

        try:
            for ev in stream_chat_events(
                api_base,
                prompt,
                st.session_state.session_id,
                agent_id=agent_id,
                access_token=token,
            ):
                if isinstance(ev, TokenEvent):
                    full += ev.text
                    current_text += ev.text
                    text_placeholder.markdown(current_text + "▌")

                elif isinstance(ev, AgentActiveEvent):
                    if agent_seen:
                        _new_agent_block()
                    agent_seen = True
                    badge = f"{_AGENT_ICON} **{ev.agent_name}** active"
                    badges.append(badge)
                    with status_container:
                        st.caption(badge)

                elif isinstance(ev, HandoffEvent):
                    badge = f"{_HANDOFF_ICON} Handoff: `{ev.from_agent}` → `{ev.to_agent}`"
                    badges.append(badge)
                    with status_container:
                        st.caption(badge)

                elif isinstance(ev, ToolCallEvent):
                    if ev.status == "started":
                        active_tools[ev.tool] = False
                        badge = f"{_TOOL_ICON} `{ev.tool}` …"
                        badges.append(badge)
                        with status_container:
                            st.caption(badge)
                    elif ev.status == "completed":
                        active_tools[ev.tool] = True
                        done_badge = f"{_TOOL_ICON} `{ev.tool}` ✓"
                        pending = f"{_TOOL_ICON} `{ev.tool}` …"
                        for i in range(len(badges) - 1, -1, -1):
                            if badges[i] == pending:
                                badges[i] = done_badge
                                break
                        else:
                            badges.append(done_badge)

                elif isinstance(ev, SkillLoadedEvent):
                    badge = f"{_SKILL_ICON} Skill loaded: `{ev.skill_name}`"
                    badges.append(badge)
                    with status_container:
                        st.caption(badge)

                elif isinstance(ev, TraceEvent):
                    trace_events.append(ev)

                elif isinstance(ev, DoneEvent):
                    done_trace_id = ev.trace_id
                    done_message_id = ev.message_id

            text_placeholder.markdown(current_text)

        except ChatStreamError as e:
            text_placeholder.error(f"{e.code}: {e}")
            full = f"*(error: {e.code})*"
        except Exception as e:
            text_placeholder.error(str(e))
            full = f"*(error: {e})*"

        # ── Inline summary card (always-on demo polish) ───────────────────
        inline_block: dict | None = None
        if trace_events:
            summary = aggregate_summary(trace_events)
            trace_url = (
                f"/Trace_Viewer?traceId={done_trace_id}" if done_trace_id else None
            )
            render_inline_summary(summary, trace_url=trace_url, raw_events=trace_events)
            inline_block = {
                "summary": summary,
                "trace_url": trace_url,
                "events": trace_events,
            }

    msg: dict = {"role": "assistant", "content": full, "badges": badges}
    if inline_block:
        msg["inline_summary"] = inline_block
    if done_trace_id:
        msg["trace_id"] = done_trace_id
    if done_message_id:
        msg["message_id"] = done_message_id
    st.session_state.messages.append(msg)
