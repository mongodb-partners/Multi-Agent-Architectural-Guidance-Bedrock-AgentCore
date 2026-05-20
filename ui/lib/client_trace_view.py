"""Client-facing Trace Viewer sections.

This is the slim, demo-friendly half of what used to be `lib/trace_view.py`.
It renders only the panels we are happy to show in front of customers:

    render_mock_banner            — dev/mock backend warning
    summary_tiles                 — Latency / AgentCore / Memory / MongoDB
                                    / Tools / Tokens / Cost / Errors tiles
    render_summary_header         — tiles + truncation warning
    render_timeline               — Gantt-style HTML timeline
    render_context                — request / auth context one-liners
    render_prompt_and_skills      — "prompt assembled" + activated skills
    render_model_activity         — model.request / usage / thinking summary
    render_routing                — handoff.decision arrows
    render_mongo_dashboard        — mongo.* + vector search dashboard
    render_tool_calls             — tool.call / tool.http / tool.mcp spans
    render_agentcore              — agentcore.* invocations + observability
    render_memory                 — long-term memory read/write/skip cards
    render_errors                 — error events
    render_trace_meta             — small caption with traceId / sessionId

Anything debug-grade (raw spans, span tree, environment dump, prompt body,
agentcore response bodies, byte-cap drops, OTel link, …) lives in the
sibling module `developer_trace_view.py` and is loaded on demand.

Helpers shared with the developer module (and unit-tested directly) live in
`trace_view_helpers.py` — we never reach across to that module's *render*
functions.
"""

from __future__ import annotations

import json
import re
from typing import Any

import streamlit as st
from lib.display_labels import DB_DATA_INFO_LABEL

from lib.trace_view_helpers import (
    _VECTOR_SCORE_BINS,
    _as_int,
    _completed_span_count,
    _events_of,
    _human_skip_reason,
    _is_redacted,
    _mock_markers,
    _nearest_vector_result_payload,
    _payload,
    _redacted_or_text,
    _redaction_banner,
    _render_jsonish,
    _render_vector_document_previews,
    _resolve_user_message_for_write,
    _short_text,
    _tile_html,
    _trace_events_dropped,
    _trace_is_truncated,
    _vector_document_previews,
    is_omitted_sentinel,
    render_omitted_sentinel,
)


# ---------------------------------------------------------------------------
# 0. Mock-data banner
# ---------------------------------------------------------------------------

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
    read_entries = sum(_as_int(_payload(e).get("entryCount")) for e in reads)
    if reads or writes or skips:
        if reads:
            modes = sorted({str(_payload(r).get("mode") or "") for r in reads if _payload(r).get("mode")})
            mode_label = "/".join(modes) if modes else "read"
            value = f"{read_entries} entries" if read_entries else "0 entries"
        elif writes:
            value = f"{stored} stored"
            mode_label = "write"
        else:
            value = "Skipped"
            mode_label = "skip"
        hint_parts: list[str] = [mode_label]
        if writes:
            hint_parts.append(f"{stored} written")
        if skips and not writes:
            reason = str(_payload(skips[-1]).get("reason") or "skipped")
            hint_parts.append(reason)
        if reads and any(bool(_payload(r).get("primaryFailed")) for r in reads):
            hint_parts.append("degraded")
        tiles.append(_tile_html("Memory", value, hint=" · ".join(p for p in hint_parts if p) or None))

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
  <div style="width:170px; font-size:11px; color:var(--text-muted,#B1B5BA); padding-right:8px;">{ev.get('type')}</div>
  <div style="flex:1; height:14px; background:var(--surface-2,#0E2932); border-radius:4px; position:relative;">
    <div style="position:absolute; left:{left}%; width:{width}%; height:100%; background:var(--primary,#00ED64); border-radius:4px; opacity:0.85;"
         title="{ev.get('type')} — {d} ms"></div>
  </div>
  <div style="width:60px; font-size:11px; text-align:right; color:var(--text-muted,#B1B5BA); padding-left:8px;">{d} ms</div>
