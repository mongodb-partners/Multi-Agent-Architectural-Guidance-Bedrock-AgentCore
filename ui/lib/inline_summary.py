"""Trace Viewer link rendered under the assistant reply."""

from __future__ import annotations

from dataclasses import dataclass, field
import json
from typing import Iterable

import streamlit as st

from lib.api_client import TraceEvent
from lib.trace_navigation import open_trace_viewer, trace_id_from_url


@dataclass
class TurnSummary:
    """Per-turn aggregate extracted from streaming TraceEvents."""

    trace_id: str | None = None
    duration_ms: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    total_tokens: int = 0
    cost_usd: float | None = None
    cost_estimate_complete: bool = True
    model_ids: list[str] = field(default_factory=list)
    tools_used: list[str] = field(default_factory=list)
    handoffs: list[tuple[str, str]] = field(default_factory=list)
    mongo_ops: list[dict] = field(default_factory=list)
    agentcore_invokes: int = 0
    agentcore_nested: int = 0
    memory_facts_read: int = 0
    memory_facts_written: int = 0
    skills_activated: list[str] = field(default_factory=list)
    error_count: int = 0
    degraded: bool = False
    classifications: list[dict] = field(default_factory=list)
    thinking_blocks: list[str] = field(default_factory=list)
    vector_searches: list[dict] = field(default_factory=list)
    # Memory-write surface: populated from memory.long_term_write /
    # memory.long_term_skip events (which land after `done` — the UI must
    # re-fetch the persisted trace doc once to pick them up; see
    # `merge_post_done_memory_events`).
    learned_facts: list[str] = field(default_factory=list)
    learned_duplicates: int = 0
    learned_embedded: int = 0
    learned_skip_reason: str | None = None
    learned_embedding_model: str | None = None

    def has_signal(self) -> bool:
        return bool(
            self.total_tokens
            or self.tools_used
            or self.handoffs
            or self.mongo_ops
            or self.agentcore_invokes
            or self.skills_activated
            or self.memory_facts_read
            or self.memory_facts_written
            or self.classifications
            or self.thinking_blocks
            or self.vector_searches
            or self.trace_id
            or self.has_memory_signal()
        )

    def has_memory_signal(self) -> bool:
        return bool(
            self.learned_facts
            or self.learned_duplicates
            or self.learned_skip_reason
        )

    def has_reasoning(self) -> bool:
        return bool(self.classifications or self.thinking_blocks)


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

_PRICE_PER_M = {
    "anthropic.claude-haiku-4-5": (0.80, 4.0),
    "anthropic.claude-sonnet-4-5": (3.0, 15.0),
    "anthropic.claude-opus-4-5": (15.0, 75.0),
}


def _model_cost(model_id: str, in_tok: int, out_tok: int) -> float | None:
    # Match the longest prefix.
    key = next(
        (k for k in _PRICE_PER_M if model_id.endswith(k) or model_id.startswith(k)),
        None,
    )
    if not key:
        return None
    pi, po = _PRICE_PER_M[key]
    return (in_tok / 1_000_000) * pi + (out_tok / 1_000_000) * po


_DOC_PREVIEW_CHARS = 180
_URL_FIELDS = ("sourceUrl", "url", "uri", "articleUrl")


def _short_text(value: object, max_chars: int = _DOC_PREVIEW_CHARS) -> str | None:
    if value is None:
        return None
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    text = text.strip()
    if not text:
        return None
    return text if len(text) <= max_chars else f"{text[:max_chars]}..."


def _list_text(value: object, max_chars: int = 80) -> list[str]:
    if isinstance(value, list):
        return [text for item in value if (text := _short_text(item, max_chars))]
    text = _short_text(value, max_chars)
    return [text] if text else []


def _first_url(doc: dict) -> str | None:
    for key in _URL_FIELDS:
        value = doc.get(key)
        if isinstance(value, str) and value.startswith(("http://", "https://")):
            return value
    return None


