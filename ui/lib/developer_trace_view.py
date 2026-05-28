"""Developer-grade Trace Viewer panel.

This module owns the single top-level "Developer details" surface appended
to the Trace Viewer page after every client-facing renderer has finished.

Lazy-loading contract
---------------------

`render_developer_details(core_trace, settings, api_token)` renders ONLY a
single `st.button` when the user has not clicked "Show developer details".
That means the `_dev_*` sub-renderers below are never imported-bound nor
evaluated on a normal client demo — the price of the dev surface for a demo
is one Streamlit widget.

On first click the page reruns and we:

1. Read the toggle from `st.session_state[f"dev_open_{traceId}"]`.
2. Fetch the dev projection via `api_client.get_trace(..., include="dev")`
   inside an `st.spinner`. Cache it in `st.session_state[f"dev_trace_{traceId}"]`
   so flipping the button on/off does not re-fetch.
3. Render every `_dev_*` sub-renderer inside an `st.container(border=True)`
   so the visual boundary is clear without re-introducing an
   always-evaluating top-level expander body.

If the api_client does not yet accept the `include` kwarg (early in the
PR2 land sequence), we fall back to the core trace already in hand. Every
`_dev_*` renderer tolerates `_omittedForCoreMode` sentinels so this fallback
degrades to "click → load → see redacted bytes counts" rather than crashing.

Sub-renderers
-------------

- `_dev_identifiers(trace, events)` — IDs + OTel + JWT + curl-to-reproduce
- `_dev_span_tree(trace, events)` — spanTree (fallback: computed from parentId)
- `_dev_prompt_and_model_io(events)` — full prompt body, messagesSeed, deltas
- `_dev_mongo_internals(events)` — full queries + scoping audit + vector indexName
- `_dev_memory_internals(events)` — perCollection table, candidates, env knobs
- `_dev_agentcore_internals(trace, events)` — full invoke payloads + nested traces
- `_dev_tool_calls_verbose(events)` — full input/result; headers; MCP args
- `_dev_skill_resource_reads(events)` — per-skill `read_skill_resource` rollup
- `_dev_retries(events)` — interleaved model.retry + agentcore.retry
- `_dev_performance(events)` — latency.checkpoint table + cumulativeBytes chart
- `_dev_cost_breakdown(trace)` — estimatedCostUsd + per-model breakdown
- `_dev_environment(trace, events)` — release + dev.environment + mock chips
- `_dev_byte_cap(trace, events)` — dev.byte_cap_hit drops + eventsDropped
- `_dev_raw_events(trace, events)` — filter + search + paginate + download
"""

from __future__ import annotations

import json
import os
from typing import Any

import streamlit as st

from lib.trace_view_helpers import (
    _LTM_COLLECTIONS,
    _as_int,
    _events_of,
    _mock_markers,
    _nearest_vector_result_payload,
    _payload,
    _redacted_or_text,
    _render_jsonish,
    _render_vector_document_previews,
    _short_text,
    _trace_events_dropped,
    _trace_is_truncated,
    _vector_document_previews,
    is_omitted_sentinel as _is_omitted_sentinel,
    render_omitted_sentinel as _render_omitted_sentinel,
)


# ---------------------------------------------------------------------------
# Top-level gate + on-demand fetch
# ---------------------------------------------------------------------------

def render_developer_details(core_trace: dict, settings: Any = None, api_token: str | None = None) -> None:
    """Button-gated "Developer details" surface.

    When the button has never been clicked, this only renders a single
    `st.button` — the `_dev_*` sub-renderers below are not invoked, so a
    client demo pays zero rendering cost beyond the widget itself.

    Once the user toggles the button on, we fetch `?include=dev` (cached in
    `st.session_state[f"dev_trace_{traceId}"]`), then render every
    sub-section inside a bordered container.

    Backward-compatibility: if `settings` is None (e.g. tests that call this
    directly without page wiring), we render the bordered container against
    the `core_trace` already in hand and skip the dev fetch. Every `_dev_*`
    renderer tolerates `_omittedForCoreMode` sentinels so this degrades
    gracefully rather than crashing.
    """
    trace_id = core_trace.get("traceId") or ""
    state_key = f"dev_open_{trace_id}"
    cache_key = f"dev_trace_{trace_id}"

    loaded = bool(st.session_state.get(state_key, False))
    label = "Hide developer details" if loaded else "Show developer details"
    if st.button(label, key=f"toggle_dev_{trace_id}"):
        st.session_state[state_key] = not loaded
        st.rerun()

    if not st.session_state.get(state_key, False):
        return

    dev_trace = st.session_state.get(cache_key)
    if dev_trace is None:
        dev_trace = _fetch_dev_trace(core_trace, settings, api_token)
        st.session_state[cache_key] = dev_trace

    events = dev_trace.get("events") or []

    with st.container(border=True):
        st.caption(
            "Debug-grade view. Same data the API recorded for this turn — "
            "every section degrades to a `no data recorded` caption on older traces."
        )
        _dev_identifiers(dev_trace, events)
        _dev_span_tree(dev_trace, events)
        _dev_orchestrator_internals(events)
        _dev_prompt_and_model_io(events)
        _dev_mongo_internals(events)
        _dev_memory_internals(events)
        _dev_agentcore_internals(dev_trace, events)
        _dev_tool_calls_verbose(events)
        _dev_skill_resource_reads(events)
        _dev_retries(events)
        _dev_performance(events)
        _dev_cost_breakdown(dev_trace)
        _dev_environment(dev_trace, events)
        _dev_byte_cap(dev_trace, events)
        _dev_raw_events(dev_trace, events)


def _fetch_dev_trace(core_trace: dict, settings: Any, api_token: str | None) -> dict:
    """Fetch the `?include=dev` projection of this trace.

    Tolerant of three failure modes so the developer surface still renders:
      1. `settings is None` (called from tests without page wiring) →
         return `core_trace` unchanged.
      2. `api_client.get_trace` does not yet accept `include=` (early in
         the PR2 land sequence before `ui-api-client-include` lands) →
         retry without the kwarg and return whatever we get.
      3. The fetch raises → surface the error and return `core_trace` so
         every `_dev_*` sub-section still renders against what we have.
    """
    if settings is None:
        return core_trace

    trace_id = core_trace.get("traceId") or ""
    if not trace_id:
        return core_trace

    try:
        from lib.api_client import get_trace
    except Exception as exc:
        st.warning(f"Developer details fetch unavailable (api_client import failed: {exc}).")
        return core_trace

    with st.spinner("Loading developer details…"):
        try:
            return get_trace(
                settings.api_base,
                trace_id=trace_id,
                access_token=api_token,
                include="dev",
            )
        except TypeError:
            try:
                return get_trace(
                    settings.api_base,
                    trace_id=trace_id,
                    access_token=api_token,
                )
            except Exception as exc:
                st.warning(f"Developer details fetch failed: {exc}")
                return core_trace
        except Exception as exc:
            st.warning(f"Developer details fetch failed: {exc}")
            return core_trace