</div>"""
        )
    st.markdown("".join(rows_html), unsafe_allow_html=True)


# ---------------------------------------------------------------------------
# 3. Request context
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
            f":material/lock: **Authenticated user context** — {ap.get('customersResolved', 0)} customer(s), "
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
            f":material/extension: **Prompt assembled** — {pp.get('totalBytes', 0)} B "
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


# ---------------------------------------------------------------------------
# 4. Model activity
# ---------------------------------------------------------------------------

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
            f":material/smart_toy: `{rp.get('modelId', '?')}` via `{rp.get('backend', '?')}`"
            f" — {up.get('totalTokens', 0)} token(s)"
            f"{f' · stop `{stop}`' if stop else ''}",
            expanded=i == 0,
        ):
            st.caption(
                f"System prompt {rp.get('systemPromptBytes', 0)} B · "
                f"prior turns {rp.get('priorTurnsCount', 0)}"
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


# ---------------------------------------------------------------------------
# 5. Routing / handoff attribution
# ---------------------------------------------------------------------------

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
# 6. MongoDB dashboard
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
        emoji = {
            "ok": ":material/check_circle:",
            "empty": ":material/circle:",
            "error": ":material/error:",
        }.get(rp.get("status", ""), "·")
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
                        st.caption(f":material/warning: {w.get('kind')} on `{w.get('field')}` — {w.get('detail')}")

    for v in vectors:
        vp = _payload(v)
        embed_src = vp.get("embeddingSource") or "?"
        embed_model = vp.get("embeddingModelId")
        embed_label = f"{embed_src}" + (f" ({embed_model})" if embed_model else "")
        collection_label = f" on `{vp.get('collection')}`" if vp.get("collection") else ""
        scores = vp.get("scores")
        hit_count = len(scores) if isinstance(scores, list) else 0
        with st.expander(
            f":material/explore: vector_search{collection_label} — embed via {embed_label} — {hit_count} hit(s)",
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
            if is_omitted_sentinel(preview):
                render_omitted_sentinel(preview, label="queryVectorPreview")
                preview = None
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
            vfilter = vp.get("filter")
            if is_omitted_sentinel(vfilter):
                render_omitted_sentinel(vfilter, label="filter")
            elif vfilter:
                if isinstance(vfilter, (dict, list)):
                    tune_bits.append(f"filter={json.dumps(vfilter, default=str)}")
                else:
                    tune_bits.append("filter recorded separately")
            if tune_bits:
                st.caption(" · ".join(tune_bits))
            if vfilter and not is_omitted_sentinel(vfilter) and not isinstance(vfilter, (dict, list)):
                st.caption("Filter")
                _render_jsonish(vfilter)
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
        with st.expander(f"{DB_DATA_INFO_LABEL} ({len(schemas)})", expanded=False):
            for s in schemas:
                sp = s.get("payload") or {}
                st.markdown(
                    f"**{sp.get('collection')}** — {sp.get('estimatedDocumentCount', 0)} estimated docs"
                )
                if sp.get("fields"):
                    _render_jsonish([{"name": f.get("name"), "type": f.get("type")} for f in sp["fields"][:30]])


# ---------------------------------------------------------------------------
# 7. Tool calls
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
        with st.expander(f":material/build: `{name}` — {duration or 0} ms", expanded=False):
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
        emoji = ":material/error:" if hp.get("blocked") or hp.get("errorClass") else f":material/satellite_alt: {hp.get('status') or '?'}"
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
        emoji = ":material/error:" if mp.get("errorClass") else ":material/router:"
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
# 8. AgentCore
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
        emoji = ":material/check_circle:" if not ip.get("errorMessage") else ":material/error:"
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
            f":material/account_tree: Nested trace {np.get('nestedTraceId') or 'unknown'} — {np.get('eventCount', 0)} events spliced"
        )
    for o in obs:
        op = o.get("payload") or {}
        if op.get("xrayUrl"):
            st.markdown(f"[X-Ray]({op['xrayUrl']})  ·  [CloudWatch logs]({op.get('cloudwatchLogStreamUrl') or '#'})")
    for g in gw:
        gp = g.get("payload") or {}
        st.caption(f"Gateway: target={gp.get('targetName')} · routing={gp.get('routingDecision')}")


# ---------------------------------------------------------------------------
# 9. Long-term memory
# ---------------------------------------------------------------------------

def _render_memory_header(scoped: list[dict], shared: list[dict], writes: list[dict], skips: list[dict]) -> None:
    reads = scoped + shared
    tiles: list[str] = []

    tiles.append(_tile_html("Reads", str(len(reads))))
    tiles.append(_tile_html("Writes", str(len(writes))))
    if skips:
        tiles.append(_tile_html("Skips", str(len(skips))))

    if reads:
        modes = sorted({str(_payload(r).get("mode") or "n/a") for r in reads})
        backends = sorted({str(_payload(r).get("backend") or "?") for r in reads})
        mode_label = "/".join(modes) if modes else "n/a"
        tiles.append(_tile_html("Read mode", mode_label, hint=", ".join(backends) or None))

        primary_failed = sum(1 for r in reads if bool(_payload(r).get("primaryFailed")))
        if primary_failed:
            tiles.append(
                _tile_html(
                    "Read status",
                    f"{primary_failed}/{len(reads)} degraded",
                    hint="primaryFailed=true",
                )
            )
        else:
            tiles.append(_tile_html("Read status", "ok"))

        total_bytes = sum(_as_int(_payload(r).get("bytesInjected")) for r in reads)
        total_entries = sum(_as_int(_payload(r).get("entryCount")) for r in reads)
        tiles.append(_tile_html("Injected", f"{total_entries} entries", hint=f"{total_bytes:,} B"))

    if writes:
        stored = sum(_as_int(_payload(w).get("docsInserted")) for w in writes)
        dupes = sum(_as_int(_payload(w).get("duplicatesSkipped")) for w in writes)
        outcomes = sorted({str(_payload(w).get("primaryOutcome") or "") for w in writes})
        hint_parts = [o for o in outcomes if o]
        if dupes:
            hint_parts.append(f"{dupes} dup skipped")
        tiles.append(
            _tile_html(
                "Stored",
                f"{stored} fact(s)",
                hint=", ".join(hint_parts) or None,
            )
        )

    if tiles:
        st.markdown("".join(tiles), unsafe_allow_html=True)


def _render_memory_read(event: dict) -> None:
    rp = _payload(event)
    kind = "Agent-scoped" if event.get("type") == "memory.scoped_read" else "Shared"
    mode = str(rp.get("mode") or "n/a")
    backend = str(rp.get("backend") or "?")
    primary_failed = bool(rp.get("primaryFailed"))
    status_chip = " · :red[primaryFailed]" if primary_failed else ""

    st.markdown(
        f":material/download: **{kind} read** — `mode={mode}` · backend `{backend}` · "
        f"{_as_int(rp.get('entryCount'))} entries · "
        f"{_as_int(rp.get('bytesInjected')):,} B · "
        f"{_as_int(rp.get('latencyMs'))} ms{status_chip}"
    )

    why_left, why_right = st.columns(2)
    with why_left:
        st.caption("Query")
        st.markdown(_redacted_or_text(rp.get("queryText"), max_chars=400))
        emb_source = rp.get("embeddingSource") or "?"
        emb_model = rp.get("embeddingModel") or "?"
        st.caption(f"Embedding: `{emb_source}` / `{emb_model}`")
        injection = rp.get("injectionPoint") or "system_prompt"
        st.caption(f"Injection point: `{injection}`")
    with why_right:
        retrieval = rp.get("retrieval") or {}
        st.caption("Retrieval")
        cols_queried = retrieval.get("collectionsQueried") if "collectionsQueried" in retrieval else rp.get("collectionsQueried")
        st.markdown(
            f"- topK `{_as_int(retrieval.get('topK'))}` · fetchK `{_as_int(retrieval.get('fetchK'))}`\n"
            f"- vectorHits `{_as_int(retrieval.get('vectorHits'))}` · "
            f"lexicalHits `{_as_int(retrieval.get('lexicalHits'))}` · "
            f"rrfMerged `{_as_int(retrieval.get('rrfMergedCount'))}`"
        )
        if isinstance(cols_queried, list) and cols_queried:
            st.caption("collectionsQueried: " + ", ".join(f"`{c}`" for c in cols_queried))

    st.caption(
        "Tuning: per-collection weights, recency half-life, and MMR diversification are env-driven "
        "(`MEMORY_WEIGHT_FACTS`, `MEMORY_WEIGHT_CHAT_MESSAGES`, `MEMORY_RECENCY_HALFLIFE_DAYS`, "
        "`MEMORY_MMR_LAMBDA`) — see `docs/memory-architecture.md` for the post-RRF pipeline. "
        "The per-collection breakdown with error column + live env-knob values is in **Developer details → Long-term memory internals**."
    )

    facts = rp.get("facts")
    if is_omitted_sentinel(facts):
        render_omitted_sentinel(facts, label="Facts injected into the system prompt")
        facts = []
    elif not isinstance(facts, list):
        facts = []
    if facts:
        with st.expander(f"Facts injected into the system prompt ({len(facts)})", expanded=False):
            for line in facts:
                if _is_redacted(line):
                    st.markdown("- *<redacted>*")
                    continue
                if not isinstance(line, str):
                    st.markdown(f"- {line}")
                    continue
                short = _short_text(line, 400) or line
                m = re.match(r"^\[(.+?)\]\s*(.*)$", short)
                if m:
                    st.markdown(f"- _[{m.group(1)}]_ {m.group(2)}")
                else:
                    st.markdown(f"- {short}")

    if primary_failed:
        cls = rp.get("retrievalErrorClass") or "RetrievalError"
        msg = rp.get("retrievalErrorMessage") or "(no message)"
        st.error(f"{cls}: {msg}")


def _render_memory_write(event: dict, all_events: list[dict]) -> None:
    wp = _payload(event)
    outcome = str(wp.get("primaryOutcome") or "?")
    outcome_label = {
        "persisted": ":green[persisted]",
        "skipped": ":orange[skipped]",
        "failed": ":red[failed]",
    }.get(outcome, f"`{outcome}`")
    op = str(wp.get("op") or "?")
    prior = wp.get("priorEntryCount")
    new = wp.get("newEntryCount")
    delta_text = f"{prior} → {new}" if prior is not None or new is not None else "n/a"

    st.markdown(
        f":material/save: **Long-term write** — {outcome_label} · `op={op}` · "
        f"{_as_int(wp.get('docsInserted'))} inserted · "
        f"{_as_int(wp.get('duplicatesSkipped'))} dup skipped · "
        f"{_as_int(wp.get('latencyMs'))} ms · entries {delta_text}"
    )

    user_label, user_source = _resolve_user_message_for_write(all_events, event)
    st.caption("What was extracted from")
    st.markdown(f"**User input** ({user_source}):")
    st.markdown(user_label)
    st.caption(
        f"User msg: {_as_int(wp.get('userMessageBytes'))} B raw → "
        f"{_as_int(wp.get('userMessageBytesStored'))} B stored (2 000-char cap) · "
        f"Assistant reply: {_as_int(wp.get('assistantReplyBytes'))} B raw → "
        f"{_as_int(wp.get('assistantReplyBytesStored'))} B stored (4 000-char cap)"
    )
    st.caption("Assistant reply is not persisted verbatim on a trace event — see the Model Activity section above for the streamed reply.")

    extractor_bits: list[str] = []
    if wp.get("extractorModelId"):
        extractor_bits.append(f"model `{wp['extractorModelId']}`")
    if wp.get("extractorLatencyMs") is not None:
        extractor_bits.append(f"{_as_int(wp.get('extractorLatencyMs'))} ms")
    tok_in = wp.get("extractorInputTokens")
    tok_out = wp.get("extractorOutputTokens")
    if tok_in is not None or tok_out is not None:
        extractor_bits.append(f"tokens in/out {_as_int(tok_in)}/{_as_int(tok_out)}")
    candidates = wp.get("factCandidates") or []
    accepted = sum(1 for c in candidates if isinstance(c, dict) and c.get("matched"))
    extractor_bits.append(f"accepted {accepted}/{len(candidates)}")
    if extractor_bits:
        st.caption("Extractor: " + " · ".join(extractor_bits))

    embed_bits: list[str] = []
    if wp.get("embeddingModel"):
        embed_bits.append(f"model `{wp['embeddingModel']}`")
    if wp.get("embeddedCount") is not None:
        embed_bits.append(f"embedded {_as_int(wp.get('embeddedCount'))}/{accepted}")
    if wp.get("ttlExpiresAt"):
        embed_bits.append(f"TTL expires {wp['ttlExpiresAt']}")
    if embed_bits:
        st.caption("Embedding + TTL: " + " · ".join(embed_bits))

    if candidates:
        st.caption(
            f"{len(candidates)} candidate(s) inspected — full table with matched/rejected reasons "
            "is in **Developer details → Long-term memory internals**."
        )

    facts_extracted = wp.get("factsExtracted")
    if is_omitted_sentinel(facts_extracted):
        render_omitted_sentinel(facts_extracted, label="Persisted facts")
        facts_extracted = []
    elif not isinstance(facts_extracted, list):
        facts_extracted = []
    if facts_extracted:
        with st.expander(f"Persisted facts ({len(facts_extracted)})", expanded=False):
            st.caption(
                f"{_as_int(wp.get('docsInserted'))} new · "
                f"{_as_int(wp.get('duplicatesSkipped'))} already existed (matched on `factHash`)."
            )
            for f in facts_extracted:
                if _is_redacted(f):
                    st.markdown("- *<redacted>*")
                else:
                    st.markdown(f"- {_short_text(f, 400) or f}")

    if wp.get("primaryOutcome") == "failed" or wp.get("primaryErrorMessage"):
        cls = wp.get("primaryErrorClass") or "WriteError"
        msg = wp.get("primaryErrorMessage") or "(no message)"
        st.error(f"Primary write failed — {cls}: {msg}")

    if wp.get("fallbackBackend"):
        fb_outcome = wp.get("fallbackOutcome") or "?"
        st.info(
            f"AgentCore Memory Store fallback attempted (`{wp['fallbackBackend']}`) — outcome: `{fb_outcome}`"
        )
        if wp.get("fallbackErrorMessage"):
            cls = wp.get("fallbackErrorClass") or "FallbackError"
            st.error(f"Fallback error — {cls}: {wp['fallbackErrorMessage']}")


def _render_memory_skip(event: dict) -> None:
    sp = _payload(event)
    reason = str(sp.get("reason") or "unknown")
    st.warning(f":material/skip_next: **Write skipped** — {_human_skip_reason(reason)}")
    excerpt = sp.get("userMessageExcerpt")
    if excerpt:
        st.caption(f"User input excerpt: {_short_text(excerpt, 200) or excerpt}")
    agent_id = sp.get("agentId")
    if agent_id:
        st.caption(f"Agent: `{agent_id}`")
    if reason == "llm_extractor_failed":
        st.markdown("Extractor diagnostics:")
        diag = {
            "extractorModelId": sp.get("extractorModelId"),
            "extractorLatencyMs": sp.get("extractorLatencyMs"),
            "extractorError": sp.get("extractorError"),
        }
        st.code(json.dumps({k: v for k, v in diag.items() if v is not None}, indent=2, default=str), language="json")


def _render_memory_related(events: list[dict]) -> None:
    """Auth + prompt-assembly chips that compete with LTM for the system prompt.

    The full rendered system-prompt body and agent-tool vector searches on
    `agent_memory_facts` / `chat_messages` moved to
    `developer_trace_view._dev_prompt_and_model_io` and
    `developer_trace_view._dev_mongo_internals` respectively — both are
    debug-grade and would otherwise drown the client demo. This function only
    keeps the two short chips a client demo still benefits from seeing.
    """
    auths = _events_of(events, "auth.context_build")
    prompts = _events_of(events, "prompt.assembled")
    if not (auths or prompts):
        return

    with st.expander("Related context — what else shaped this prompt", expanded=False):
        if auths:
            st.markdown("**Auth context** (competes with LTM for system-prompt bytes)")
            for a in auths:
                ap = _payload(a)
                claims = ap.get("jwtClaims") or {}
                st.markdown(
                    f"- user `{str(ap.get('userId') or 'anonymous')[:32]}` · "
                    f"sub `{str(claims.get('sub') or '?')[:32]}` · "
                    f"iss `{str(claims.get('iss') or '?')[:48]}` · "
                    f"aud `{str(claims.get('aud') or '?')[:48]}`"
                )
                st.caption(
                    f"customersResolved {_as_int(ap.get('customersResolved'))} · "
                    f"ordersResolved {_as_int(ap.get('ordersResolved'))}"
                )

        if prompts:
            st.markdown("**Prompt assembly** (where the memory context lands)")
            for p in prompts:
                pp = _payload(p)
                st.markdown(
                    f"- total `{_as_int(pp.get('totalBytes')):,}` B = "
                    f"persona `{_as_int(pp.get('personaBytes'))}` + "
                    f"discovery `{_as_int(pp.get('discoveryBytes'))}` + "
                    f"memory `{_as_int(pp.get('memoryContextBytes'))}` "
                    f"+ skills `{sum(_as_int((s or {}).get('bytes')) for s in (pp.get('activatedSkills') or []))}`"
                )
                activated = pp.get("activatedSkills") or []
                if activated:
                    names = ", ".join(f"`{(s or {}).get('name') or '?'}`" for s in activated if isinstance(s, dict))
                    st.caption(f"Activated skills: {names}")
                if isinstance(pp.get("body"), str) and pp.get("body"):
                    st.caption("Full rendered prompt body is in **Developer details → Prompt + messages seed + model I/O**.")


def render_memory(events: list[dict]) -> None:
    scoped = _events_of(events, "memory.scoped_read")
    shared = _events_of(events, "memory.shared_read")
    writes = _events_of(events, "memory.long_term_write")
    skips = _events_of(events, "memory.long_term_skip")
    if not (scoped or shared or writes or skips):
        return

    st.markdown('<div class="trace-section-title">Long-term memory</div>', unsafe_allow_html=True)

    ltm_events = scoped + shared + writes + skips
    _render_memory_header(scoped, shared, writes, skips)
    _redaction_banner(ltm_events)

    for r in scoped + shared:
        _render_memory_read(r)
    for w in writes:
        _render_memory_write(w, events)
    for s in skips:
        _render_memory_skip(s)

    _render_memory_related(events)


# ---------------------------------------------------------------------------
# 10. Errors
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
# 11. Trace meta caption
# ---------------------------------------------------------------------------

def render_trace_meta(trace: dict) -> None:
    st.caption(
        f"Trace `{trace.get('traceId', '')[:8]}…` · session `{trace.get('sessionId', '')[:8]}…`"
        f" · agent `{trace.get('agentId', '')}` · created {trace.get('createdAt', '')}"
    )
