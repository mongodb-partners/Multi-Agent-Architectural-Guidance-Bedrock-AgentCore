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
from collections import defaultdict
from typing import Any

import streamlit as st


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _events_of(events: list[dict], *types: str) -> list[dict]:
    s = set(types)
    return [e for e in events if e.get("type") in s]


def _tile_html(label: str, value: str, hint: str | None = None) -> str:
    extra = f'<div class="trace-tile-hint">{hint}</div>' if hint else ""
    return (
        f'<div class="trace-tile">'
        f'<div class="trace-tile-label">{label}</div>'
        f'<div class="trace-tile-value">{value}</div>'
        f"{extra}"
        f"</div>"
    )


# ---------------------------------------------------------------------------
# 1. Summary header
# ---------------------------------------------------------------------------

def render_summary_header(trace: dict) -> None:
    summary = trace.get("summary") or {}
    tiles: list[str] = []
    if summary.get("durationMs"):
        tiles.append(_tile_html("Latency", f"{int(summary['durationMs']) / 1000:.2f}s"))
    if summary.get("totalTokens"):
        tiles.append(
            _tile_html(
                "Tokens",
                f"{int(summary['totalTokens']):,}",
                hint=f"{summary.get('inputTokens', 0):,} in / {summary.get('outputTokens', 0):,} out",
            )
        )
    cost = summary.get("estimatedCostUsd")
    if cost is not None:
        mark = "" if summary.get("costEstimateComplete") else "≈"
        tiles.append(_tile_html("Cost", f"{mark}${float(cost):.4f}"))
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
    if summary.get("mongoQueriesCount"):
        tiles.append(_tile_html("Mongo ops", str(summary["mongoQueriesCount"])))
    if tiles:
        st.markdown("".join(tiles), unsafe_allow_html=True)
    if summary.get("degraded"):
        st.warning("This trace was byte-capped — some low-priority events were dropped.")


# ---------------------------------------------------------------------------
# 2. Mock backend banner
# ---------------------------------------------------------------------------

def render_mock_banner(events: list[dict]) -> None:
    req = _events_of(events, "model.request")
    if any((e.get("payload") or {}).get("backend") == "mock" for e in req):
        st.markdown(
            '<div class="trace-banner-mock">🧪 <strong>Mock backend</strong> — '
            "this turn ran against <code>DEV_MOCK_BACKENDS</code>; no real Bedrock/Atlas call was made."
            "</div>",
            unsafe_allow_html=True,
        )


# ---------------------------------------------------------------------------
# 3. Timeline (Gantt-style, lightweight HTML)
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

def render_routing(events: list[dict]) -> None:
    decisions = _events_of(events, "handoff.decision")
    if not decisions:
        return
    st.markdown('<div class="trace-section-title">Routing decisions</div>', unsafe_allow_html=True)
    for d in decisions:
        p = d.get("payload") or {}
        fr, to = p.get("fromAgentId"), p.get("toAgentId")
        src = p.get("routingSource") or "llm"
        conf = p.get("confidence")
        chips: list[str] = [f'<span class="trace-chip">{src}</span>']
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
    queries = _events_of(events, "mongo.query")
    results = _events_of(events, "mongo.result")
    plans = _events_of(events, "mongo.plan")
    diags = _events_of(events, "mongo.diagnostic")
    schemas = _events_of(events, "mongo.schema")
    vectors = _events_of(events, "mongo.vector_search")
    if not (queries or vectors or results):
        return
    st.markdown('<div class="trace-section-title">MongoDB</div>', unsafe_allow_html=True)
    # Pair query+result by index — they're emitted in order.
    for i, q in enumerate(queries):
        qp = q.get("payload") or {}
        rp = (results[i].get("payload") if i < len(results) else None) or {}
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
                st.json(rp["sampleDocs"])
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
        vp = v.get("payload") or {}
        with st.expander(
            f"🧭 vector_search — embed via {vp.get('embeddingSource')} — {len(vp.get('scores') or [])} hit(s)",
            expanded=False,
        ):
            st.caption(f"Query: {vp.get('queryText')}")
            if vp.get("scoreSummary"):
                ss = vp["scoreSummary"]
                st.caption(f"Scores — min {ss.get('min', 0):.3f}, max {ss.get('max', 0):.3f}, avg {ss.get('avg', 0):.3f}")
            if vp.get("histogram"):
                hist = vp["histogram"]
                cols = st.columns(len(hist))
                for j, count in enumerate(hist):
                    with cols[j]:
                        st.metric(f"bin {j + 1}", count)

    if schemas:
        with st.expander(f"Schema samples ({len(schemas)})", expanded=False):
            for s in schemas:
                sp = s.get("payload") or {}
                st.markdown(
                    f"**{sp.get('collection')}** — {sp.get('estimatedDocumentCount', 0)} estimated docs"
                )
                if sp.get("fields"):
                    st.json([{"name": f.get("name"), "type": f.get("type")} for f in sp["fields"][:30]])