# ---------------------------------------------------------------------------
# _dev_identifiers
# ---------------------------------------------------------------------------

_OTEL_HEX_RE = (
    "0123456789abcdef"  # cheap sanity check below
)


def _build_servicelens_url(region: str | None, otel_trace_id: str | None) -> str | None:
    if not (region and otel_trace_id):
        return None
    return (
        f"https://{region}.console.aws.amazon.com/cloudwatch/home"
        f"?region={region}#servicelens:traces/{otel_trace_id}"
    )


def _build_xray_url(region: str | None, otel_trace_id: str | None) -> str | None:
    if not (region and otel_trace_id):
        return None
    return (
        f"https://{region}.console.aws.amazon.com/cloudwatch/home"
        f"?region={region}#xray:traces/{otel_trace_id}"
    )


def _curl_to_reproduce(events: list[dict], settings_api_base: str | None) -> str | None:
    starts = _events_of(events, "chat.turn.start")
    if not starts:
        return None
    sp = _payload(starts[0])
    session_id = sp.get("sessionId") or ""
    agent_id = sp.get("agentId") or ""
    api_base = settings_api_base or "<API_BASE>"
    return (
        f'curl -X POST "{api_base}/chat" \\\n'
        f'  -H "Authorization: Bearer $TOKEN" \\\n'
        f'  -H "Content-Type: application/json" \\\n'
        f'  -d \'{{"sessionId":"{session_id}","agentId":"{agent_id}","message":"<your prompt>"}}\''
    )


def _dev_identifiers(trace: dict, events: list[dict]) -> None:
    with st.expander("Identifiers + OTel correlation", expanded=False):
        st.markdown(
            "| Field | Value |\n|---|---|\n"
            f"| traceId | `{trace.get('traceId') or '—'}` |\n"
            f"| sessionId | `{trace.get('sessionId') or '—'}` |\n"
            f"| messageId | `{trace.get('messageId') or '—'}` |\n"
            f"| userId | `{trace.get('userId') or 'anonymous'}` |\n"
            f"| agentId | `{trace.get('agentId') or '—'}` |\n"
            f"| finalAgentId | `{trace.get('finalAgentId') or trace.get('agentId') or '—'}` |\n"
            f"| createdAt | `{trace.get('createdAt') or '—'}` |"
        )

        correlation = trace.get("correlation") or {}
        if correlation:
            st.caption("Correlation")
            _render_jsonish(correlation)

        auths = _events_of(events, "auth.context_build")
        if auths:
            claims = _payload(auths[0]).get("jwtClaims") or {}
            if claims:
                st.caption("JWT claims (from auth.context_build)")
                _render_jsonish(claims)

        otel = trace.get("otel") or {}
        otel_trace_id = otel.get("traceId")
        if otel_trace_id:
            region = (trace.get("release") or {}).get("region") or os.environ.get("AWS_REGION")
            st.markdown(
                f"**OTel** — traceId `{otel_trace_id}` · "
                f"rootSpanId `{otel.get('rootSpanId') or '—'}`"
            )
            servicelens = _build_servicelens_url(region, otel_trace_id)
            xray = _build_xray_url(region, otel_trace_id)
            if servicelens or xray:
                links = " · ".join(
                    f"[{name}]({url})"
                    for name, url in (("ServiceLens", servicelens), ("X-Ray", xray))
                    if url
                )
                st.markdown(links)
        else:
            st.caption("OTel: no traceId on this trace.")

        api_base = None
        try:
            from lib.config import load_settings  # local import keeps tests deps light
            api_base = load_settings().api_base
        except Exception:
            api_base = None
        curl = _curl_to_reproduce(events, api_base)
        if curl:
            st.caption("Reproduce this turn")
            st.code(curl, language="bash")


# ---------------------------------------------------------------------------
# _dev_span_tree
# ---------------------------------------------------------------------------

def _compute_span_tree_from_parent_id(events: list[dict]) -> list[dict]:
    """Fallback span-tree builder used when `trace.spanTree` is absent.

    Mirrors the API-side `buildSpanTree()` shape: each node has
    `{ id, name, durationMs, agentId?, children: [...] }`.
    """
    nodes_by_id: dict[str, dict] = {}
    for ev in events:
        ev_id = str(ev.get("id") or "")
        if not ev_id:
            continue
        nodes_by_id.setdefault(
            ev_id,
            {
                "id": ev_id,
                "name": str(ev.get("type") or "event"),
                "durationMs": ev.get("durationMs"),
                "agentId": (ev.get("payload") or {}).get("agentId") if isinstance(ev.get("payload"), dict) else None,
                "children": [],
            },
        )
    roots: list[dict] = []
    for ev in events:
        ev_id = str(ev.get("id") or "")
        if not ev_id or ev_id not in nodes_by_id:
            continue
        parent_id = str(ev.get("parentId") or "")
        if parent_id and parent_id in nodes_by_id:
            nodes_by_id[parent_id]["children"].append(nodes_by_id[ev_id])
        else:
            roots.append(nodes_by_id[ev_id])
    return roots


def _render_span_tree_node(node: dict, depth: int = 0) -> None:
    indent = "&nbsp;" * (depth * 4)
    # API-side `buildSpanTree` ships nodes as `{ id, type, ts, durationMs,
    # agentId, children }`; the fallback recompute in
    # `_compute_span_tree_from_parent_id` writes `name` for back-compat with
    # older trace docs. Accept either so a developer never sees a row of
    # bare `?` glyphs while debugging.
    name = node.get("type") or node.get("name") or "?"
    duration = node.get("durationMs")
    duration_text = f" — {_as_int(duration)} ms" if duration is not None else ""
    agent_id = node.get("agentId")
    agent_text = f" · `{agent_id}`" if agent_id else ""
    st.markdown(
        f"<div class='trace-span-tree'>{indent}<code>{name}</code>{duration_text}{agent_text}</div>",
        unsafe_allow_html=True,
    )
    for child in node.get("children") or []:
        _render_span_tree_node(child, depth + 1)


