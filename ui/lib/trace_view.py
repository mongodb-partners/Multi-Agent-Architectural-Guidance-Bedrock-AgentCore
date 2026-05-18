"""Trace Viewer rendering functions.

Each `render_*` function takes a list of events (or a slice) and renders one
section of the Trace Viewer page. The Trace Viewer page composes them.

Tier hierarchy:
 1. Tiles + banners (always visible)
 2. Section blocks (expander-collapsed by default for low-priority)
 3. Developer details (full raw JSON)
"""

from __future__ import annotations

import json
import re
from typing import Any

from collections import defaultdict
import streamlit as st


# ---------------------------------------------------------------------------
# Helpers
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


def render_mock_banner(events: list[dict]) -> None:
    """Show when a trace includes mock/dev backend data."""
    markers = _mock_markers(events)
    if not markers:
        return

    shown = ", ".join(markers[:3])
    suffix = f", +{len(markers) - 3} more" if len(markers) > 3 else ""
    st.info(f"Mock/dev backend data detected in this trace: {shown}{suffix}")


# ---------------------------------------------------------------------------
# 1. Summary header
# ---------------------------------------------------------------------------

def summary_tiles(trace: dict) -> list[str]:
    """Build the high-signal top tiles for a trace document."""
    summary = trace.get("summary") or {}
    events = trace.get("events") or []
    tiles: list[str] = []

    end_payloads = [_payload(e) for e in _events_of(events, "chat.turn.end")]
    duration_ms = _as_int(summary.get("durationMs"))
    if not duration_ms and end_payloads:
        duration_ms = _as_int(end_payloads[-1].get("durationMs"))
    if duration_ms:
        tiles.append(_tile_html("Latency", f"{duration_ms / 1000:.2f}s"))

    agentcore_invokes = _events_of(events, "agentcore.invoke")
    agentcore_count = max(_as_int(summary.get("agentcoreHops")), _completed_span_count(agentcore_invokes))
    if agentcore_count:
        runtime_ms = _as_int(summary.get("agentcoreRuntimeMs"))
        if not runtime_ms:
            runtime_ms = sum(_as_int(_payload(e).get("latencyMs")) for e in agentcore_invokes)
        hint = f"{runtime_ms / 1000:.1f}s runtime" if runtime_ms else None
        tiles.append(
            _tile_html(
                "AgentCore",
                f"{agentcore_count} hop{'s' if agentcore_count != 1 else ''}",
                hint=hint,
            )
        )

    writes = _events_of(events, "memory.long_term_write")
    skips = _events_of(events, "memory.long_term_skip")
    reads = _events_of(events, "memory.scoped_read", "memory.shared_read")
    stored = sum(_as_int(_payload(e).get("docsInserted")) for e in writes)
    if stored:
        outcomes = [str(_payload(e).get("primaryOutcome") or "") for e in writes]
        hint = ", ".join(x for x in outcomes if x) or None
        tiles.append(_tile_html("Memory", f"{stored} stored", hint=hint))
    elif skips:
        reason = str(_payload(skips[-1]).get("reason") or "skipped")
        tiles.append(_tile_html("Memory", "Skipped", hint=reason))
    elif reads:
        read_count = sum(_as_int(_payload(e).get("entryCount")) for e in reads)
        if read_count:
            tiles.append(_tile_html("Memory", f"{read_count} read"))

    mongo_results = _events_of(events, "mongo.result")
    vector_searches = _events_of(events, "mongo.vector_search")
    mongo_count = (
        _as_int(summary.get("mongoQueriesCount"))
        or _as_int(summary.get("mongoQueries"))
        or len(mongo_results) + len(vector_searches)
    )
    if mongo_count:
        ok = sum(1 for e in mongo_results if _payload(e).get("status") != "error")
        docs = _as_int(summary.get("mongoDocsReturned")) or sum(_as_int(_payload(e).get("docCount")) for e in mongo_results)
        vector_hits = sum(len(_payload(e).get("scores") or []) for e in vector_searches)
        if mongo_results:
            value = f"{ok}/{mongo_count} ok"
        elif vector_searches:
            value = f"{len(vector_searches)} vector search{'es' if len(vector_searches) != 1 else ''}"
        else:
            value = str(mongo_count)
        hints = []
        if docs:
            hints.append(f"{docs} doc(s)")
        if vector_searches:
            hints.append(f"{len(vector_searches)} vector · {vector_hits} hit(s)")
        tiles.append(_tile_html("MongoDB", value, hint=", ".join(hints) or None))

    tool_events = _events_of(events, "tool.call")
    tool_count = max(_as_int(summary.get("toolCalls")), _completed_span_count(tool_events))
    if tool_count:
        tiles.append(_tile_html("Tools", f"{tool_count} call{'s' if tool_count != 1 else ''}"))

    usage_events = _events_of(events, "model.usage")
    total_tokens = _as_int(summary.get("totalTokens")) or sum(_as_int(_payload(e).get("totalTokens")) for e in usage_events)
    input_tokens = _as_int(summary.get("inputTokens")) or sum(_as_int(_payload(e).get("inputTokens")) for e in usage_events)
    output_tokens = _as_int(summary.get("outputTokens")) or sum(_as_int(_payload(e).get("outputTokens")) for e in usage_events)
    if total_tokens:
        tiles.append(_tile_html("Tokens", f"{total_tokens:,}", hint=f"{input_tokens:,} in / {output_tokens:,} out"))

    cost = summary.get("estimatedCostUsd")
    if cost is not None:
        mark = "" if summary.get("costEstimateComplete", True) else "≈"
        tiles.append(_tile_html("Cost", f"{mark}${float(cost):.4f}"))

    error_count = len(_events_of(events, "error"))
    error_count += sum(1 for e in mongo_results if _payload(e).get("status") == "error")
    error_count += sum(1 for e in agentcore_invokes if _payload(e).get("errorMessage"))
    if error_count:
        tiles.append(_tile_html("Errors", str(error_count), hint="See details below"))

    return tiles


