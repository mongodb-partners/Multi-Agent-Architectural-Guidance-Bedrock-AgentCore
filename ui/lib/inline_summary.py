"""Inline summary card rendered under the assistant reply.

Shown for every assistant turn whenever at least one trace event arrived.
High-priority signals are surfaced prominently as tiles; lower-priority
detail collapses into "View full trace" + a developer-details expander.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

import streamlit as st

from lib.api_client import TraceEvent


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
    backend_mock: bool = False
    error_count: int = 0
    degraded: bool = False

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
            or self.trace_id
        )


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


def aggregate_summary(events: Iterable[TraceEvent]) -> TurnSummary:
    s = TurnSummary()
    cost_total = 0.0
    saw_unknown_model = False
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

        elif t == "model.request":
            backend = str(p.get("backend") or "")
            if backend == "mock":
                s.backend_mock = True

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

        elif t == "skill.activated":
            name = str(p.get("name") or "")
            if name and name not in s.skills_activated:
                s.skills_activated.append(name)

        elif t == "memory.scoped_read" or t == "memory.shared_read":
            s.memory_facts_read += int(p.get("entryCount") or 0)

        elif t == "memory.long_term_write":
            s.memory_facts_written += int(p.get("docsInserted") or 0)

        elif t == "agentcore.invoke":
            s.agentcore_invokes += 1

        elif t == "agentcore.nested_trace":
            s.agentcore_nested += int(p.get("eventCount") or 0)

        elif t == "error":
            s.error_count += 1

    s.cost_usd = cost_total if cost_total > 0 else None
    s.cost_estimate_complete = not saw_unknown_model
    return s


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _tile(label: str, value: str, *, hint: str | None = None) -> None:
    st.markdown(
        f"""
<div style="
    background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 10px;
    padding: 10px 12px;
    min-width: 90px;
    display: inline-block;
    margin-right: 8px;
    margin-bottom: 8px;
">
  <div style="font-size: 11px; opacity: 0.65; letter-spacing: 0.04em; text-transform: uppercase;">{label}</div>
  <div style="font-size: 17px; font-weight: 600; margin-top: 2px;">{value}</div>
  {f'<div style="font-size: 11px; opacity: 0.55; margin-top: 2px;">{hint}</div>' if hint else ''}
</div>
""",
        unsafe_allow_html=True,
    )


def render_inline_summary(
    s: TurnSummary,
    *,
    trace_url: str | None = None,
    raw_events: list[TraceEvent] | None = None,
) -> None:
    """Render the inline summary card under an assistant reply."""
    if not s.has_signal():
        return

    if s.backend_mock:
        st.info("This turn ran against **DEV_MOCK_BACKENDS** — no real Bedrock/Atlas call.", icon="🧪")

    # ── Top tile row — high priority signals ──────────────────────────────
    cols = st.columns([1, 1, 1, 1, 1])
    with cols[0]:
        if s.duration_ms:
            _tile("Latency", f"{s.duration_ms / 1000:.1f}s")
    with cols[1]:
        if s.total_tokens:
            _tile("Tokens", f"{s.total_tokens:,}", hint=f"{s.input_tokens:,} in / {s.output_tokens:,} out")
    with cols[2]:
        if s.cost_usd is not None:
            mark = "≈" if not s.cost_estimate_complete else ""
            _tile("Cost", f"{mark}${s.cost_usd:.4f}")
    with cols[3]:
        if s.tools_used:
            _tile("Tools", str(len(s.tools_used)), hint=", ".join(s.tools_used[:2]))
    with cols[4]:
        if s.mongo_ops:
            success = sum(1 for op in s.mongo_ops if op["status"] != "error")
            _tile(
                "MongoDB",
                f"{success}/{len(s.mongo_ops)} ok",
                hint=f"avg {sum(op['latencyMs'] for op in s.mongo_ops) // max(len(s.mongo_ops), 1)} ms",
            )

    # ── Memory + skills + agentcore badges ─────────────────────────────────
    badges: list[str] = []
    if s.memory_facts_read:
        badges.append(f"🧠 {s.memory_facts_read} fact{'s' if s.memory_facts_read != 1 else ''} read")
    if s.memory_facts_written:
        badges.append(f"💾 {s.memory_facts_written} stored")
    if s.skills_activated:
        badges.append(f"📚 Skills: {', '.join(s.skills_activated[:3])}")
    if s.agentcore_invokes:
        badges.append(f"☁️ AgentCore × {s.agentcore_invokes}")
    if s.handoffs:
        for fr, to in s.handoffs:
            badges.append(f"🔀 `{fr}` → `{to}`")
    if s.error_count:
        badges.append(f"⚠️ {s.error_count} error{'s' if s.error_count != 1 else ''}")
    if badges:
        st.markdown(" · ".join(badges))

    # ── Mongo mini-trail (compact) ────────────────────────────────────────
    if s.mongo_ops:
        with st.expander(f"MongoDB ops ({len(s.mongo_ops)})", expanded=False):
            for i, op in enumerate(s.mongo_ops, 1):
                emoji = "✅" if op["status"] == "ok" else ("∅" if op["status"] == "empty" else "❌")
                st.markdown(f"{emoji} **#{i}** — {op['docCount']} docs · {op['latencyMs']} ms · {op['status']}")

    # ── Footer link to full trace + developer details ─────────────────────
    if trace_url:
        st.markdown(f"[**View full trace →**]({trace_url})")

    if raw_events:
        with st.expander("Developer details (raw trace events)", expanded=False):
            st.json([_event_to_json(e) for e in raw_events])

    if s.degraded:
        st.caption("⚠️ Trace was byte-capped — some low-priority events were dropped.")


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