def _dev_span_tree(trace: dict, events: list[dict]) -> None:
    with st.expander("Span tree (call hierarchy)", expanded=False):
        tree = trace.get("spanTree")
        if not (isinstance(tree, list) and tree):
            tree = _compute_span_tree_from_parent_id(events)
        if not tree:
            st.caption("No span tree recorded for this trace.")
            return
        for node in tree:
            _render_span_tree_node(node, 0)


# ---------------------------------------------------------------------------
# _dev_prompt_and_model_io
# ---------------------------------------------------------------------------

def _is_model_request_start(payload: dict) -> bool:
    """Filter to the start signature of `model.request` spans so each request
    renders once. The end event is `{}` (empty payload)."""
    return bool(payload.get("userMessage") or payload.get("modelId"))


def _dev_prompt_and_model_io(events: list[dict]) -> None:
    prompts = _events_of(events, "prompt.assembled")
    skills = _events_of(events, "skill.activated")
    requests = [e for e in _events_of(events, "model.request") if _is_model_request_start(_payload(e))]
    deltas = _events_of(events, "model.text_delta_batch")
    thinking = _events_of(events, "model.thinking_block")
    usage = _events_of(events, "model.usage")
    if not (prompts or skills or requests or deltas or thinking or usage):
        return

    with st.expander("Prompt + messages seed + model I/O", expanded=False):
        for p in prompts:
            pp = _payload(p)
            st.markdown(
                f"**Prompt assembled** — total `{_as_int(pp.get('totalBytes')):,}` B · "
                f"hash `{pp.get('bodyHash') or '—'}`"
            )
            body = pp.get("body")
            if _is_omitted_sentinel(body):
                _render_omitted_sentinel(body, label="prompt body")
            elif isinstance(body, str) and body:
                st.code(body, language="markdown")
            else:
                st.caption("_Prompt body not captured (set `TRACE_PROMPT_BODY=1` on the API to record it)._")

        if skills:
            st.markdown("**Activated skills**")
            for s in skills:
                sp = _payload(s)
                name = sp.get("name") or "?"
                preview = sp.get("bodyPreview")
                with st.expander(f"`{name}` — {_as_int(sp.get('bytes'))} B", expanded=False):
                    if _is_omitted_sentinel(preview):
                        _render_omitted_sentinel(preview, label="skill body preview")
                    elif isinstance(preview, str) and preview:
                        st.code(preview, language="markdown")
                    reads = sp.get("resourceReads") or []
                    if reads:
                        st.caption(f"{len(reads)} read_skill_resource invocation(s) — see Skill resource reads section.")

        for req in requests:
            rp = _payload(req)
            st.markdown(
                f"**Model request** — `{rp.get('modelId') or '?'}` via "
                f"`{rp.get('backend') or '?'}` · region `{rp.get('region') or '?'}` · "
                f"systemPromptBytes `{_as_int(rp.get('systemPromptBytes'))}` · "
                f"systemPromptHash `{rp.get('systemPromptHash') or '—'}`"
            )
            user_msg = rp.get("userMessage")
            if _is_omitted_sentinel(user_msg):
                _render_omitted_sentinel(user_msg, label="userMessage")
            elif user_msg:
                st.caption("userMessage")
                st.code(str(user_msg), language=None)

            seed = rp.get("messagesSeed")
            if _is_omitted_sentinel(seed):
                _render_omitted_sentinel(seed, label="messagesSeed")
            elif isinstance(seed, list) and seed:
                md = "| Role | Content bytes | Preview |\n|---|---:|---|\n"
                for m in seed:
                    if not isinstance(m, dict):
                        continue
                    md += (
                        f"| `{m.get('role') or '?'}` "
                        f"| {_as_int(m.get('contentBytes'))} "
                        f"| {(_short_text(m.get('contentPreview'), 200) or '').replace('|', '\\|')} |\n"
                    )
                st.caption("messagesSeed (Strands replay history)")
                st.markdown(md)
            elif seed is not None:
                st.caption("messagesSeed")
                _render_jsonish(seed)

            prior = rp.get("priorTurnsPreview")
            if isinstance(prior, list) and prior:
                with st.expander(f"priorTurnsPreview ({len(prior)})", expanded=False):
                    _render_jsonish(prior)

        if deltas:
            with st.expander(f"Streamed assistant text — {len(deltas)} batch(es)", expanded=False):
                combined = "".join(str(_payload(d).get("text") or "") for d in deltas)
                if combined:
                    st.code(combined, language="markdown")
                md = "| ts | bytes | windowMs | cumulativeBytes |\n|---|---:|---:|---:|\n"
                for d in deltas:
                    dp = _payload(d)
                    md += (
                        f"| {d.get('ts') or 0} "
                        f"| {_as_int(dp.get('bytes'))} "
                        f"| {_as_int(dp.get('windowMs'))} "
                        f"| {_as_int(dp.get('cumulativeBytes'))} |\n"
                    )
                st.caption("Per-batch streaming detail")
                st.markdown(md)

        if thinking:
            with st.expander(f"Thinking blocks ({len(thinking)})", expanded=False):
                for t in thinking:
                    tp = _payload(t)
                    text = tp.get("text") or ""
                    if _is_omitted_sentinel(text):
                        _render_omitted_sentinel(text, label="thinking block")
                    else:
                        st.code(str(text), language=None)

        if usage:
            with st.expander(f"Model usage ({len(usage)})", expanded=False):
                for u in usage:
                    _render_jsonish(_payload(u))


# ---------------------------------------------------------------------------
# _dev_mongo_internals
# ---------------------------------------------------------------------------

def _scoping_chip(scoping: str | None) -> str:
    if scoping == "missing_user_filter":
        return '<span class="trace-chip danger">scoping: missing_user_filter</span>'
    if scoping == "ok":
        return '<span class="trace-chip">scoping: ok</span>'
    return ""


