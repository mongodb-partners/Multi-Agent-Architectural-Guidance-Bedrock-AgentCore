"""Shared helpers for the Trace Viewer.

Used by `client_trace_view.py` (today's client-facing sections) and
`developer_trace_view.py` (the on-demand Developer details panel). Kept
private to the trace UI — call sites should import these symbols rather
than reimplementing them.

Two categories live here today:

1. **Generic trace-event helpers** — `_events_of`, `_payload`, `_as_int`,
   `_render_jsonish`, `_trace_events_dropped`, `_trace_is_truncated`,
   `_short_text`, `_doc_sources`, `_doc_preview_from_sample`,
   `_nearest_vector_result_payload`, `_vector_document_previews`,
   `_render_vector_document_previews`, `_completed_span_count`, `_tile_html`,
   `_mock_markers`.

2. **Long-term-memory helpers** — `_is_redacted`, `_any_redacted`,
   `_redaction_banner`, `_redacted_or_text`, `_human_skip_reason`,
   `_resolve_user_message_for_write`, plus the `_LTM_COLLECTIONS` set and
   `_MEMORY_SKIP_REASON_LABELS` mapping. Originally added by commit `c94f87e`
   to `lib/trace_view.py`; moved here so both the slim client-facing memory
   panel and the deep `_dev_memory_internals` panel can share them without
   either reaching across module boundaries.

The third category — sentinel rendering / OTel deep-link / span-tree-node
formatting — lives next to its consumer in `developer_trace_view.py` because
no client-facing renderer needs it.
"""

from __future__ import annotations

import json
import re
from typing import Any

import streamlit as st


# ---------------------------------------------------------------------------
# Generic trace-event helpers
# ---------------------------------------------------------------------------

def _events_of(events: list[dict], *types: str) -> list[dict]:
    s = set(types)
    return [e for e in events if e.get("type") in s]


def _payload(ev: dict) -> dict:
    p = ev.get("payload") or {}
    return p if isinstance(p, dict) else {}


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value or default)
    except (TypeError, ValueError):
        return default


_TRIMMED_MARKER_RE = re.compile(r"^\[trimmed\s+([0-9]+)B\]$")


def _render_jsonish(value: Any, *, empty_label: str | None = None) -> None:
    """Render trace payload values without handing raw strings to st.json."""
    if value is None:
        if empty_label:
            st.caption(empty_label)
        return

    if isinstance(value, (dict, list)):
        st.json(value)
        return

    if isinstance(value, str):
        text = value.strip()
        if not text:
            if empty_label:
                st.caption(empty_label)
            return

        trimmed = _TRIMMED_MARKER_RE.match(text)
        if trimmed:
            st.caption(f"Large raw trace detail was shortened for display ({int(trimmed.group(1)):,} bytes).")
            return

        if text[0] in "{[":
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, (dict, list)):
                st.json(parsed)
                return

        st.code(text, language=None)
        return

    st.code(str(value), language=None)


def _trace_events_dropped(trace: dict) -> int:
    summary = trace.get("summary") if isinstance(trace.get("summary"), dict) else {}
    return max(_as_int(trace.get("eventsDropped")), _as_int(summary.get("eventsDropped")))


def _trace_is_truncated(trace: dict) -> bool:
    summary = trace.get("summary") if isinstance(trace.get("summary"), dict) else {}
    return bool(trace.get("truncated") or summary.get("degraded") or _trace_events_dropped(trace))


_VECTOR_SCORE_BINS = [
    "0.00-0.19",
    "0.20-0.39",
    "0.40-0.59",
    "0.60-0.79",
    "0.80-1.00",
]


def _short_text(value: Any, max_chars: int = 180) -> str | None:
    if value is None:
        return None
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    text = text.strip()
    if not text:
        return None
    return text if len(text) <= max_chars else f"{text[:max_chars]}…"


def _doc_sources(doc: dict) -> list[str]:
    values: list[str] = []
    for key in ("sources", "_sources", "source", "url", "uri", "path"):
        raw = doc.get(key)
        if isinstance(raw, list):
            values.extend(_short_text(v, 80) for v in raw)
        else:
            values.append(_short_text(raw, 80))
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            out.append(value)
    return out


def _doc_preview_from_sample(doc: dict, rank: int, collection: str | None = None) -> dict:
    fields = {}
    for key in ("sku", "category", "brand", "status", "orderId", "customerEmail", "docId", "source", "url", "role"):
        if key in doc:
            fields[key] = doc.get(key)
    title = next(
        (_short_text(doc.get(key), 120) for key in ("title", "name", "sku", "code", "fact", "_id", "id", "docId") if doc.get(key)),
        None,
    )
    snippet = next(
        (_short_text(doc.get(key)) for key in ("content", "fact", "description", "summary", "body", "text", "answer") if doc.get(key)),
        None,
    )
    return {
        "rank": rank,
        "collection": collection,
        "_id": _short_text(doc.get("_id"), 120),
        "id": _short_text(doc.get("_id") or doc.get("id") or doc.get("docId") or doc.get("messageId") or doc.get("sku"), 120),
        "score": doc.get("_score"),
        "title": title,
        "snippet": snippet,
        "sources": _doc_sources(doc),
        "fields": fields,
    }


