"""Plain-English narrative lines for the Trace Viewer.

Take a list of trace events and emit short narrative sentences that explain
what happened. Used by the Trace Viewer as a "story-mode" intro above the
detailed sections.

Pure / side-effect-free — UI calls it once per trace render.
"""

from __future__ import annotations

import html
from collections.abc import Iterable
from typing import Any


def _payload(ev: dict) -> dict:
    p = ev.get("payload") or {}
    return p if isinstance(p, dict) else {}


def _completed_span_count(events: list[dict]) -> int:
    completed = [e for e in events if e.get("durationMs") is not None]
    return len(completed) or len(events)


def narrate(events: Iterable[dict]) -> list[str]:
    """Return a small list of HTML-safe narrative lines for the trace."""
    out: list[str] = []
    events_list = list(events)

    # 1. Auth context.
    auth = next((e for e in events_list if e.get("type") == "auth.context_build"), None)
    if auth:
        p = _payload(auth)
        if int(p.get("customersResolved") or 0) > 0 or int(p.get("ordersResolved") or 0) > 0:
            out.append(
                f"We recognised the user via the JWT claim (sub=<code>{html.escape(str(p.get('userId') or '?'))[:24]}…</code>) and "
                f"enriched their context with <strong>{p.get('customersResolved', 0)}</strong> customer + "
                f"<strong>{p.get('ordersResolved', 0)}</strong> order(s) from MongoDB."
            )

    # 2. Memory injection.
    for e in events_list:
        if e.get("type") == "memory.scoped_read":
            p = _payload(e)
            if int(p.get("entryCount") or 0) > 0:
                out.append(
                    f"Recalled <strong>{p.get('entryCount')}</strong> prior fact(s) from long-term memory "
                    f"({p.get('bytesInjected', 0)} bytes injected into the system prompt)."
                )
                break

    # 3. Routing decision.
    routing = next((e for e in events_list if e.get("type") == "handoff.decision"), None)
    if routing:
        p = _payload(routing)
        triggers = p.get("triggerSpans") or []
        trigger_text = ""
        if triggers:
            tspan = triggers[0] if isinstance(triggers[0], dict) else {"text": str(triggers[0])}
            trigger_text = f" because of the phrase “{html.escape(str(tspan.get('text') or ''))}”"
        out.append(
            f"The orchestrator routed to <code>{html.escape(str(p.get('toAgentId') or '?'))}</code>"
            f"{trigger_text}."
        )

    # 4. MongoDB ops.
    mongo_results = [e for e in events_list if e.get("type") == "mongo.result"]
    if mongo_results:
        ok = sum(1 for e in mongo_results if _payload(e).get("status") == "ok")
        empty = sum(1 for e in mongo_results if _payload(e).get("status") == "empty")
        total = len(mongo_results)
        if empty and not ok:
            out.append(
                f"All <strong>{total}</strong> MongoDB lookup(s) returned 0 documents — see the diagnostic panel for why."
            )
        elif total:
            out.append(
                f"Ran <strong>{total}</strong> MongoDB op(s) — {ok} ok, {empty} empty."
            )

    # 5. AgentCore.
    invokes = [e for e in events_list if e.get("type") == "agentcore.invoke"]
    if invokes:
        hop_count = _completed_span_count(invokes)
        nested = [e for e in events_list if e.get("type") == "agentcore.nested_trace"]
        if nested:
            nested_count = sum(int(_payload(e).get("eventCount") or 0) for e in nested)
            out.append(
                f"Crossed the AgentCore Runtime boundary <strong>{hop_count}</strong> time(s) — "
                f"<strong>{nested_count}</strong> nested event(s) were spliced under the wrapper span(s)."
            )
        else:
            out.append(
                f"Crossed the AgentCore Runtime boundary <strong>{hop_count}</strong> time(s)."
            )

    # 6. Cost.
    usage = [e for e in events_list if e.get("type") == "model.usage"]
    if usage:
        tot = sum(int(_payload(e).get("totalTokens") or 0) for e in usage)
        out.append(f"Total model tokens consumed: <strong>{tot:,}</strong>.")

    # 7. Errors.
    errs = [e for e in events_list if e.get("type") == "error"]
    if errs:
        out.append(
            f"⚠️ <strong>{len(errs)}</strong> error(s) recorded — see the trace events for details."
        )

    return out