def _dev_mongo_internals(events: list[dict]) -> None:
    queries = _events_of(events, "mongo.query")
    results = _events_of(events, "mongo.result")
    plans = _events_of(events, "mongo.plan")
    diags = _events_of(events, "mongo.diagnostic")
    vectors = _events_of(events, "mongo.vector_search")
    if not (queries or vectors):
        return

    with st.expander("MongoDB internals (with scoping audit)", expanded=False):
        for i, q in enumerate(queries):
            qp = _payload(q)
            rp = _payload(results[i]) if i < len(results) else {}
            scoping_html = _scoping_chip(qp.get("scoping"))
            header = (
                f"**#{i + 1} `{qp.get('op') or '?'}` on `{qp.get('collection') or '?'}` "
                f"— {_as_int(rp.get('docCount'))} doc(s) in {_as_int(rp.get('latencyMs'))} ms**"
            )
            st.markdown(header + (f"<br>{scoping_html}" if scoping_html else ""), unsafe_allow_html=True)
            for label, field in (
                ("filter", "filter"),
                ("normalizedFilter", "normalizedFilter"),
                ("pipeline", "pipeline"),
                ("projection", "projection"),
                ("sort", "sort"),
                ("skip", "skip"),
            ):
                value = qp.get(field)
                if value is not None:
                    st.caption(label)
                    _render_jsonish(value)
            if i < len(plans):
                pp = _payload(plans[i])
                if pp:
                    st.caption("Plan")
                    _render_jsonish(pp)
            if i < len(diags):
                dp = _payload(diags[i])
                if dp:
                    st.caption("Diagnostic")
                    _render_jsonish(dp)

        for v in vectors:
            vp = _payload(v)
            collection = vp.get("collection") or "?"
            is_ltm = str(collection) in _LTM_COLLECTIONS
            label_suffix = " (agent-tool LTM search)" if is_ltm else ""
            index_name = vp.get("indexName")
            index_chip = (
                f'<span class="trace-chip">index: <code>{index_name}</code></span>' if index_name else ""
            )
            st.markdown(
                f"**Vector search on `{collection}`{label_suffix}** — "
                f"embed via `{vp.get('embeddingSource') or '?'}`"
                + (f" ({vp.get('embeddingModelId')})" if vp.get('embeddingModelId') else "")
                + (f"<br>{index_chip}" if index_chip else ""),
                unsafe_allow_html=True,
            )
            embed_ms = vp.get("embedQueryMs")
            search_ms = vp.get("searchMs")
            if embed_ms is not None or search_ms is not None:
                st.caption(
                    f"Embedding {_as_int(embed_ms)} ms · Atlas Search {_as_int(search_ms)} ms"
                )
            for label, field in (
                ("filter", "filter"),
                ("queryVectorPreview", "queryVectorPreview"),
                ("scoreSummary", "scoreSummary"),
                ("histogram", "histogram"),
                ("hybrid", "hybrid"),
                ("recallWithoutFilter", "recallWithoutFilter"),
            ):
                value = vp.get(field)
                if _is_omitted_sentinel(value):
                    _render_omitted_sentinel(value, label=label)
                elif value is not None:
                    st.caption(label)
                    _render_jsonish(value)
            previews = _vector_document_previews(vp, _nearest_vector_result_payload(events, v))
            if previews:
                _render_vector_document_previews(previews)


# ---------------------------------------------------------------------------
# _dev_memory_internals  (deep half of the render_memory split)
# ---------------------------------------------------------------------------

_MEMORY_ENV_KNOB_FIELDS: tuple[tuple[str, str, str], ...] = (
    ("mmrLambda", "MEMORY_MMR_LAMBDA", "1=pure relevance, 0=pure diversity"),
    ("recencyHalflifeDays", "MEMORY_RECENCY_HALFLIFE_DAYS", "exponential recency decay; 0 disables"),
    ("weightFacts", "MEMORY_WEIGHT_FACTS", "RRF score multiplier on `agent_memory_facts`"),
    ("weightChatMessages", "MEMORY_WEIGHT_CHAT_MESSAGES", "RRF score multiplier on `chat_messages`"),
    ("numCandidates", "MEMORY_VECTOR_NUM_CANDIDATES", "`$vectorSearch.numCandidates` width"),
)


def _render_per_collection_dev_table(per_collection: list[dict]) -> None:
    if not per_collection:
        return
    md = "| Collection | Vector | Lexical | Embed ms | Search ms | Error |\n|---|---:|---:|---:|---:|---|\n"
    for c in per_collection:
        if not isinstance(c, dict):
            continue
        embed_ms = c.get("embedQueryMs")
        search_ms = c.get("searchMs")
        embed_cell = "—" if embed_ms is None else str(_as_int(embed_ms))
        search_cell = "—" if search_ms is None else str(_as_int(search_ms))
        md += (
            f"| `{c.get('collection', '?')}` "
            f"| {_as_int(c.get('vectorReturned'))} "
            f"| {_as_int(c.get('lexicalReturned'))} "
            f"| {embed_cell} "
            f"| {search_cell} "
            f"| {c.get('error') or ''} |\n"
        )
    st.markdown(md)


def _render_env_knob_values(rp: dict) -> None:
    rows: list[tuple[str, str, str]] = []
    for field, env_name, blurb in _MEMORY_ENV_KNOB_FIELDS:
        if rp.get(field) is None:
            continue
        rows.append((env_name, str(rp.get(field)), blurb))
    if not rows:
        return
    md = "| Env knob | Live value | Effect |\n|---|---:|---|\n"
    for env_name, value, blurb in rows:
        md += f"| `{env_name}` | `{value}` | {blurb} |\n"
    st.markdown(md)


def _render_candidates_dev_table(candidates: list[dict]) -> None:
    if not candidates:
        return
    with st.expander(f"All candidates considered ({len(candidates)})", expanded=True):
        sorted_candidates = sorted(
            candidates,
            key=lambda c: (
                0 if isinstance(c, dict) and c.get("matched") else 1,
                str(c.get("rejectedReason") or "") if isinstance(c, dict) else "",
            ),
        )
        for c in sorted_candidates:
            if not isinstance(c, dict):
                continue
            matched = bool(c.get("matched"))
            check = ":material/check:" if matched else ":material/close:"
            text = _redacted_or_text(c.get("text"), max_chars=300)
            length = _as_int(c.get("length"))
            category = c.get("category") or "?"
            patterns = ", ".join(c.get("matchedPatterns") or []) or "—"
            rejected = c.get("rejectedReason") or ""
            note = c.get("note")
            line = (
                f"- {check} {text} "
                f"· len `{length}` · category `{category}` · patterns `{patterns}`"
            )
            if rejected:
                line += f" · rejected `{rejected}`"
            if note:
                line += f" — _{note}_"
            st.markdown(line)