def render_summary_header(trace: dict) -> None:
    summary = trace.get("summary") or {}
    tiles = summary_tiles(trace)
    if summary.get("modelIds"):
        models = summary["modelIds"]
        tiles.append(_tile_html("Model", models[0] if len(models) == 1 else f"{len(models)} models"))
    if summary.get("toolsUsed"):
        tiles.append(
            _tile_html(
                "Tools",
                str(len(summary["toolsUsed"])),
                hint=", ".join(summary["toolsUsed"][:2]),
            )
        )
    if tiles:
        st.markdown("".join(tiles), unsafe_allow_html=True)
    if _trace_is_truncated(trace):
        dropped = _trace_events_dropped(trace)
        suffix = f" ({dropped} event(s) dropped)" if dropped else ""
        st.warning(f"This trace was byte-capped — some payload details were trimmed or events were dropped{suffix}.")


# ---------------------------------------------------------------------------
# 2. Timeline (Gantt-style, lightweight HTML)
# ---------------------------------------------------------------------------

def render_timeline(events: list[dict]) -> None:
    if not events:
        return
    starts = [int(e.get("ts") or 0) for e in events]
    t0 = min(starts) if starts else 0
    t1 = max(int(e.get("ts") or 0) + int(e.get("durationMs") or 0) for e in events) if events else t0
    span = max(1, t1 - t0)
    st.markdown('<div class="trace-section-title">Timeline</div>', unsafe_allow_html=True)
    rows_html: list[str] = []
    for ev in events:
        ts = int(ev.get("ts") or 0)
        d = int(ev.get("durationMs") or 0)
        left = (ts - t0) / span * 100
        width = max(0.5, d / span * 100)
        rows_html.append(
            f"""
<div style="display:flex; align-items:center; margin-bottom:3px;">
  <div style="width:170px; font-size:11px; opacity:0.7; padding-right:8px;">{ev.get('type')}</div>
  <div style="flex:1; height:14px; background:rgba(255,255,255,0.05); border-radius:4px; position:relative;">
    <div style="position:absolute; left:{left}%; width:{width}%; height:100%; background:cornflowerblue; border-radius:4px;"
         title="{ev.get('type')} — {d} ms"></div>
  </div>
  <div style="width:60px; font-size:11px; text-align:right; opacity:0.6; padding-left:8px;">{d} ms</div>
</div>"""
        )
    st.markdown("".join(rows_html), unsafe_allow_html=True)


