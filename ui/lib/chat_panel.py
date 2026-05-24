"""Main chat transcript and streaming input."""

from __future__ import annotations

import streamlit as st

from lib.avatars import BOT_AVATAR, USER_AVATAR
from lib.api_client import (
    AgentActiveEvent,
    ChatStreamError,
    DoneEvent,
    HandoffEvent,
    SkillLoadedEvent,
    ToolCallEvent,
    TokenEvent,
    TraceEvent,
    get_trace,
    stream_chat_events,
)
from lib import log as ui_log
from lib.inline_summary import (
    TurnSummary,
    aggregate_summary,
    merge_post_done_memory_events,
    render_inline_summary,
)

_TOOL_ICON = ":material/build:"
_SKILL_ICON = ":material/menu_book:"
_HANDOFF_ICON = ":material/swap_horiz:"
_AGENT_ICON = ":material/smart_toy:"
_MODEL_ICON = ":material/psychology:"
_MONGO_ICON = ":material/database:"
_STREAM_ICON = ":material/bolt:"


def _pretty_tool_name(tool: str) -> str:
    names = {
        "mongodb_query": "MongoDB query",
        "mongodb_aggregate": "MongoDB aggregation",
        "mongodb_vector_search": "MongoDB vector search",
        "run_skill_script": "skill script",
        "read_skill_resource": "skill resource",
    }
    return names.get(tool, tool.replace("_", " ") or "tool")


def _trace_progress_badge(ev: TraceEvent) -> str | None:
    payload = ev.payload or {}
    if ev.type == "latency.checkpoint":
        name = str(payload.get("name") or "")
        if name == "api.stream.opened":
            return f"{_STREAM_ICON} Response stream opened"
        if name == "api.runtime.first_frame":
            return f"{_STREAM_ICON} Agent runtime started streaming"
        if name == "model.first_delta":
            return f"{_MODEL_ICON} Model started planning"
        if name == "model.first_tool_call":
            tool_name = _pretty_tool_name(str(payload.get("toolName") or "tool"))
            return f"{_TOOL_ICON} Model selected {tool_name}"
        return None

    if ev.type == "model.request":
        model_id = str(payload.get("modelId") or "model")
        short_model = model_id.rsplit(".", 1)[-1]
        return f"{_MODEL_ICON} Calling {short_model}"

    if ev.type == "mongo.query":
        collection = str(payload.get("collection") or "collection")
        op = str(payload.get("op") or "query")
        if op == "vector_search":
            return f"{_MONGO_ICON} Searching MongoDB vectors in `{collection}`"
        return f"{_MONGO_ICON} Querying MongoDB `{collection}`"

    if ev.type == "mongo.result":
        status = str(payload.get("status") or "")
        doc_count = payload.get("docCount")
        latency = payload.get("latencyMs")
        if isinstance(doc_count, int):
            noun = "document" if doc_count == 1 else "documents"
            suffix = f" in {int(latency)} ms" if isinstance(latency, (int, float)) else ""
            return f"{_MONGO_ICON} MongoDB returned {doc_count} {noun}{suffix}"
        if status:
            return f"{_MONGO_ICON} MongoDB result: {status}"
        return None

    if ev.type == "mongo.vector_search":
        limit = payload.get("limit")
        if isinstance(limit, int):
            return f"{_MONGO_ICON} Running vector search for top {limit}"
        return f"{_MONGO_ICON} Running vector search"

    return None


def render_message_history() -> None:
    _avatars = {"user": USER_AVATAR, "assistant": BOT_AVATAR}
    for m in st.session_state.messages:
        with st.chat_message(m["role"], avatar=_avatars.get(m["role"])):
            st.markdown(m["content"])
            for badge in m.get("badges", []):
                st.caption(badge)
            inline = m.get("inline_summary")
            trace_id = (
                (inline or {}).get("trace_id")
                or m.get("trace_id")
            )
            if inline:
                # Render the same inline summary as during streaming.
                render_inline_summary(
                    inline["summary"],
                    trace_url=inline.get("trace_url"),
                    trace_id=trace_id,
                )
            elif trace_id:
                # Session replay: API stores traceId but not the live inline card.
                render_inline_summary(
                    TurnSummary(trace_id=trace_id),
                    trace_id=trace_id,
                )


def _resolve_prompt() -> str | None:
    """Read the chat input, falling back to a queued prompt from the sidebar."""
    typed = st.chat_input("Message")
    queued = st.session_state.pop("pending_chat_input", None)
    if queued:
        return str(queued)
    return typed or None


