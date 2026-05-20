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
        if e.get("type") in ("memory.scoped_read", "memory.shared_read"):
            p = _payload(e)
            if int(p.get("entryCount") or 0) > 0:
                mode = str(p.get("mode") or "lexical")
                retrieval = p.get("retrieval") or {}
                latency = int(p.get("latencyMs") or 0)
                bytes_inj = int(p.get("bytesInjected") or 0)
                degraded = (
                    ' <span class="brand-status brand-status--warn" title="primaryFailed"></span>'
                    if p.get("primaryFailed")
                    else ""
                )
                detail_bits = []
                if retrieval.get("vectorHits") or retrieval.get("lexicalHits"):
                    detail_bits.append(
                        f"{int(retrieval.get('vectorHits') or 0)} vector + "
                        f"{int(retrieval.get('lexicalHits') or 0)} lexical hit(s)"
                    )
                if latency:
                    detail_bits.append(f"{latency} ms")
                detail = f" ({'; '.join(detail_bits)})" if detail_bits else ""
                out.append(
                    f"Recalled <strong>{p.get('entryCount')}</strong> prior context entry(s) via "
                    f"<code>{html.escape(mode)}</code> retrieval{detail}, injecting "
                    f"<strong>{bytes_inj:,}</strong> bytes into the system prompt.{degraded}"
                )
                break

    # 2b. Memory write outcome.
    writes = [e for e in events_list if e.get("type") == "memory.long_term_write"]
    skips = [e for e in events_list if e.get("type") == "memory.long_term_skip"]
    if writes:
        stored = sum(int(_payload(w).get("docsInserted") or 0) for w in writes)
        dupes = sum(int(_payload(w).get("duplicatesSkipped") or 0) for w in writes)
        outcomes = sorted({str(_payload(w).get("primaryOutcome") or "") for w in writes if _payload(w).get("primaryOutcome")})
        outcome_label = ", ".join(outcomes) or "n/a"
        extra = f" ({dupes} duplicate(s) skipped)" if dupes else ""
        out.append(
            f"Persisted <strong>{stored}</strong> new fact(s) to long-term memory "
            f"(<code>{html.escape(outcome_label)}</code>){extra}."
        )
    elif skips:
        reason = str(_payload(skips[-1]).get("reason") or "skipped")
        out.append(
            f"Skipped the long-term memory write — reason "
            f"<code>{html.escape(reason)}</code>."
        )

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
            f'<span class="brand-status brand-status--warn" title="errors"></span>'
            f" <strong>{len(errs)}</strong> error(s) recorded — see the trace events for details."
        )

    # 8. MongoDB scoping audit (security): unscoped queries on user-keyed
    # collections are a tenant-leak risk and should never be silent in a demo.
    unscoped = [
        e
        for e in events_list
        if e.get("type") == "mongo.query"
        and str(_payload(e).get("scoping") or "") == "missing_user_filter"
    ]
    if unscoped:
        out.append(
            f'<span class="brand-status brand-status--warn" title="missing user scoping"></span>'
            f" Detected <strong>{len(unscoped)}</strong> MongoDB query(ies) without user scoping — "
            f"see <strong>Developer details → MongoDB internals</strong>."
        )

    # 9. Retries — interleaved model + agentcore so the demo viewer sees one
    # "we retried N times" line instead of two separate ones.
    model_retries = [e for e in events_list if e.get("type") == "model.retry"]
    ac_retries = [e for e in events_list if e.get("type") == "agentcore.retry"]
    total_retries = len(model_retries) + len(ac_retries)
    if total_retries:
        first = model_retries[0] if model_retries else ac_retries[0]
        fp = _payload(first)
        prev_class = str(fp.get("previousErrorClass") or "")
        backoff = int(fp.get("backoffMs") or 0)
        suffix_bits: list[str] = []
        if model_retries and ac_retries:
            suffix_bits.append(
                f"{len(model_retries)} model + {len(ac_retries)} agentcore"
            )
        elif model_retries and not ac_retries:
            suffix_bits.append("Bedrock model")
        elif ac_retries and not model_retries:
            suffix_bits.append("AgentCore Runtime")
        suffix = f" ({', '.join(suffix_bits)})" if suffix_bits else ""
        head = (
            f"Retried <strong>{total_retries}</strong> time(s) before success"
        )
        if prev_class or backoff:
            cause_bits: list[str] = []
            if prev_class:
                cause_bits.append(f"<code>{html.escape(prev_class)}</code>")
            if backoff:
                cause_bits.append(f"{backoff} ms backoff")
            head += " — " + " · ".join(cause_bits)
        out.append(f"{head}{suffix}. See <strong>Developer details</strong>.")

    # 10. Byte-cap drops — surfaces when the trace was so large that
    # individual payload fields hit `TRUNCATION_CAP_DEBUG` or `MAX_TURN_BYTES`.
    cap_hits = [e for e in events_list if e.get("type") == "dev.byte_cap_hit"]
    if cap_hits:
        total_dropped_bytes = sum(int(_payload(e).get("bytes") or 0) for e in cap_hits)
        out.append(
            f"Some debug payloads were trimmed to fit the trace cap — "
            f"<strong>{len(cap_hits)}</strong> event(s) capped, "
            f"<strong>{total_dropped_bytes:,}</strong> total bytes dropped. "
            f"See <strong>Developer details</strong>."
        )

    return out