# ---------------------------------------------------------------------------
# 4. Routing / handoff attribution
# ---------------------------------------------------------------------------

def render_context(events: list[dict]) -> None:
    """Show request enrichment that happened before the model ran."""
    starts = _events_of(events, "chat.turn.start")
    auth = _events_of(events, "auth.context_build")
    if not (starts or auth):
        return
    st.markdown('<div class="trace-section-title">Request context</div>', unsafe_allow_html=True)
    for s in starts[:1]:
        sp = _payload(s)
        st.caption(
            f"Session `{sp.get('sessionId', '?')}` · message `{sp.get('messageId', '?')}` · "
            f"user `{str(sp.get('userId') or 'anonymous')[:28]}`"
        )
    for a in auth:
        ap = _payload(a)
        st.markdown(
            f"🔐 **Authenticated user context** — {ap.get('customersResolved', 0)} customer(s), "
            f"{ap.get('ordersResolved', 0)} order(s) resolved from MongoDB"
        )


def render_prompt_and_skills(events: list[dict]) -> None:
    prompts = _events_of(events, "prompt.assembled")
    skills = _events_of(events, "skill.activated")
    activations = _events_of(events, "agent.activate")
    if not (prompts or skills or activations):
        return
    st.markdown('<div class="trace-section-title">Prompt, skills, and agents</div>', unsafe_allow_html=True)
    for a in activations:
        ap = _payload(a)
        st.caption(
            f"Agent active: `{ap.get('agentId')}`"
            f"{' (specialist)' if ap.get('specialist') else ''}"
            f"{' · suppressed from chat' if ap.get('suppressed') else ''}"
        )
    for p in prompts:
        pp = _payload(p)
        st.markdown(
            f"🧩 **Prompt assembled** — {pp.get('totalBytes', 0)} B "
            f"(persona {pp.get('personaBytes', 0)} B, discovery {pp.get('discoveryBytes', 0)} B, "
            f"memory {pp.get('memoryContextBytes', 0)} B)"
        )
        activated = pp.get("activatedSkills") or []
        if activated:
            with st.expander(f"Prompt-injected skills ({len(activated)})", expanded=False):
                _render_jsonish(activated)
    if skills:
        with st.expander(f"Skill activations ({len(skills)})", expanded=False):
            for s in skills:
                sp = _payload(s)
                allowed = "allowed" if sp.get("allowed", True) else "blocked"
                st.markdown(
                    f"- `{sp.get('name')}` via `{sp.get('source')}` · "
                    f"{sp.get('bytes', 0)} B · {allowed}"
                )