def _doc_preview_from_sample(doc: dict, rank: int, collection: str | None = None) -> dict:
    fields = {}
    for key in (
        "sku",
        "category",
        "brand",
        "status",
        "orderId",
        "customerEmail",
        "docId",
        "source",
        "sourceUrl",
        "url",
        "uri",
        "articleUrl",
        "role",
        "sessionId",
        "messageId",
    ):
        if key in doc:
            fields[key] = doc.get(key)

    title = next(
        (
            _short_text(doc.get(key), 120)
            for key in ("title", "name", "sku", "code", "fact", "_id", "id", "docId")
            if doc.get(key)
        ),
        None,
    )
    snippet = next(
        (
            _short_text(doc.get(key))
            for key in ("content", "fact", "description", "summary", "body", "text", "answer")
            if doc.get(key)
        ),
        None,
    )
    sources = [
        *_list_text(doc.get("_sources")),
        *_list_text(doc.get("source")),
        *_list_text(doc.get("sourceUrl")),
        *_list_text(doc.get("url")),
        *_list_text(doc.get("uri")),
        *_list_text(doc.get("articleUrl")),
        *_list_text(doc.get("path")),
    ]
    deduped_sources = list(dict.fromkeys(sources))
    return {
        "rank": rank,
        "collection": collection,
        "_id": _short_text(doc.get("_id"), 120),
        "id": _short_text(doc.get("_id") or doc.get("id") or doc.get("docId") or doc.get("messageId") or doc.get("sku"), 120),
        "score": doc.get("_score"),
        "title": title,
        "snippet": snippet,
        "sources": deduped_sources,
        "sourceUrl": _first_url(doc),
        "fields": fields,
    }


def _sample_doc_previews(result_payload: dict | None, collection: str | None) -> list[dict]:
    sample_docs = result_payload.get("sampleDocs") if isinstance(result_payload, dict) else None
    if not isinstance(sample_docs, list):
        return []
    return [
        _doc_preview_from_sample(doc, i + 1, collection)
        for i, doc in enumerate(sample_docs[:5])
        if isinstance(doc, dict)
    ]


def aggregate_summary(events: Iterable[TraceEvent]) -> TurnSummary:
    s = TurnSummary()
    cost_total = 0.0
    saw_unknown_model = False
    last_mongo_result: dict | None = None
    for ev in events:
        p = ev.payload or {}
        t = ev.type

        if t == "chat.turn.end":
            s.duration_ms = int(p.get("durationMs") or 0)
            summ = p.get("summary") or {}
            if isinstance(summ, dict):
                s.degraded = bool(summ.get("degraded"))

        elif t == "model.usage":
            s.input_tokens += int(p.get("inputTokens") or 0)
            s.output_tokens += int(p.get("outputTokens") or 0)
            s.total_tokens += int(p.get("totalTokens") or 0)
            mid = str(p.get("modelId") or "")
            if mid and mid not in s.model_ids:
                s.model_ids.append(mid)
            cost = _model_cost(mid, int(p.get("inputTokens") or 0), int(p.get("outputTokens") or 0))
            if cost is None:
                saw_unknown_model = True
            else:
                cost_total += cost

        elif t == "tool.call":
            name = str(p.get("toolName") or "")
            if p.get("phase") == "end" and name and name not in s.tools_used:
                s.tools_used.append(name)

        elif t == "handoff.decision":
            s.handoffs.append((str(p.get("fromAgentId") or ""), str(p.get("toAgentId") or "")))

        elif t == "mongo.result":
            s.mongo_ops.append(
                {
                    "docCount": int(p.get("docCount") or 0),
                    "latencyMs": int(p.get("latencyMs") or 0),
                    "status": str(p.get("status") or "ok"),
                }
            )
            last_mongo_result = p

        elif t == "skill.activated":
            name = str(p.get("name") or "")
            if name and name not in s.skills_activated:
                s.skills_activated.append(name)

        elif t == "mongo.vector_search":
            collection = p.get("collection") if isinstance(p.get("collection"), str) else None
            previews = p.get("documentPreviews")
            if not isinstance(previews, list):
                previews = []
            normalized = [pp for pp in previews if isinstance(pp, dict)]
            if not normalized:
                normalized = _sample_doc_previews(last_mongo_result, collection)
            scores = p.get("scores")
            s.vector_searches.append(
                {
                    "collection": collection,
                    "query_text": p.get("queryText"),
                    "hybrid": bool(p.get("hybrid")),
                    "hit_count": len(scores) if isinstance(scores, list) else len(normalized),
                    "previews": normalized,
                }
            )

        elif t == "memory.scoped_read" or t == "memory.shared_read":
            s.memory_facts_read += int(p.get("entryCount") or 0)

        elif t == "memory.long_term_write":
            inserted = int(p.get("docsInserted") or 0)
            s.memory_facts_written += inserted
            s.learned_duplicates += int(p.get("duplicatesSkipped") or 0)
            s.learned_embedded += int(p.get("embeddedCount") or 0)
            emb_model = p.get("embeddingModel")
            if isinstance(emb_model, str) and emb_model:
                s.learned_embedding_model = emb_model
            # factCandidates is the authoritative list of considered facts —
            # accepted ones have matched=true and no rejectedReason.
            candidates = p.get("factCandidates")
            if isinstance(candidates, list):
                for c in candidates:
                    if not isinstance(c, dict):
                        continue
                    text = c.get("text")
                    if not isinstance(text, str) or text == "<redacted>":
                        continue
                    if not c.get("matched"):
                        continue
                    if c.get("rejectedReason"):
                        continue
                    if text not in s.learned_facts:
                        s.learned_facts.append(text)

        elif t == "memory.long_term_skip":
            reason = p.get("reason")
            if isinstance(reason, str) and reason:
                s.learned_skip_reason = reason

        elif t == "agentcore.invoke":
            s.agentcore_invokes += 1

        elif t == "agentcore.nested_trace":
            s.agentcore_nested += int(p.get("eventCount") or 0)

        elif t == "agentcore.classification":
            chosen = str(p.get("chosenSpecialist") or "").strip()
            reasoning = str(p.get("reasoning") or "").strip()
            if chosen or reasoning:
                s.classifications.append(
                    {
                        "chosen": chosen,
                        "reasoning": reasoning,
                        "latency_ms": int(p.get("latencyMs") or 0),
                    }
                )

        elif t == "model.thinking_block":
            text = str(p.get("text") or "").strip()
            if text:
                s.thinking_blocks.append(text)

        elif t == "error":
            s.error_count += 1

    s.cost_usd = cost_total if cost_total > 0 else None
    s.cost_estimate_complete = not saw_unknown_model
    return s


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _tile(label: str, value: str, *, hint: str | None = None) -> None:
    hint_html = f'<div class="brand-tile-hint">{hint}</div>' if hint else ""
    st.markdown(
        f"""<div class="brand-tile">
  <div class="brand-tile-label">{label}</div>
  <div class="brand-tile-value">{value}</div>
  {hint_html}
</div>""",
        unsafe_allow_html=True,
    )