def _render_extractor_diagnostics(wp: dict) -> None:
    keys = (
        "extractorModelId",
        "extractorLatencyMs",
        "extractorInputTokens",
        "extractorOutputTokens",
        "extractorRawText",
        "extractorRequestPrompt",
        "extractorErrorClass",
        "extractorErrorMessage",
        "extractorError",
        "embeddingModel",
        "embeddedCount",
        "ttlExpiresAt",
        "primaryOutcome",
        "primaryErrorClass",
        "primaryErrorMessage",
        "fallbackBackend",
        "fallbackOutcome",
        "fallbackErrorClass",
        "fallbackErrorMessage",
        "bytesPersisted",
    )
    diag = {k: wp.get(k) for k in keys if wp.get(k) is not None}
    if not diag:
        return
    st.caption("Extractor + embedding + outcome diagnostics")
    st.code(json.dumps(diag, indent=2, default=str), language="json")


def _dev_memory_internals(events: list[dict]) -> None:
    scoped = _events_of(events, "memory.scoped_read")
    shared = _events_of(events, "memory.shared_read")
    writes = _events_of(events, "memory.long_term_write")
    skips = _events_of(events, "memory.long_term_skip")
    if not (scoped or shared or writes or skips):
        return

    with st.expander("Long-term memory internals", expanded=False):
        st.caption(
            "Debug-grade depth: per-collection latency + error column, full "
            "candidate inspection table, live `MEMORY_*` env-knob values, "
            "extractor diagnostics, raw payload JSON. The slim client summary "
            "lives in the Long-term memory section above."
        )

        for r in scoped + shared:
            rp = _payload(r)
            kind = "Agent-scoped" if r.get("type") == "memory.scoped_read" else "Shared"
            st.markdown(
                f"**{kind} read** — `mode={rp.get('mode') or 'n/a'}` · "
                f"backend `{rp.get('backend') or '?'}` · "
                f"{_as_int(rp.get('latencyMs'))} ms · "
                f"primaryFailed={bool(rp.get('primaryFailed'))}"
            )
            retrieval = rp.get("retrieval") or {}
            per_collection = retrieval.get("perCollection") or []
            _render_per_collection_dev_table(per_collection if isinstance(per_collection, list) else [])
            _render_env_knob_values(rp)
            if rp.get("retrievalErrorMessage"):
                st.error(
                    f"{rp.get('retrievalErrorClass') or 'RetrievalError'}: "
                    f"{rp.get('retrievalErrorMessage')}"
                )
            with st.expander("Raw payload", expanded=False):
                _render_jsonish(rp)

        for w in writes:
            wp = _payload(w)
            outcome = str(wp.get("primaryOutcome") or "?")
            st.markdown(
                f"**Long-term write** — outcome `{outcome}` · "
                f"{_as_int(wp.get('docsInserted'))} inserted · "
                f"{_as_int(wp.get('duplicatesSkipped'))} dup skipped · "
                f"{_as_int(wp.get('latencyMs'))} ms"
            )
            candidates = wp.get("factCandidates") or []
            _render_candidates_dev_table(candidates if isinstance(candidates, list) else [])
            _render_extractor_diagnostics(wp)
            with st.expander("Raw payload", expanded=False):
                _render_jsonish(wp)

        for s in skips:
            sp = _payload(s)
            st.markdown(
                f"**Write skipped** — reason `{sp.get('reason') or 'unknown'}` · "
                f"agent `{sp.get('agentId') or '?'}`"
            )
            with st.expander("Raw payload", expanded=False):
                _render_jsonish(sp)


# ---------------------------------------------------------------------------
# _dev_agentcore_internals
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _dev_orchestrator_internals — multi-specialist orchestration raw view
# ---------------------------------------------------------------------------