def render_model_activity(events: list[dict]) -> None:
    requests = _events_of(events, "model.request")
    usage = _events_of(events, "model.usage")
    stops = _events_of(events, "model.stop")
    thinking = _events_of(events, "model.thinking_block")
    deltas = _events_of(events, "model.text_delta_batch")
    batches = _events_of(events, "tools.batch")
    conversation = _events_of(events, "conversation.message_added")
    if not (requests or usage or stops or thinking or deltas or batches or conversation):
        return
    st.markdown('<div class="trace-section-title">Model activity</div>', unsafe_allow_html=True)
    for i, req in enumerate(requests):
        rp = _payload(req)
        up = _payload(usage[i]) if i < len(usage) else {}
        stop = _payload(stops[i]).get("stopReason") if i < len(stops) else None
        with st.expander(
            f"🤖 `{rp.get('modelId', '?')}` via `{rp.get('backend', '?')}`"
            f" — {up.get('totalTokens', 0)} token(s)"
            f"{f' · stop `{stop}`' if stop else ''}",
            expanded=i == 0,
        ):
            st.caption(
                f"System prompt {rp.get('systemPromptBytes', 0)} B · "
                f"prior turns {rp.get('priorTurnsCount', 0)} · "
                f"hash `{rp.get('systemPromptHash', '?')}`"
            )
            if up:
                st.json(
                    {
                        "inputTokens": up.get("inputTokens", 0),
                        "outputTokens": up.get("outputTokens", 0),
                        "totalTokens": up.get("totalTokens", 0),
                        "latencyMs": up.get("latencyMs"),
                        "timeToFirstByteMs": up.get("timeToFirstByteMs"),
                    }
                )
    if thinking:
        with st.expander(f"Thinking blocks ({len(thinking)})", expanded=False):
            for t in thinking:
                tp = _payload(t)
                st.code(str(tp.get("text") or "")[:2000], language=None)
    if deltas or batches or conversation:
        st.caption(
            f"Streamed {len(deltas)} text batch(es), emitted {len(batches)} tool batch event(s), "
            f"and recorded {len(conversation)} conversation message event(s)."
        )


def render_routing(events: list[dict]) -> None:
    decisions = _events_of(events, "handoff.decision")
    if not decisions:
        return
    st.markdown('<div class="trace-section-title">Routing decisions</div>', unsafe_allow_html=True)
    for d in decisions:
        p = d.get("payload") or {}
        fr, to = p.get("fromAgentId"), p.get("toAgentId")
        conf = p.get("confidence")
        chips: list[str] = []
        if conf is not None:
            chips.append(f'<span class="trace-chip">confidence {float(conf):.2f}</span>')
        triggers = p.get("triggerSpans") or []
        for t in triggers[:6]:
            tx = t.get("text") if isinstance(t, dict) else str(t)
            chips.append(f'<span class="trace-chip">{tx}</span>')
        st.markdown(
            f"**`{fr}` → `{to}`**<br>{' '.join(chips)}",
            unsafe_allow_html=True,
        )
        alts = p.get("alternativesConsidered") or []
        if alts:
            with st.expander(f"Alternatives considered ({len(alts)})", expanded=False):
                for alt in alts:
                    st.markdown(f"- **{alt.get('agentId')}** — score {alt.get('score', 0):.2f}")


# ---------------------------------------------------------------------------
# 5. MongoDB dashboard
# ---------------------------------------------------------------------------

