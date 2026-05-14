"""Trace Viewer link rendered under the assistant reply."""

from __future__ import annotations

from dataclasses import dataclass, field
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
            or self.trace_id
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


_THINKING_PREVIEW_CHARS = 280


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
    header = "🧠 Reasoning — " + " · ".join(parts)

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
                f"🤔 Thinking block #{i}"
                f" ({len(block):,} chars)" if truncated else f"🤔 Thinking block #{i}"
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
    tid = trace_id or trace_id_from_url(trace_url)
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