def handle_chat_input(api_base: str, token: str | None, agent_id: str) -> None:
    prompt = _resolve_prompt()
    if not prompt:
        return

    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user", avatar=USER_AVATAR):
        st.markdown(prompt)

    with st.chat_message("assistant", avatar=BOT_AVATAR):
        progress_status = st.status("Starting assistant response...", expanded=True)
        progress_status.write("Opening response stream...")

        # Each agent gets its own text placeholder, created in order so
        # Streamlit renders multi-agent text chronologically.
        text_placeholder = st.empty()

        full = ""          # accumulates all text across agents (for session storage)
        current_text = ""  # text for the current agent block only
        badges: list[str] = []
        progress_seen: set[str] = set()
        active_tools: dict[str, bool] = {}
        agent_seen = False  # track whether we've already started a block

        trace_events: list[TraceEvent] = []
        done_trace_id: str | None = None
        done_message_id: str | None = None

        def _emit_progress(badge: str, *, key: str | None = None, persist: bool = True) -> None:
            dedupe_key = key or badge
            if dedupe_key in progress_seen:
                return
            progress_seen.add(dedupe_key)
            progress_status.write(badge)
            progress_status.update(label=badge, state="running", expanded=True)
            if persist:
                badges.append(badge)

        def _new_agent_block() -> None:
            """Finalize current text block and create a fresh pair of placeholders."""
            nonlocal text_placeholder, current_text, active_tools
            text_placeholder.markdown(current_text)
            current_text = ""
            active_tools = {}
            text_placeholder = st.empty()

        try:
            chat_rid = ui_log.new_request_id()

            def _capture_headers(resp) -> None:
                xt = resp.headers.get("X-Trace-Id")
                if xt:
                    st.session_state["last_x_trace_id"] = xt

            for ev in stream_chat_events(
                api_base,
                prompt,
                st.session_state.session_id,
                agent_id=agent_id,
                access_token=token,
                request_id=chat_rid,
                on_response_headers=_capture_headers,
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
                    _emit_progress(badge, key=f"agent:{ev.agent_id or ev.agent_name}")

                elif isinstance(ev, HandoffEvent):
                    badge = f"{_HANDOFF_ICON} Handoff: `{ev.from_agent}` → `{ev.to_agent}`"
                    _emit_progress(badge, key=f"handoff:{ev.from_agent}:{ev.to_agent}")

                elif isinstance(ev, ToolCallEvent):
                    pretty_tool = _pretty_tool_name(ev.tool)
                    if ev.status == "started":
                        active_tools[ev.tool] = False
                        badge = f"{_TOOL_ICON} Running {pretty_tool}..."
                        _emit_progress(badge, key=f"tool:{ev.tool}:started")
                    elif ev.status == "completed":
                        active_tools[ev.tool] = True
                        done_badge = f"{_TOOL_ICON} Finished {pretty_tool}"
                        pending = f"{_TOOL_ICON} Running {pretty_tool}..."
                        for i in range(len(badges) - 1, -1, -1):
                            if badges[i] == pending:
                                badges[i] = done_badge
                                break
                        else:
                            badges.append(done_badge)
                        _emit_progress(done_badge, key=f"tool:{ev.tool}:completed", persist=False)

                elif isinstance(ev, SkillLoadedEvent):
                    badge = f"{_SKILL_ICON} Skill loaded: `{ev.skill_name}`"
                    _emit_progress(badge, key=f"skill:{ev.skill_name}")

                elif isinstance(ev, TraceEvent):
                    trace_events.append(ev)
                    badge = _trace_progress_badge(ev)
                    if badge:
                        _emit_progress(badge, key=f"trace:{ev.type}:{badge}")

                elif isinstance(ev, DoneEvent):
                    done_trace_id = ev.trace_id
                    done_message_id = ev.message_id

            text_placeholder.markdown(current_text)
            progress_status.update(label="Response complete", state="complete", expanded=False)

        except ChatStreamError as e:
            progress_status.update(label=f"{e.code}: response failed", state="error", expanded=True)
            text_placeholder.error(f"{e.code}: {e}")
            full = f"*(error: {e.code})*"
        except Exception as e:
            progress_status.update(label="Response failed", state="error", expanded=True)
            text_placeholder.error(str(e))
            full = f"*(error: {e})*"

        # ── Inline summary card (always-on demo polish) ───────────────────
        # `memory.long_term_write` and `memory.long_term_skip` only land in
        # the persisted trace AFTER the SSE `done` event because fact
        # extraction is intentionally dangling. Re-fetch once with a short
        # wait so the Memory card surfaces those events on this same render.
        inline_block: dict | None = None
        if trace_events:
            persisted_doc: dict | None = None
            if done_trace_id:
                try:
                    import time as _time
                    _time.sleep(1.5)  # one second covers most extraction latencies
                    persisted_doc = get_trace(
                        api_base,
                        trace_id=done_trace_id,
                        access_token=token,
                        request_id=ui_log.new_request_id(),
                        timeout=10.0,
                    )
                except Exception as exc:
                    ui_log.warn(
                        "post-done trace fetch failed",
                        trace_id=done_trace_id,
                        error=str(exc),
                    )
            merged_events = merge_post_done_memory_events(trace_events, persisted_doc)
            summary = aggregate_summary(merged_events)
            render_inline_summary(summary, trace_id=done_trace_id)
            inline_block = {
                "summary": summary,
                "trace_id": done_trace_id,
            }

    msg: dict = {"role": "assistant", "content": full, "badges": badges}
    if inline_block:
        msg["inline_summary"] = inline_block
    if done_trace_id:
        msg["trace_id"] = done_trace_id
    if done_message_id:
        msg["message_id"] = done_message_id
    if inline_block:
        msg["trace_enriched"] = True
    st.session_state.messages.append(msg)