def render_mongo_dashboard(events: list[dict]) -> None:
    intents = _events_of(events, "mongo.intent")
    queries = _events_of(events, "mongo.query")
    results = _events_of(events, "mongo.result")
    plans = _events_of(events, "mongo.plan")
    diags = _events_of(events, "mongo.diagnostic")
    schemas = _events_of(events, "mongo.schema")
    vectors = _events_of(events, "mongo.vector_search")
    if not (intents or queries or vectors or results):
        return
    st.markdown('<div class="trace-section-title">MongoDB</div>', unsafe_allow_html=True)
    if intents:
        with st.expander(f"Collections used ({len(intents)})", expanded=False):
            for intent in intents:
                ip = _payload(intent)
                st.markdown(f"- Collection `{ip.get('collection', '?')}`")
                if ip.get("triggeringUserMessage"):
                    st.caption(f"User message: {ip.get('triggeringUserMessage')}")
                if ip.get("thinkingSnippet"):
                    st.caption(f"Thinking: {ip.get('thinkingSnippet')}")
                if ip.get("skillInstructionSnippet"):
                    st.caption(f"Skill instruction: {ip.get('skillInstructionSnippet')}")
    # Pair query+result by index — they're emitted in order.
    for i, q in enumerate(queries):
        qp = _payload(q)
        rp = _payload(results[i]) if i < len(results) else {}
        emoji = {"ok": "✅", "empty": "∅", "error": "❌"}.get(rp.get("status", ""), "·")
        with st.expander(
            f"{emoji} #{i + 1} {qp.get('op')} on `{qp.get('collection')}` — "
            f"{rp.get('docCount', 0)} doc(s) in {rp.get('latencyMs', 0)} ms",
            expanded=i == 0,
        ):
            cfilter = qp.get("filter") or qp.get("normalizedFilter")
            if cfilter:
                st.code(json.dumps(cfilter, indent=2, default=str), language="json")
            if rp.get("sampleDocs"):
                st.caption("Sample documents")
                _render_jsonish(rp["sampleDocs"])
            if rp.get("status") == "error":
                st.error(rp.get("errorMessage") or "MongoDB error")
            # Match this query's diagnostic and plan, if present.
            if i < len(plans):
                pp = (plans[i].get("payload") or {})
                if pp:
                    st.caption(
                        f"Plan: stage={pp.get('stage') or '?'} · "
                        f"selectivity={pp.get('selectivity') if pp.get('selectivity') is not None else '?'} · "
                        f"executionTimeMillis={pp.get('executionTimeMillis') or '?'}"
                    )
            if i < len(diags):
                dp = (diags[i].get("payload") or {})
                if dp.get("offendingClause"):
                    o = dp["offendingClause"]
                    st.warning(
                        f"Offending clause: `{o.get('field')} {o.get('op')} {o.get('value')}` — "
                        f"{o.get('countWith', 0)} with vs {o.get('countWithout', 0)} without"
                    )
                if dp.get("valueTypeWarnings"):
                    for w in dp["valueTypeWarnings"]:
                        st.caption(f"⚠️ {w.get('kind')} on `{w.get('field')}` — {w.get('detail')}")

    for v in vectors:
        vp = _payload(v)
        embed_src = vp.get("embeddingSource") or "?"
        embed_model = vp.get("embeddingModelId")
        embed_label = f"{embed_src}" + (f" ({embed_model})" if embed_model else "")
        collection_label = f" on `{vp.get('collection')}`" if vp.get("collection") else ""
        scores = vp.get("scores")
        hit_count = len(scores) if isinstance(scores, list) else 0
        with st.expander(
            f"🧭 vector_search{collection_label} — embed via {embed_label} — {hit_count} hit(s)",
            expanded=False,
        ):
            if vp.get("queryText") is not None:
                query_text = vp.get("queryText")
                if isinstance(query_text, str):
                    st.caption(f"Query: {query_text}")
                else:
                    st.caption("Query")
                    _render_jsonish(query_text)
            preview = vp.get("queryVectorPreview")
            if isinstance(preview, dict):
                head = preview.get("head") or []
                tail = preview.get("tail") or []
                if isinstance(head, list) and isinstance(tail, list):
                    head_str = ", ".join(f"{float(x):.4f}" for x in head if isinstance(x, (int, float)))
                    tail_str = ", ".join(f"{float(x):.4f}" for x in tail if isinstance(x, (int, float)))
                    preview_str = f"{head_str}, …, {tail_str}" if tail_str else head_str
                    if preview_str:
                        st.caption(f"Vector ({preview.get('length')} dims): [{preview_str}]")
                else:
                    st.caption("Vector preview")
                    _render_jsonish(preview)
            elif preview:
                st.caption("Vector preview")
                _render_jsonish(preview)
            tune_bits = []
            if vp.get("limit") is not None:
                tune_bits.append(f"limit={vp['limit']}")
            if vp.get("numCandidates") is not None:
                tune_bits.append(f"numCandidates={vp['numCandidates']}")
            if vp.get("filter"):
                vfilter = vp["filter"]
                if isinstance(vfilter, (dict, list)):
                    tune_bits.append(f"filter={json.dumps(vfilter, default=str)}")
                else:
                    tune_bits.append("filter recorded separately")
            if tune_bits:
                st.caption(" · ".join(tune_bits))
            if vp.get("filter") and not isinstance(vp.get("filter"), (dict, list)):
                st.caption("Filter")
                _render_jsonish(vp.get("filter"))
            if isinstance(vp.get("scoreSummary"), dict):
                ss = vp["scoreSummary"]
                try:
                    st.caption(
                        f"Scores — min {float(ss.get('min', 0)):.3f}, "
                        f"max {float(ss.get('max', 0)):.3f}, avg {float(ss.get('avg', 0)):.3f}"
                    )
                except (TypeError, ValueError):
                    st.caption("Score summary")
                    _render_jsonish(ss)
            elif vp.get("scoreSummary"):
                st.caption("Score summary")
                _render_jsonish(vp.get("scoreSummary"))
            if isinstance(vp.get("histogram"), list) and vp.get("histogram"):
                hist = vp["histogram"]
                cols = st.columns(len(hist))
                for j, count in enumerate(hist):
                    with cols[j]:
                        label = _VECTOR_SCORE_BINS[j] if j < len(_VECTOR_SCORE_BINS) else f"bin {j + 1}"
                        st.metric(label, count if isinstance(count, (int, float)) else str(count))
                st.caption(
                    "Explicit classification criteria: each retrieved score is bucketed by fixed similarity range; "
                    "higher bins mean closer vector matches."
                )
            elif vp.get("histogram"):
                st.caption("Score histogram")
                _render_jsonish(vp.get("histogram"))
            result_payload = _nearest_vector_result_payload(events, v)
            _render_vector_document_previews(_vector_document_previews(vp, result_payload))

    if schemas:
        with st.expander(f"Schema samples ({len(schemas)})", expanded=False):
            for s in schemas:
                sp = s.get("payload") or {}
                st.markdown(
                    f"**{sp.get('collection')}** — {sp.get('estimatedDocumentCount', 0)} estimated docs"
                )
                if sp.get("fields"):
                    _render_jsonish([{"name": f.get("name"), "type": f.get("type")} for f in sp["fields"][:30]])