_THINKING_PREVIEW_CHARS = 280


def _preview_url(preview: dict) -> str | None:
    for value in (
        preview.get("sourceUrl"),
        preview.get("url"),
        preview.get("uri"),
        preview.get("articleUrl"),
    ):
        if isinstance(value, str) and value.startswith(("http://", "https://")):
            return value
    fields = preview.get("fields")
    if isinstance(fields, dict):
        for key in _URL_FIELDS:
            value = fields.get(key)
            if isinstance(value, str) and value.startswith(("http://", "https://")):
                return value
    sources = preview.get("sources")
    if isinstance(sources, list):
        for value in sources:
            if isinstance(value, str) and value.startswith(("http://", "https://")):
                return value
    return None


def _preview_title(preview: dict) -> str:
    return (
        _short_text(preview.get("title"), 80)
        or _short_text(preview.get("id"), 80)
        or "document"
    )


def _markdown_text(value: object) -> str:
    text = _short_text(value, 180) or ""
    return (
        text.replace("\\", "\\\\")
        .replace("`", "\\`")
        .replace("*", "\\*")
        .replace("_", "\\_")
        .replace("[", "\\[")
        .replace("]", "\\]")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _vector_search_signature(search: dict) -> str:
    previews = search.get("previews")
    preview_bits: list[str] = []
    if isinstance(previews, list):
        for preview in previews[:5]:
            if isinstance(preview, dict):
                preview_bits.append(
                    "|".join(
                        str(preview.get(key) or "")
                        for key in ("rank", "collection", "id", "title", "score")
                    )
                )
    return json.dumps(
        {
            "collection": search.get("collection"),
            "query_text": search.get("query_text"),
            "hybrid": bool(search.get("hybrid")),
            "hit_count": search.get("hit_count"),
            "previews": preview_bits,
        },
        sort_keys=True,
        default=str,
    )


def _dedupe_vector_searches(searches: list[dict]) -> list[dict]:
    seen: set[str] = set()
    out: list[dict] = []
    for search in searches:
        if not isinstance(search, dict):
            continue
        sig = _vector_search_signature(search)
        if sig in seen:
            continue
        seen.add(sig)
        out.append(search)
    return out


def _render_vector_sources_panel(s: TurnSummary) -> None:
    if not s.vector_searches:
        return

    for search in _dedupe_vector_searches(s.vector_searches):
        collection = search.get("collection")
        collection_label = f" on `{collection}`" if collection else ""
        hit_count = int(search.get("hit_count") or 0)
        hit_label = "hit" if hit_count == 1 else "hits"
        if search.get("hybrid"):
            header = f"Hybrid sources from vector + lexical fusion - {hit_count} {hit_label}{collection_label}"
        else:
            header = f"Sources from vector search - {hit_count} {hit_label}{collection_label}"
        st.caption(header)

        previews = search.get("previews")
        linked = 0
        if isinstance(previews, list) and previews:
            for idx, preview in enumerate(previews[:5], 1):
                if not isinstance(preview, dict):
                    continue
                rank = preview.get("rank") if isinstance(preview.get("rank"), int) else idx
                title = _preview_title(preview)
                score = preview.get("score")
                score_label = f" - {float(score):.2f}" if isinstance(score, (int, float)) else ""
                url = _preview_url(preview)
                has_url = bool(url)
                label = f"#{rank} {title}{score_label}"
                st.markdown(f"- {_markdown_text(label)}")
                if mongo_id := _short_text(preview.get("_id"), 120):
                    st.caption(f"Mongo _id: `{_markdown_text(mongo_id)}`")
                if url:
                    st.caption(f"URL: {url}")
                if snippet := _short_text(preview.get("snippet"), 160):
                    st.caption(snippet)
                fields = preview.get("fields")
                if isinstance(fields, dict) and fields:
                    field_bits = [
                        f"{key}={_short_text(value, 80)}"
                        for key, value in list(fields.items())[:5]
                        if value is not None and _short_text(value, 80)
                    ]
                    if field_bits:
                        st.caption("Fields: " + ", ".join(field_bits))
                if has_url:
                    linked += 1
        elif hit_count == 0:
            st.caption("No vector-search documents were returned.")
        else:
            st.caption("No source document preview was recorded for these hits.")

        if hit_count > 0 and linked == 0:
            st.caption("No source URL recorded; showing collection and document identifiers when available.")


_MEMORY_SKIP_LABELS = {
    "no_user_id": "no signed-in user — memory write skipped",
    "empty_assistant_reply": "assistant reply was empty — nothing to learn from",
    "no_fact_candidates": "the extractor found no personal facts in this turn",
    "duplicates_only": "nothing new — every candidate was a duplicate of a saved fact",
    "llm_extractor_failed": "the fact extractor model errored — no facts were added",
    "no_fact_acceptance": "extractor returned candidates but none matched curation rules",
}


def _render_memory_panel(s: TurnSummary, trace_id: str | None = None) -> None:
    """Memory-write card: what this turn taught the system about the user.

    Driven by `memory.long_term_write` / `memory.long_term_skip` events.
    Those land AFTER the SSE `done` event, so the caller must merge a
    post-`done` trace fetch into the streamed events before aggregating
    (see `merge_post_done_memory_events`).

    When `trace_id` is supplied and we've never toasted this trace before
    in this session, also emit a non-blocking `st.toast()`. This makes new
    memory writes a visible event without forcing the user to expand the
    Memory card.
    """
    if not s.has_memory_signal():
        return

    toast_seen: set[str] = st.session_state.setdefault("_memory_toast_seen", set())
    should_toast = bool(trace_id and trace_id not in toast_seen)

    if s.learned_facts:
        count = len(s.learned_facts)
        header = f":material/psychology: Learned {count} new fact{'s' if count != 1 else ''}"
        with st.expander(header, expanded=False):
            for fact in s.learned_facts:
                st.markdown(f"- {_markdown_text(fact)}")
            meta_bits: list[str] = []
            if s.learned_duplicates:
                meta_bits.append(f"{s.learned_duplicates} duplicate{'s' if s.learned_duplicates != 1 else ''} skipped")
            if s.learned_embedded:
                meta_bits.append(f"{s.learned_embedded} embedded")
            if s.learned_embedding_model:
                meta_bits.append(f"model: {s.learned_embedding_model}")
            if meta_bits:
                st.caption(" · ".join(meta_bits))
        if should_toast:
            preview = s.learned_facts[0]
            if len(preview) > 80:
                preview = preview[:77] + "..."
            extra = f" (+{count - 1} more)" if count > 1 else ""
            st.toast(f"Memory updated · {preview}{extra}", icon=":material/psychology:")
            toast_seen.add(trace_id or "")
    elif s.learned_skip_reason:
        label = _MEMORY_SKIP_LABELS.get(
            s.learned_skip_reason,
            f"memory write skipped ({s.learned_skip_reason})",
        )
        st.caption(f":material/psychology: {label}")


def merge_post_done_memory_events(
    streamed: list[TraceEvent],
    persisted_doc: dict | None,
) -> list[TraceEvent]:
    """Augment streamed SSE trace events with post-`done` memory events.

    The `memory.long_term_write` / `memory.long_term_skip` events emit AFTER
    the SSE `done` event because fact extraction is intentionally dangling
    (off the user's clock). The trace doc is re-persisted once that microtask
    completes, so a fresh `GET /traces/:id` ~1-2 s after `done` exposes them.
    This helper splices those events onto the streamed list without disturbing
    existing ones.
    """
    if not persisted_doc:
        return streamed
    persisted_events = persisted_doc.get("events")
    if not isinstance(persisted_events, list):
        return streamed
    seen_keys = {(ev.type, ev.id) for ev in streamed}
    extras: list[TraceEvent] = []
    for raw in persisted_events:
        if not isinstance(raw, dict):
            continue
        if raw.get("type") not in ("memory.long_term_write", "memory.long_term_skip"):
            continue
        key = (raw.get("type"), raw.get("id") or "")
        if key in seen_keys:
            continue
        extras.append(
            TraceEvent(
                type=str(raw.get("type") or ""),
                id=str(raw.get("id") or ""),
                ts=int(raw.get("ts") or 0),
                payload=raw.get("payload") or {},
                parent_id=raw.get("parentId"),
                agent_id=raw.get("agentId"),
                duration_ms=raw.get("durationMs"),
            )
        )
    if not extras:
        return streamed
    return [*streamed, *extras]


def _render_reasoning_panel(s: TurnSummary) -> None:
    """Inline reasoning surface: classification + extended-thinking blocks.

    Lives inside the assistant message so it stays attached to the reply
    on replay (see chat_panel.render_message_history → render_inline_summary).
    Both signals are collapsed by default so they don't dominate the chat.
    """
    if not s.has_reasoning():
        return

    parts: list[str] = []
    if s.classifications:
        parts.append(
            f"{len(s.classifications)} routing decision"
            f"{'s' if len(s.classifications) != 1 else ''}"
        )
    if s.thinking_blocks:
        parts.append(
            f"{len(s.thinking_blocks)} thinking block"
            f"{'s' if len(s.thinking_blocks) != 1 else ''}"
        )
    header = ":material/psychology: Reasoning — " + " · ".join(parts)

    with st.expander(header, expanded=False):
        for i, c in enumerate(s.classifications, 1):
            chosen = c.get("chosen") or "?"
            latency = int(c.get("latency_ms") or 0)
            st.markdown(
                f"**Routing #{i}** → `{chosen}`"
                + (f" · {latency} ms" if latency else "")
            )
            reasoning = (c.get("reasoning") or "").strip()
            if reasoning:
                st.markdown(f"> {reasoning}")
            else:
                st.caption("_(no orchestrator reasoning emitted)_")
        for i, block in enumerate(s.thinking_blocks, 1):
            preview = block[:_THINKING_PREVIEW_CHARS]
            truncated = len(block) > _THINKING_PREVIEW_CHARS
            label = (
                f":material/lightbulb: Thinking block #{i}"
                f" ({len(block):,} chars)" if truncated else f":material/lightbulb: Thinking block #{i}"
            )
            with st.expander(label, expanded=False):
                if truncated:
                    st.caption(
                        f"Showing first {_THINKING_PREVIEW_CHARS} chars — full text below."
                    )
                    st.markdown(preview + "…")
                    st.text_area(
                        "Full thinking",
                        value=block,
                        height=200,
                        key=f"thinking_full_{id(s)}_{i}",
                        disabled=True,
                    )
                else:
                    st.markdown(block)


def render_inline_summary(
    s: TurnSummary,
    *,
    trace_url: str | None = None,
    trace_id: str | None = None,
    raw_events: list[TraceEvent] | None = None,
) -> None:
    """Render only the Trace Viewer button under an assistant reply."""
    if not s.has_signal():
        return

    _ = raw_events  # Metrics and raw events intentionally live only in Trace Viewer.
    _render_vector_sources_panel(s)
    tid = trace_id or trace_id_from_url(trace_url)
    _render_memory_panel(s, trace_id=tid)
    if tid and st.button("View full trace →", key=f"view_full_trace_{tid}"):
        open_trace_viewer(tid)


def _event_to_json(ev: TraceEvent) -> dict:
    return {
        "id": ev.id,
        "ts": ev.ts,
        "type": ev.type,
        "parentId": ev.parent_id,
        "agentId": ev.agent_id,
        "durationMs": ev.duration_ms,
        "payload": ev.payload,
    }