def _dev_orchestrator_internals(events: list[dict]) -> None:
    """Raw orchestration view for the multi-specialist flow.

    Renders three event families when present:
      - ``orchestrator.multi_route_decision`` — classifier scores,
        thresholds, every rejected candidate.
      - ``orchestrator.specialist_draft`` — per-specialist draft preview
        (full text up to the per-event byte cap), runtime span id, failure
        stack when present.
      - ``orchestrator.synthesis`` — synthesizer agent metadata: model id,
        inputs, omitted specialists, output bytes, persistence flag.

    Older traces (single-specialist single-handoff) emit none of these,
    so this section degrades to nothing.
    """
    decisions = _events_of(events, "orchestrator.multi_route_decision")
    drafts = _events_of(events, "orchestrator.specialist_draft")
    syntheses = _events_of(events, "orchestrator.synthesis")
    if not (decisions or drafts or syntheses):
        return

    with st.expander("Orchestrator internals (multi-specialist)", expanded=False):
        # ---- Multi-route decision ---------------------------------------
        for d in decisions:
            p = _payload(d)
            path = p.get("pathTaken") or "single"
            latency = p.get("latencyMs")
            latency_str = f" · decided in {int(latency)} ms" if isinstance(latency, (int, float)) else ""
            st.markdown(f"**Path:** `{path}`{latency_str}")

            sel = p.get("selected") or []
            if sel:
                st.caption(f"Selected ({len(sel)}):")
                rows = "| # | agentId | source | score | reasoning |\n|---|---|---|---|---|\n"
                for i, s in enumerate(sel):
                    score = s.get("score")
                    score_str = (
                        f"{float(score):.2f}" if isinstance(score, (int, float)) else "—"
                    )
                    reasoning = (s.get("reasoning") or "—").replace("|", "\\|")
                    rows += (
                        f"| {i + 1} | `{s.get('agentId') or '?'}` | "
                        f"`{s.get('source') or '?'}` | {score_str} | {reasoning} |\n"
                    )
                st.markdown(rows)

            rej = p.get("rejected") or []
            if rej:
                with st.container(border=True):
                    st.caption(f"Rejected candidates ({len(rej)}):")
                    rows = "| agentId | score | reason |\n|---|---|---|\n"
                    for r in rej:
                        score = r.get("score")
                        score_str = (
                            f"{float(score):.2f}" if isinstance(score, (int, float)) else "—"
                        )
                        reason = (r.get("reason") or "—").replace("|", "\\|")
                        rows += f"| `{r.get('agentId') or '?'}` | {score_str} | {reason} |\n"
                    st.markdown(rows)

            thresholds = p.get("thresholds")
            if isinstance(thresholds, dict):
                st.caption("Thresholds (env-knob snapshot):")
                _render_jsonish(thresholds)
            elif _is_omitted_sentinel(thresholds):
                _render_omitted_sentinel(thresholds, label="thresholds")

            input_msg = p.get("inputMessage")
            if input_msg:
                st.caption("Input message preview:")
                st.code(_short_text(str(input_msg), 1000))

        # ---- Per-specialist drafts --------------------------------------
        if drafts:
            st.markdown("**Specialist drafts**")
            for dr in drafts:
                dp = _payload(dr)
                rank = dp.get("rank")
                name = dp.get("agentName") or dp.get("agentId") or "?"
                status = dp.get("status") or "?"
                bytes_ = dp.get("answerBytes") or 0
                latency = dp.get("latencyMs")
                latency_str = f" · {int(latency)} ms" if isinstance(latency, (int, float)) else ""
                rank_str = f"#{rank} " if isinstance(rank, int) else ""
                with st.container(border=True):
                    st.markdown(
                        f"{rank_str}**{name}** — `{status}` · {bytes_} bytes{latency_str}"
                    )
                    span_id = dp.get("runtimeSpanId")
                    if span_id:
                        st.caption(f"runtimeSpanId: `{span_id}`")
                    elif _is_omitted_sentinel(span_id):
                        _render_omitted_sentinel(span_id, label="runtimeSpanId")
                    preview = dp.get("answerPreview")
                    if _is_omitted_sentinel(preview):
                        _render_omitted_sentinel(preview, label="answerPreview")
                    elif preview:
                        st.caption("Draft preview:")
                        st.code(_short_text(str(preview), 4000))
                    if dp.get("failureClass") or dp.get("failureMessage"):
                        st.error(
                            f"{dp.get('failureClass') or 'Error'}: "
                            f"{dp.get('failureMessage') or 'unknown'}"
                        )
                    stack = dp.get("failureStack")
                    if _is_omitted_sentinel(stack):
                        _render_omitted_sentinel(stack, label="failureStack")
                    elif stack:
                        with st.expander("failureStack", expanded=False):
                            st.code(str(stack))

        # ---- Synthesis summary ------------------------------------------
        if syntheses:
            st.markdown("**Synthesizer agent**")
            for sy in syntheses:
                sp = _payload(sy)
                model = sp.get("modelId") or "?"
                out_bytes = sp.get("outputBytes") or 0
                latency = sp.get("latencyMs")
                latency_str = f" · {int(latency)} ms" if isinstance(latency, (int, float)) else ""
                persisted = sp.get("finalAnswerPersisted")
                pers_chip = (
                    " · :material/check_circle: persisted"
                    if persisted
                    else " · :material/cancel: not persisted"
                )
                st.markdown(
                    f"model `{model}` · {out_bytes} bytes{latency_str}{pers_chip}"
                )
                inputs = sp.get("inputSpecialists") or []
                if inputs:
                    st.caption(f"Input specialists ({len(inputs)}):")
                    rows = "| agentId | bytes |\n|---|---|\n"
                    for i in inputs:
                        rows += f"| `{i.get('agentId') or '?'}` | {i.get('answerBytes') or 0} |\n"
                    st.markdown(rows)
                omitted = sp.get("omittedSpecialists") or []
                if omitted:
                    st.caption(f"Omitted ({len(omitted)}):")
                    rows = "| agentId | reason |\n|---|---|\n"
                    for o in omitted:
                        rows += f"| `{o.get('agentId') or '?'}` | `{o.get('reason') or '?'}` |\n"
                    st.markdown(rows)


# ---------------------------------------------------------------------------
# _dev_agentcore_internals
# ---------------------------------------------------------------------------


def _dev_agentcore_internals(trace: dict, events: list[dict]) -> None:
    invokes = _events_of(events, "agentcore.invoke")
    nested = _events_of(events, "agentcore.nested_trace")
    obs = _events_of(events, "agentcore.observability_link")
    gateways = _events_of(events, "agentcore.gateway")
    if not (invokes or nested or obs or gateways):
        return

    with st.expander("AgentCore internals", expanded=False):
        for inv in invokes:
            ip = _payload(inv)
            target = ip.get("targetAgentId") or "?"
            st.markdown(
                f"**Invoke `{ip.get('mode') or '?'}` → `{target}`** — "
                f"{_as_int(ip.get('latencyMs'))} ms · "
                f"status {ip.get('httpStatus') or '—'} · "
                f"in {_as_int(ip.get('requestBytes'))} B / out {_as_int(ip.get('responseBytes'))} B"
            )
            st.caption(f"ARN: `{ip.get('arn') or '—'}`")
            for label, field in (
                ("runtimeSessionId", "runtimeSessionId"),
                ("runtimeRequestId", "runtimeRequestId"),
                ("region", "region"),
                ("qualifier", "qualifier"),
            ):
                value = ip.get(field)
                if value:
                    st.caption(f"{label}: `{value}`")
            for label, field in (
                ("payload (request)", "payload"),
                ("responseBody", "responseBody"),
                ("requestHeadersPreview", "requestHeadersPreview"),
                ("responseHeadersPreview", "responseHeadersPreview"),
            ):
                value = ip.get(field)
                if _is_omitted_sentinel(value):
                    _render_omitted_sentinel(value, label=label)
                elif value is not None:
                    st.caption(label)
                    _render_jsonish(value)
            if ip.get("errorMessage"):
                st.error(f"{ip.get('errorClass') or 'Error'}: {ip.get('errorMessage')}")

        for nm in nested:
            np = _payload(nm)
            nested_id = np.get("nestedTraceId") or "unknown"
            st.markdown(
                f"**Nested trace** `{nested_id}` — "
                f"{_as_int(np.get('eventCount'))} events spliced · "
                f"dropped {_as_int(np.get('nestedEventsDropped'))}"
            )
            if np.get("nestedRuntimeArn"):
                st.caption(f"nestedRuntimeArn: `{np['nestedRuntimeArn']}`")

        for o in obs:
            op = _payload(o)
            xray = op.get("xrayUrl")
            cw = op.get("cloudwatchLogStreamUrl")
            chunks: list[str] = []
            if xray:
                chunks.append(f"[X-Ray]({xray})")
            if cw:
                chunks.append(f"[CloudWatch]({cw})")
            if chunks:
                st.markdown("  ·  ".join(chunks))

        for g in gateways:
            gp = _payload(g)
            st.caption(
                f"Gateway: arn `{gp.get('gatewayArn') or '—'}` · "
                f"target `{gp.get('targetName') or '—'}` · "
                f"routing `{gp.get('routingDecision') or '—'}`"
            )