# ---------------------------------------------------------------------------
# 6. Tool calls
# ---------------------------------------------------------------------------

def render_tool_calls(events: list[dict]) -> None:
    spans: list[dict[str, Any]] = []
    starts_by_id: dict[str, dict[str, Any]] = {}
    starts_by_tool_use_id: dict[str, dict[str, Any]] = {}
    for e in _events_of(events, "tool.call"):
        p = e.get("payload") or {}
        name = str(p.get("toolName") or "?")
        if p.get("phase") == "start" or (e.get("durationMs") is None and ("input" in p or "toolUseId" in p)):
            record = {"name": name, "start": p, "end": {}}
            starts_by_id[str(e.get("id"))] = record
            if p.get("toolUseId"):
                starts_by_tool_use_id[str(p.get("toolUseId"))] = record
        elif p.get("phase") == "end" or e.get("durationMs") is not None:
            record = starts_by_id.get(str(e.get("parentId")))
            if not record and p.get("toolUseId"):
                record = starts_by_tool_use_id.get(str(p.get("toolUseId")))
            if not record:
                record = {"name": name, "start": {}, "end": {}}
            record["end"] = p
            record["durationMs"] = e.get("durationMs")
            spans.append(record)
    https = _events_of(events, "tool.http")
    mcps = _events_of(events, "tool.mcp")
    if not (spans or https or mcps):
        return
    st.markdown('<div class="trace-section-title">Tool calls</div>', unsafe_allow_html=True)
    for info in spans:
        name = info.get("name") or "?"
        end = info.get("end") or {}
        duration = end.get("latencyMs", info.get("durationMs", 0))
        with st.expander(f"🔧 `{name}` — {duration or 0} ms", expanded=False):
            if (info.get("start") or {}).get("input"):
                st.caption("Input")
                _render_jsonish((info["start"] or {}).get("input"))
            if end.get("result") is not None:
                st.caption("Result")
                _render_jsonish(end["result"])
            if end.get("error"):
                st.error(end["error"].get("message") or "Tool error")
    for h in https:
        hp = h.get("payload") or {}
        emoji = "❌" if hp.get("blocked") or hp.get("errorClass") else f"📡 {hp.get('status') or '?'}"
        with st.expander(
            f"{emoji} HTTP {hp.get('method')} {hp.get('url')}", expanded=False
        ):
            if hp.get("body"):
                _render_jsonish(hp["body"])
            if hp.get("responseSnippet"):
                st.caption(f"Response (first {len(hp.get('responseSnippet', ''))} chars)")
                st.code(hp["responseSnippet"], language=None)
            if hp.get("blocked"):
                st.warning(f"Blocked: {hp.get('blocked')}")
    for m in mcps:
        mp = m.get("payload") or {}
        emoji = "❌" if mp.get("errorClass") else "🛰"
        with st.expander(
            f"{emoji} MCP {mp.get('toolName')} on `{mp.get('server')}` ({mp.get('transport')})",
            expanded=False,
        ):
            if mp.get("args") is not None:
                _render_jsonish(mp["args"])
            if mp.get("result") is not None:
                _render_jsonish(mp["result"])
            if mp.get("errorMessage"):
                st.error(mp["errorMessage"])