def _nearest_vector_result_payload(events: list[dict], vector_event: dict) -> dict:
    try:
        idx = events.index(vector_event)
    except ValueError:
        return {}
    for candidate in reversed(events[:idx]):
        if candidate.get("type") == "mongo.vector_search":
            break
        if candidate.get("type") == "mongo.result":
            payload = _payload(candidate)
            if payload.get("sampleDocs"):
                return payload
    return {}


def _vector_document_previews(vector_payload: dict, result_payload: dict) -> list[dict]:
    previews = vector_payload.get("documentPreviews")
    if isinstance(previews, list) and previews:
        return [p for p in previews if isinstance(p, dict)]
    sample_docs = result_payload.get("sampleDocs") if isinstance(result_payload, dict) else None
    if isinstance(sample_docs, list):
        collection = vector_payload.get("collection")
        return [
            _doc_preview_from_sample(doc, i + 1, collection if isinstance(collection, str) else None)
            for i, doc in enumerate(sample_docs[:5])
            if isinstance(doc, dict)
        ]
    return []


def _render_vector_document_previews(previews: list[dict]) -> None:
    if not previews:
        st.caption("No retrieved document/source preview was recorded for this vector search.")
        return
    st.caption("Retrieved sources / documents")
    for i, doc in enumerate(previews[:5], 1):
        rank = _as_int(doc.get("rank"), i)
        title = _short_text(doc.get("title"), 120) or _short_text(doc.get("id"), 120) or "document"
        score = doc.get("score")
        score_label = f" · score {float(score):.3f}" if isinstance(score, (int, float)) else ""
        collection = doc.get("collection")
        collection_label = f" · `{collection}`" if collection else ""
        st.markdown(f"**#{rank} {title}**{collection_label}{score_label}")
        stable_id = _short_text(doc.get("id"), 120)
        mongo_id = _short_text(doc.get("_id"), 120)
        if stable_id:
            st.caption(f"ID: `{stable_id}`")
        if mongo_id:
            st.caption(f"Mongo _id: `{mongo_id}`")
        sources = doc.get("sources")
        if isinstance(sources, list) and sources:
            st.caption("Sources: " + ", ".join(f"`{src}`" for src in sources[:4]))
        snippet = _short_text(doc.get("snippet"))
        if snippet:
            st.caption(snippet)
        fields = doc.get("fields")
        if isinstance(fields, dict) and fields:
            _render_jsonish(fields)


def _completed_span_count(events: list[dict]) -> int:
    completed = [e for e in events if e.get("durationMs") is not None]
    return len(completed) or len(events)


def _tile_html(label: str, value: str, hint: str | None = None) -> str:
    extra = f'<div class="trace-tile-hint">{hint}</div>' if hint else ""
    return (
        f'<div class="trace-tile">'
        f'<div class="trace-tile-label">{label}</div>'
        f'<div class="trace-tile-value">{value}</div>'
        f"{extra}"
        f"</div>"
    )


def _mock_markers(events: list[dict]) -> list[str]:
    markers: set[str] = set()
    source_fields = (
        "backend",
        "embeddingSource",
        "provider",
        "source",
        "modelBackend",
        "runtime",
        "adapter",
    )
    for ev in events:
        payload = _payload(ev)
        event_type = str(ev.get("type") or "event")
        for field in source_fields:
            value = payload.get(field)
            if isinstance(value, str) and any(token in value.lower() for token in ("mock", "stub", "fixture")):
                markers.add(f"{event_type}: {value}")
        if payload.get("devMock") is True or payload.get("mock") is True:
            markers.add(event_type)
    return sorted(markers)


# ---------------------------------------------------------------------------
# Long-term memory helpers
# (Added by commit c94f87e; moved here so client + dev memory panels share.)
# ---------------------------------------------------------------------------

_REDACTED_PLACEHOLDER = "<redacted>"

_LTM_COLLECTIONS = {"agent_memory_facts", "chat_messages"}

_MEMORY_SKIP_REASON_LABELS: dict[str, str] = {
    "no_user_id": "No signed-in user — long-term memory writes require a JWT `sub`.",
    "empty_assistant_reply": "Assistant reply was empty — nothing to extract facts from.",
    "agent_memory_disabled": "Agent has `memory.longTerm: false` — write path is intentionally inert.",
    "mongodb_unavailable": "MongoDB was unreachable — write was skipped (and the AgentCore fallback was not attempted or also failed).",
    "no_fact_candidates": "Extractor found no candidate facts in this turn.",
    "llm_extractor_failed": "The fact-extractor model errored — see diagnostics below.",
    "duplicates_only": "Every candidate fact already existed (matched on `factHash`).",
    "no_fact_acceptance": "Extractor returned candidates but none matched curation rules.",
}


