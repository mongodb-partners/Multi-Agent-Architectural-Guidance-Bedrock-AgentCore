"""Sidebar block showing live, aggregated metrics from /traces.

Cached for 10 seconds to avoid hammering the API during demos.
"""

from __future__ import annotations

import streamlit as st

from lib.api_client import get_trace, list_recent_traces


@st.cache_data(ttl=10, show_spinner=False)
def _recent(api_base: str, token: str | None, limit: int) -> list[dict]:
    try:
        return list_recent_traces(api_base, limit=limit, access_token=token)
    except Exception:
        return []


@st.cache_data(ttl=10, show_spinner=False)
def _trace_detail(api_base: str, token: str | None, trace_id: str) -> dict | None:
    try:
        return get_trace(api_base, trace_id=trace_id, access_token=token, include="core")
    except Exception:
        return None


def _as_int(value: object) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _duration_ms(trace: dict) -> int:
    summary = trace.get("summary") if isinstance(trace.get("summary"), dict) else {}
    for value in (trace.get("durationMs"), summary.get("durationMs")):
        duration = _as_int(value)
        if duration:
            return duration

    events = trace.get("events")
    if isinstance(events, list):
        for ev in reversed(events):
            if not isinstance(ev, dict) or ev.get("type") != "chat.turn.end":
                continue
            payload = ev.get("payload") if isinstance(ev.get("payload"), dict) else {}
            duration = _as_int(payload.get("durationMs"))
            if duration:
                return duration
    return 0


def render_metrics_block(api_base: str, token: str | None) -> None:
    traces = _recent(api_base, token, 25)
    if not traces:
        return

    total_cost = 0.0
    total_tokens = 0
    total_mongo = 0
    n = len(traces)
    avg_latency = 0
    for t in traces:
        summ = t.get("summary") or {}
        c = summ.get("estimatedCostUsd")
        if c is not None:
            total_cost += float(c)
        total_tokens += _as_int(summ.get("totalTokens"))
        total_mongo += _as_int(summ.get("mongoQueries") or summ.get("mongoQueriesCount"))

        duration = _duration_ms(t)
        if not duration and t.get("traceId"):
            detail = _trace_detail(api_base, token, str(t["traceId"]))
            duration = _duration_ms(detail) if detail else 0
        avg_latency += duration
    if n:
        avg_latency //= n

    with st.expander(f"Live metrics — last {n} turn(s)", expanded=False):
        st.metric("Approx. Total cost (USD)", f"${total_cost:.4f}")
        st.metric("Approx. Total tokens", f"{total_tokens:,}")
        st.metric("Avg latency", f"{avg_latency / 1000:.2f}s")
        st.metric("Mongo ops", str(total_mongo))
        st.caption("Cached for 10 s — refresh page to recompute.")