# ---------------------------------------------------------------------------
# 7. AgentCore deep tracing
# ---------------------------------------------------------------------------

def render_agentcore(events: list[dict]) -> None:
    invokes = _events_of(events, "agentcore.invoke")
    classifications = _events_of(events, "agentcore.classification")
    nested_meta = _events_of(events, "agentcore.nested_trace")
    obs = _events_of(events, "agentcore.observability_link")
    gw = _events_of(events, "agentcore.gateway")
    if not (invokes or classifications):
        return
    st.markdown('<div class="trace-section-title">AgentCore runtime</div>', unsafe_allow_html=True)
    for c in classifications:
        cp = c.get("payload") or {}
        st.markdown(
            f"**Classification** → `{cp.get('chosenSpecialist')}` "
            f"({int(cp.get('latencyMs', 0))} ms)"
        )
        if cp.get("reasoning"):
            with st.expander("Reasoning", expanded=False):
                st.write(cp["reasoning"])
    for inv in invokes:
        ip = inv.get("payload") or {}
        emoji = "✅" if not ip.get("errorMessage") else "❌"
        with st.expander(
            f"{emoji} {ip.get('mode')} → `{ip.get('targetAgentId') or '?'}` "
            f"({int(ip.get('latencyMs', 0))} ms · {ip.get('responseBytes', 0)}B)",
            expanded=False,
        ):
            st.caption(f"ARN: `{ip.get('arn')}`")
            if ip.get("runtimeSessionId"):
                st.caption(f"Session: `{ip.get('runtimeSessionId')}`")
            if ip.get("errorMessage"):
                st.error(f"{ip.get('errorClass')}: {ip.get('errorMessage')}")
            if ip.get("payload"):
                _render_jsonish(ip["payload"])
    for nm in nested_meta:
        np = nm.get("payload") or {}
        st.caption(
            f"🪆 Nested trace {np.get('nestedTraceId') or 'unknown'} — {np.get('eventCount', 0)} events spliced"
        )
    for o in obs:
        op = o.get("payload") or {}
        if op.get("xrayUrl"):
            st.markdown(f"[X-Ray]({op['xrayUrl']})  ·  [CloudWatch logs]({op.get('cloudwatchLogStreamUrl') or '#'})")
    for g in gw:
        gp = g.get("payload") or {}
        st.caption(f"Gateway: target={gp.get('targetName')} · routing={gp.get('routingDecision')}")


# ---------------------------------------------------------------------------
# 8. Memory dashboard
# ---------------------------------------------------------------------------

