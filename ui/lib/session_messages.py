"""Map API session messages into Streamlit chat state and enrich with traces."""

from __future__ import annotations

from lib import log as ui_log
from lib.api_client import get_trace, trace_events_from_doc
from lib.inline_summary import TurnSummary, aggregate_summary


def _message_id_from_api(m: dict) -> str | None:
    mid = m.get("id") or m.get("messageId") or m.get("message_id")
    if isinstance(mid, str) and mid.strip():
        return mid.strip()
    return None


def normalize_session_message(m: dict) -> dict | None:
    """Convert a GET /sessions/:id message into ``st.session_state.messages`` shape."""
    role = m.get("role")
    if role not in ("user", "assistant"):
        return None

    out: dict = {
        "role": role,
        "content": str(m.get("content") or ""),
    }

    message_id = _message_id_from_api(m)
    if message_id:
        out["message_id"] = message_id

    trace_id = m.get("traceId") or m.get("trace_id")
    if isinstance(trace_id, str) and trace_id.strip():
        tid = trace_id.strip()
        out["trace_id"] = tid
        out["inline_summary"] = _minimal_inline_block(tid)

    return out


def _minimal_inline_block(trace_id: str) -> dict:
    return {
        "summary": TurnSummary(trace_id=trace_id),
        "trace_id": trace_id,
    }


def messages_from_session_api(api_messages: list[dict]) -> list[dict]:
    """Normalize all messages from a session API payload (no trace fetch)."""
    out: list[dict] = []
    for m in api_messages:
        if not isinstance(m, dict):
            continue
        normalized = normalize_session_message(m)
        if normalized:
            out.append(normalized)
    return out


def _needs_trace_enrichment(msg: dict) -> bool:
    if msg.get("role") != "assistant":
        return False
    if msg.get("trace_enriched"):
        return False
    if not msg.get("trace_id"):
        return False
    inline = msg.get("inline_summary")
    if not inline:
        return True
    summary = inline.get("summary")
    if not isinstance(summary, TurnSummary):
        return True
    if (
        summary.total_tokens
        or summary.tools_used
        or summary.mongo_ops
        or summary.memory_facts_read
        or summary.memory_facts_written
        or summary.classifications
        or summary.vector_searches
    ):
        return False
    return True


def _trace_id_from_message(msg: dict) -> str | None:
    tid = msg.get("trace_id")
    if isinstance(tid, str) and tid.strip():
        return tid.strip()
    return None


def _fetch_trace_doc(
    api_base: str,
    *,
    session_id: str,
    trace_id: str,
    access_token: str | None,
    cache: dict[str, dict],
) -> dict | None:
    if trace_id in cache:
        return cache[trace_id]
    doc: dict | None = None
    try:
        doc = get_trace(api_base, trace_id=trace_id, access_token=access_token)
    except Exception as exc:
        ui_log.warn(
            "session trace fetch failed",
            session_id=session_id,
            trace_id=trace_id,
            error=str(exc),
        )
    if doc:
        cache[trace_id] = doc
    return doc


def enrich_messages_with_traces(
    api_base: str,
    session_id: str,
    messages: list[dict],
    access_token: str | None = None,
) -> None:
    """Attach full inline summaries and trace ids by fetching persisted traces."""
    cache: dict[str, dict] = {}

    for msg in messages:
        if not _needs_trace_enrichment(msg):
            continue

        trace_id = _trace_id_from_message(msg)
        if not trace_id:
            continue

        doc = _fetch_trace_doc(
            api_base,
            session_id=session_id,
            trace_id=trace_id,
            access_token=access_token,
            cache=cache,
        )
        if not doc:
            if trace_id:
                msg.setdefault("trace_id", trace_id)
                msg.setdefault("inline_summary", _minimal_inline_block(trace_id))
            continue

        resolved_tid = str(doc.get("traceId") or trace_id or "").strip()
        if resolved_tid:
            msg["trace_id"] = resolved_tid

        events = trace_events_from_doc(doc)
        summary = aggregate_summary(events)
        if resolved_tid:
            summary.trace_id = resolved_tid
        msg["inline_summary"] = {
            "summary": summary,
            "trace_id": resolved_tid or None,
        }
        msg["trace_enriched"] = True


def load_session_messages(
    api_base: str,
    session_id: str,
    api_messages: list[dict],
    access_token: str | None = None,
) -> list[dict]:
    """Normalize session messages and enrich assistant turns with persisted traces."""
    messages = messages_from_session_api(api_messages)
    enrich_messages_with_traces(api_base, session_id, messages, access_token)
    return messages


def any_need_trace_enrichment(messages: list[dict]) -> bool:
    return any(_needs_trace_enrichment(m) for m in messages)