# ---------------------------------------------------------------------------
# _dev_tool_calls_verbose
# ---------------------------------------------------------------------------

def _dev_tool_calls_verbose(events: list[dict]) -> None:
    tool_calls = _events_of(events, "tool.call")
    https = _events_of(events, "tool.http")
    mcps = _events_of(events, "tool.mcp")
    if not (tool_calls or https or mcps):
        return

    with st.expander("Tool calls (verbose)", expanded=False):
        for e in tool_calls:
            p = _payload(e)
            phase = p.get("phase") or ("end" if e.get("durationMs") is not None else "start")
            name = p.get("toolName") or "?"
            tool_use_id = p.get("toolUseId") or "—"
            st.markdown(
                f"**`{name}`** — phase `{phase}` · toolUseId `{tool_use_id}` · "
                f"id `{e.get('id') or '—'}` · parentId `{e.get('parentId') or '—'}`"
            )
            for label, field in (
                ("input", "input"),
                ("result", "result"),
            ):
                value = p.get(field)
                if _is_omitted_sentinel(value):
                    _render_omitted_sentinel(value, label=label)
                elif value is not None:
                    st.caption(label)
                    _render_jsonish(value)
            if p.get("error"):
                err = p["error"]
                st.error(
                    f"{(err or {}).get('class') or 'ToolError'}: "
                    f"{(err or {}).get('message') or 'unknown'}"
                )

        for h in https:
            hp = _payload(h)
            st.markdown(
                f"**HTTP `{hp.get('method') or '?'}` {hp.get('url') or '?'}** — "
                f"status {hp.get('status') or '—'}"
            )
            for label, field in (
                ("headers", "headers"),
                ("body", "body"),
                ("responseSnippet", "responseSnippet"),
            ):
                value = hp.get(field)
                if _is_omitted_sentinel(value):
                    _render_omitted_sentinel(value, label=label)
                elif value is not None:
                    st.caption(label)
                    _render_jsonish(value)
            if hp.get("blocked"):
                st.warning(f"Blocked: {hp.get('blocked')}")

        for m in mcps:
            mp = _payload(m)
            st.markdown(
                f"**MCP `{mp.get('toolName') or '?'}`** on `{mp.get('server') or '?'}` "
                f"({mp.get('transport') or '?'})"
            )
            for label, field in (
                ("args", "args"),
                ("result", "result"),
            ):
                value = mp.get(field)
                if _is_omitted_sentinel(value):
                    _render_omitted_sentinel(value, label=label)
                elif value is not None:
                    st.caption(label)
                    _render_jsonish(value)
            if mp.get("errorMessage"):
                st.error(f"{mp.get('errorClass') or 'McpError'}: {mp['errorMessage']}")


# ---------------------------------------------------------------------------
# _dev_skill_resource_reads
# ---------------------------------------------------------------------------

def _dev_skill_resource_reads(events: list[dict]) -> None:
    skills = _events_of(events, "skill.activated")
    rows: list[tuple[str, dict]] = []
    for s in skills:
        sp = _payload(s)
        for r in sp.get("resourceReads") or []:
            if isinstance(r, dict):
                rows.append((sp.get("name") or "?", r))
    with st.expander(f"Skill resource reads ({len(rows)})", expanded=False):
        if not rows:
            st.caption("No skill resources read this turn.")
            return
        md = "| Skill | Resource | Bytes | Latency ms | toolUseId |\n|---|---|---:|---:|---|\n"
        for skill_name, r in rows:
            md += (
                f"| `{skill_name}` "
                f"| `{r.get('resourcePath') or '—'}` "
                f"| {_as_int(r.get('bytes'))} "
                f"| {_as_int(r.get('latencyMs'))} "
                f"| `{r.get('toolUseId') or '—'}` |\n"
            )
        st.markdown(md)


# ---------------------------------------------------------------------------
# _dev_retries
# ---------------------------------------------------------------------------

def _dev_retries(events: list[dict]) -> None:
    model_retries = [(e, "model") for e in _events_of(events, "model.retry")]
    ac_retries = [(e, "agentcore") for e in _events_of(events, "agentcore.retry")]
    combined = sorted(model_retries + ac_retries, key=lambda pair: int(pair[0].get("ts") or 0))
    with st.expander(f"Retries ({len(combined)})", expanded=False):
        if not combined:
            st.caption("No retries — every call succeeded on the first attempt.")
            return
        md = "| ts | Layer | Attempt | Previous error | Backoff ms | Target |\n|---|---|---:|---|---:|---|\n"
        for ev, layer in combined:
            p = _payload(ev)
            if layer == "model":
                target = p.get("modelId") or "—"
            else:
                target = f"{p.get('arn') or '—'} → {p.get('targetAgentId') or '—'}"
            md += (
                f"| {ev.get('ts') or 0} "
                f"| `{layer}` "
                f"| {_as_int(p.get('attempt'))} "
                f"| `{p.get('previousErrorClass') or '—'}` "
                f"| {_as_int(p.get('backoffMs'))} "
                f"| `{target}` |\n"
            )
        st.markdown(md)


# ---------------------------------------------------------------------------
# _dev_performance
# ---------------------------------------------------------------------------