def render_memory(events: list[dict]) -> None:
    scoped = _events_of(events, "memory.scoped_read")
    shared = _events_of(events, "memory.shared_read")
    writes = _events_of(events, "memory.long_term_write")
    skips = _events_of(events, "memory.long_term_skip")
    if not (scoped or shared or writes or skips):
        return
    st.markdown('<div class="trace-section-title">Long-term memory</div>', unsafe_allow_html=True)
    for r in scoped + shared:
        rp = r.get("payload") or {}
        kind = "Agent-scoped" if r.get("type") == "memory.scoped_read" else "Shared"
        st.markdown(
            f"📥 **{kind}** — {rp.get('entryCount', 0)} fact(s) injected "
            f"({rp.get('bytesInjected', 0)} B, backend `{rp.get('backend', '?')}`)"
        )
        if rp.get("facts"):
            with st.expander("Facts injected (gated by MEMORY_TRACE_VALUES)", expanded=False):
                for f in rp["facts"]:
                    st.markdown(f"- {f}")
    for w in writes:
        wp = w.get("payload") or {}
        st.markdown(
            f"💾 **Write** — {wp.get('docsInserted', 0)} fact(s) · `{wp.get('primaryOutcome')}` "
            f"(prior {wp.get('priorEntryCount')}, now {wp.get('newEntryCount')})"
        )
        if wp.get("extractorModelId") or wp.get("extractorLatencyMs") is not None:
            extractor_bits = ["extractor `llm`"]
            if wp.get("extractorModelId"):
                extractor_bits.append(f"model `{wp['extractorModelId']}`")
            if wp.get("extractorLatencyMs") is not None:
                extractor_bits.append(f"{wp['extractorLatencyMs']} ms")
            tok_in = wp.get("extractorInputTokens")
            tok_out = wp.get("extractorOutputTokens")
            if tok_in is not None or tok_out is not None:
                extractor_bits.append(f"tokens in/out {tok_in or 0}/{tok_out or 0}")
            st.caption(" · ".join(extractor_bits))
        if wp.get("factsExtracted"):
            with st.expander("Facts extracted", expanded=False):
                for f in wp["factsExtracted"]:
                    st.markdown(f"- {f}")
        if wp.get("factCandidates"):
            with st.expander("All candidates considered", expanded=False):
                for c in wp["factCandidates"]:
                    label_parts = c.get("matchedPatterns") or []
                    if c.get("category") and c["category"] not in label_parts:
                        label_parts = [c["category"], *label_parts]
                    label = ", ".join(label_parts)
                    note = c.get("note")
                    if c.get("matched"):
                        line = f"- ✅ `{c.get('text')}`"
                        if label:
                            line += f" ({label})"
                        if note:
                            line += f" — _{note}_"
                        st.markdown(line)
                    else:
                        line = f"- ✗ `{c.get('text')}` — {c.get('rejectedReason')}"
                        if note:
                            line += f" (_{note}_)"
                        st.markdown(line)
    for s in skips:
        sp = s.get("payload") or {}
        st.caption(f"⏭ Write skipped — {sp.get('reason')}")


# ---------------------------------------------------------------------------
# 9. Errors
# ---------------------------------------------------------------------------

def render_errors(events: list[dict]) -> None:
    errors = _events_of(events, "error")
    if not errors:
        return
    st.markdown('<div class="trace-section-title">Errors</div>', unsafe_allow_html=True)
    for e in errors:
        ep = _payload(e)
        st.error(f"{ep.get('source') or 'trace'} — {ep.get('class') or 'Error'}: {ep.get('message')}")
        if ep.get("stack"):
            with st.expander("Stack trace", expanded=False):
                st.code(ep["stack"], language=None)


# ---------------------------------------------------------------------------
# 10. Developer details (raw events)
# ---------------------------------------------------------------------------

def render_developer_details(trace: dict) -> None:
    with st.expander("Developer details — raw events", expanded=False):
        events = trace.get("events") or []
        st.caption(
            f"{len(events)} event(s) · degraded={_trace_is_truncated(trace)}"
            f" · dropped={_trace_events_dropped(trace)}"
        )
        _render_jsonish(events)


def render_trace_meta(trace: dict) -> None:
    st.caption(
        f"Trace `{trace.get('traceId', '')[:8]}…` · session `{trace.get('sessionId', '')[:8]}…`"
        f" · agent `{trace.get('agentId', '')}` · created {trace.get('createdAt', '')}"
    )