# ---------------------------------------------------------------------------
# 6. Tool calls
# ---------------------------------------------------------------------------

def render_tool_calls(events: list[dict]) -> None:
    spans = defaultdict(dict)
    for e in _events_of(events, "tool.call"):
        p = e.get("payload") or {}
        name = str(p.get("toolName") or "?")
        if p.get("phase") == "start":
            spans[name]["start"] = p
        elif p.get("phase") == "end":
            spans[name]["end"] = p
    https = _events_of(events, "tool.http")
    mcps = _events_of(events, "tool.mcp")
    if not (spans or https or mcps):
        return
    st.markdown('<div class="trace-section-title">Tool calls</div>', unsafe_allow_html=True)
    for name, info in spans.items():
        end = info.get("end") or {}
        with st.expander(f"🔧 `{name}` — {end.get('latencyMs', 0)} ms", expanded=False):
            if (info.get("start") or {}).get("input"):
                st.caption("Input")
                st.json((info["start"] or {}).get("input"))
            if end.get("result") is not None:
                st.caption("Result")
                st.json(end["result"])
            if end.get("error"):
                st.error(end["error"].get("message") or "Tool error")
    for h in https:
        hp = h.get("payload") or {}
        emoji = "❌" if hp.get("blocked") or hp.get("errorClass") else f"📡 {hp.get('status') or '?'}"
        with st.expander(
            f"{emoji} HTTP {hp.get('method')} {hp.get('url')}", expanded=False
        ):
            if hp.get("body"):
                st.json(hp["body"])
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
                st.json(mp["args"])
            if mp.get("result") is not None:
                st.json(mp["result"])
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
                st.json(ip["payload"])
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
        if wp.get("factsExtracted"):
            with st.expander("Facts extracted", expanded=False):
                for f in wp["factsExtracted"]:
                    st.markdown(f"- {f}")
        if wp.get("factCandidates"):
            with st.expander("All candidates considered", expanded=False):
                for c in wp["factCandidates"]:
                    if c.get("matched"):
                        st.markdown(f"- ✅ `{c.get('text')}` ({', '.join(c.get('matchedPatterns') or [])})")
                    else:
                        st.markdown(f"- ✗ `{c.get('text')}` — {c.get('rejectedReason')}")
    for s in skips:
        sp = s.get("payload") or {}
        st.caption(f"⏭ Write skipped — {sp.get('reason')}")


# ---------------------------------------------------------------------------
# 9. Developer details (raw events)
# ---------------------------------------------------------------------------

def render_developer_details(trace: dict) -> None:
    with st.expander("Developer details — raw events", expanded=False):
        events = trace.get("events") or []
        st.caption(
            f"{len(events)} event(s) · degraded={bool((trace.get('summary') or {}).get('degraded'))}"
            f" · dropped={trace.get('eventsDropped', 0)}"
        )
        st.json(events)


def render_trace_meta(trace: dict) -> None:
    st.caption(
        f"Trace `{trace.get('traceId', '')[:8]}…` · session `{trace.get('sessionId', '')[:8]}…`"
        f" · agent `{trace.get('agentId', '')}` · created {trace.get('createdAt', '')}"
    )