def _dev_performance(events: list[dict]) -> None:
    checkpoints = _events_of(events, "latency.checkpoint")
    deltas = _events_of(events, "model.text_delta_batch")
    ends = _events_of(events, "chat.turn.end")
    if not (checkpoints or deltas or ends):
        return

    with st.expander("Performance + checkpoints", expanded=False):
        if checkpoints:
            md = "| Name | Elapsed ms | Event kind | Part type | Tool | Agent |\n|---|---:|---|---|---|---|\n"
            for c in checkpoints:
                p = _payload(c)
                md += (
                    f"| `{p.get('name') or '—'}` "
                    f"| {_as_int(p.get('elapsedMs'))} "
                    f"| `{p.get('eventKind') or '—'}` "
                    f"| `{p.get('partType') or '—'}` "
                    f"| `{p.get('toolName') or '—'}` "
                    f"| `{p.get('agentId') or '—'}` |\n"
                )
            st.markdown(md)

        if deltas:
            data: list[dict[str, int]] = []
            cumulative = 0
            for d in deltas:
                p = _payload(d)
                cum = p.get("cumulativeBytes")
                cumulative = _as_int(cum, cumulative + _as_int(p.get("bytes")))
                data.append({"ts": _as_int(d.get("ts")), "cumulativeBytes": cumulative})
            if data:
                st.caption("Streaming throughput (cumulativeBytes over ts)")
                try:
                    st.line_chart(data, x="ts", y="cumulativeBytes")
                except Exception:
                    _render_jsonish(data)

        for end in ends:
            ep = _payload(end)
            summary = (ep.get("summary") or {}) if isinstance(ep.get("summary"), dict) else {}
            bytes_in = summary.get("bytesIn") or ep.get("bytesIn")
            bytes_out = summary.get("bytesOut") or ep.get("bytesOut")
            if bytes_in is not None or bytes_out is not None:
                st.caption(f"Turn IO — bytesIn {_as_int(bytes_in):,} · bytesOut {_as_int(bytes_out):,}")


# ---------------------------------------------------------------------------
# _dev_cost_breakdown
# ---------------------------------------------------------------------------

def _dev_cost_breakdown(trace: dict) -> None:
    summary = trace.get("summary") if isinstance(trace.get("summary"), dict) else {}
    cost = summary.get("estimatedCostUsd")
    if cost is None and not summary.get("costBreakdown"):
        return
    with st.expander("Cost breakdown", expanded=False):
        if cost is not None:
            complete = summary.get("costEstimateComplete", True)
            mark = "" if complete else "≈"
            st.markdown(f"**Estimated cost** — {mark}${float(cost):.6f}")
            if not complete:
                st.warning("`costEstimateComplete=false` — not every token-using call was priced.")
        breakdown = summary.get("costBreakdown")
        if breakdown:
            _render_jsonish(breakdown)


# ---------------------------------------------------------------------------
# _dev_environment
# ---------------------------------------------------------------------------

def _dev_environment(trace: dict, events: list[dict]) -> None:
    release = trace.get("release") or {}
    env_events = _events_of(events, "dev.environment")
    markers = _mock_markers(events)
    if not (release or env_events or markers):
        return

    with st.expander("Environment", expanded=False):
        if release:
            st.caption("Release")
            _render_jsonish(release)
        for env in env_events:
            st.caption("Runtime environment (dev.environment)")
            _render_jsonish(_payload(env))
        if markers:
            chips = " ".join(f'<span class="trace-chip">{m}</span>' for m in markers[:8])
            st.markdown(f"**Mock/dev markers**<br>{chips}", unsafe_allow_html=True)


# ---------------------------------------------------------------------------
# _dev_byte_cap
# ---------------------------------------------------------------------------

def _dev_byte_cap(trace: dict, events: list[dict]) -> None:
    drops = _events_of(events, "dev.byte_cap_hit")
    truncated = _trace_is_truncated(trace)
    dropped_count = _trace_events_dropped(trace)
    if not (drops or truncated or dropped_count):
        return

    with st.expander(f"Byte cap drops ({len(drops)})", expanded=False):
        if truncated:
            st.warning(
                f"`trace.truncated=true` — {dropped_count} event(s) dropped at the per-turn cap."
            )
        if not drops:
            st.caption("No per-event-type byte-cap hits recorded.")
            return
        md = "| ts | Dropped type | Bytes | Reason |\n|---|---|---:|---|\n"
        for d in drops:
            p = _payload(d)
            md += (
                f"| {d.get('ts') or 0} "
                f"| `{p.get('droppedType') or '?'}` "
                f"| {_as_int(p.get('bytes'))} "
                f"| `{p.get('reason') or '?'}` |\n"
            )
        st.markdown(md)


# ---------------------------------------------------------------------------
# _dev_raw_events
# ---------------------------------------------------------------------------

_RAW_EVENTS_PAGE_SIZE = 200


def _dev_raw_events(trace: dict, events: list[dict]) -> None:
    with st.expander(f"Raw events ({len(events)})", expanded=False):
        if not events:
            st.caption("No events on this trace.")
            return

        all_types = sorted({str(e.get("type") or "") for e in events if e.get("type")})
        trace_id = trace.get("traceId") or "trace"

        col_filter, col_search = st.columns([2, 3])
        with col_filter:
            chosen = st.multiselect(
                "Filter by type",
                all_types,
                default=[],
                key=f"raw_filter_{trace_id}",
            )
        with col_search:
            query = st.text_input(
                "Text search (substring across the serialized event)",
                key=f"raw_search_{trace_id}",
            )

        filtered = events
        if chosen:
            filtered = [e for e in filtered if str(e.get("type") or "") in set(chosen)]
        if query:
            needle = query.lower()
            filtered = [
                e
                for e in filtered
                if needle in json.dumps(e, default=str).lower()
            ]

        total = len(filtered)
        page_size = _RAW_EVENTS_PAGE_SIZE
        max_page = max(1, (total + page_size - 1) // page_size)
        page = st.number_input(
            f"Page (1–{max_page}, {page_size} events per page)",
            min_value=1,
            max_value=max_page,
            value=1,
            step=1,
            key=f"raw_page_{trace_id}",
        )
        start = (int(page) - 1) * page_size
        end = start + page_size
        page_events = filtered[start:end]

        st.caption(
            f"Showing {start + 1 if page_events else 0}–{start + len(page_events)} "
            f"of {total} matched event(s) · {len(events)} total event(s) on trace · "
            f"degraded={_trace_is_truncated(trace)} · dropped={_trace_events_dropped(trace)}"
        )
        _render_jsonish(page_events)

        st.download_button(
            "Download full trace JSON",
            data=json.dumps(trace, default=str, indent=2),
            file_name=f"trace-{trace_id}.json",
            mime="application/json",
            key=f"raw_download_{trace_id}",
        )
