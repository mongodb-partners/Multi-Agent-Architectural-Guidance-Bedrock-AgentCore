"""Sidebar block showing live, aggregated metrics from /traces.

Cached for 10 seconds to avoid hammering the API during demos.
"""

from __future__ import annotations

import streamlit as st

from lib.api_client import list_recent_traces


@st.cache_data(ttl=10, show_spinner=False)
def _recent(api_base: str, token: str | None, limit: int) -> list[dict]:
    try:
        return list_recent_traces(api_base, limit=limit, access_token=token)
    except Exception:
        return []


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
        total_tokens += int(summ.get("totalTokens") or 0)
        total_mongo += int(summ.get("mongoQueriesCount") or 0)
        avg_latency += int(summ.get("durationMs") or 0)
    if n:
        avg_latency //= n

    with st.expander(f"Live metrics — last {n} turn(s)", expanded=False):
        st.metric("Total cost (USD)", f"${total_cost:.4f}")
        st.metric("Total tokens", f"{total_tokens:,}")
        st.metric("Avg latency", f"{avg_latency / 1000:.2f}s")
        st.metric("Mongo ops", str(total_mongo))
        st.caption("Cached for 10 s — refresh page to recompute.")