def _is_redacted(value: Any) -> bool:
    return isinstance(value, str) and value == _REDACTED_PLACEHOLDER


def _any_redacted(events: list[dict]) -> bool:
    """True if any LTM event carries a `<redacted>` string field."""
    for e in events:
        p = _payload(e)
        if _is_redacted(p.get("queryText")):
            return True
        if any(_is_redacted(f) for f in (p.get("facts") or [])):
            return True
        if any(_is_redacted((c or {}).get("text")) for c in (p.get("factCandidates") or []) if isinstance(c, dict)):
            return True
        if any(_is_redacted(f) for f in (p.get("factsExtracted") or [])):
            return True
    return False


def _human_skip_reason(reason: Any) -> str:
    key = str(reason or "").strip()
    return _MEMORY_SKIP_REASON_LABELS.get(key, f"Write skipped — `{key or 'unknown'}`")


def _redaction_banner(events: list[dict]) -> None:
    if not _any_redacted(events):
        return
    st.info(
        "Fact values are redacted in this trace. Set `MEMORY_TRACE_VALUES=1` on the API "
        "(then redeploy or restart `multiagent-api`) to surface raw text. Counts, latencies, "
        "models, and error classes are never gated."
    )


def _redacted_or_text(value: Any, *, max_chars: int | None = None) -> str:
    """Inline placeholder for redacted strings; otherwise short_text or str."""
    if _is_redacted(value):
        return "*<redacted>*"
    if value is None:
        return "_(none)_"
    if max_chars:
        short = _short_text(value, max_chars)
        return short or "_(empty)_"
    text = value if isinstance(value, str) else str(value)
    return text or "_(empty)_"


def _resolve_user_message_for_write(events: list[dict], write_event: dict) -> tuple[str, str]:
    """Pick the user input text that produced this write.

    Returns (label, source) where label is rendered markdown and source describes
    where it came from. ChatTurnStartPayload does NOT carry the user text — we
    pull from the nearest preceding `model.request` event (always present,
    never gated by MEMORY_TRACE_VALUES). Falls back to the read's `queryText`
    if not redacted, then to a "not in trace" sentinel.
    """
    write_ts = int(write_event.get("ts") or 0)
    # `model.request` is a span — start events carry `userMessage`, end events
    # have an empty payload. Filter to events that actually carry the field so
    # we don't accidentally pick the (later, empty) end event for that span.
    requests = [
        e
        for e in events
        if e.get("type") == "model.request"
        and isinstance(_payload(e).get("userMessage"), str)
        and _payload(e).get("userMessage")
    ]
    best: dict | None = None
    for r in requests:
        rts = int(r.get("ts") or 0)
        if rts <= write_ts and (best is None or rts >= int(best.get("ts") or 0)):
            best = r
    if best is not None:
        msg = _payload(best).get("userMessage")
        return _redacted_or_text(msg, max_chars=400), "from `model.request.userMessage`"

    reads = [e for e in events if e.get("type") in ("memory.scoped_read", "memory.shared_read")]
    for r in reads:
        qt = _payload(r).get("queryText")
        if isinstance(qt, str) and qt and not _is_redacted(qt):
            return _redacted_or_text(qt, max_chars=400), "from `memory.*_read.queryText` (fallback)"

    return "_(user input not in trace)_", "no source available"


# ---------------------------------------------------------------------------
# core-mode `_omittedForCoreMode` sentinel handling
# ---------------------------------------------------------------------------
# When the page is loaded with `?include=core`, the API replaces heavy payload
# fields with `{ _omittedForCoreMode: true, bytesAvailable: N, wasRedacted?: bool }`
# sentinels. Client renderers must tolerate these by rendering a muted
# "available in developer details" caption instead of the raw value.


def is_omitted_sentinel(value: Any) -> bool:
    return isinstance(value, dict) and value.get("_omittedForCoreMode") is True


def render_omitted_sentinel(value: dict, label: str = "field") -> None:
    """Render the `_omittedForCoreMode` sentinel as a muted caption.

    Two shapes:
    - `{_omittedForCoreMode: true, wasRedacted: true}` — the source field was
      `<redacted>` (because `MEMORY_TRACE_VALUES=0` on the API) and then
      projected. Caption says "redacted by MEMORY_TRACE_VALUES".
    - `{_omittedForCoreMode: true, bytesAvailable: N}` — heavy field stripped
      by the `core` projection. Caption tells the user the bytes count and
      points at the Developer details section.
    """
    if value.get("wasRedacted") is True:
        st.caption(f"_{label}: redacted by `MEMORY_TRACE_VALUES=0`._")
        return
    bytes_available = _as_int(value.get("bytesAvailable"))
    if bytes_available:
        st.caption(
            f"_{label}: {bytes_available:,} bytes available — open **Developer details** to load._"
        )
    else:
        st.caption(f"_{label}: hidden in core view — open **Developer details** to load._")
