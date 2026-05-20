#!/usr/bin/env python3
"""Tier-2 verification for the debug-grade LTM trace section.

Runs two live chat turns through the deployed API:

  1. Plant turn — should produce a `memory.long_term_write` (or `_skip`) event
     with the field shape consumed by `_render_memory_write`.
  2. Recall turn — fresh session, should produce a `memory.scoped_read` (or
     `_shared_read`) with the retrieval block consumed by `_render_memory_read`.

After each turn the script fetches the persisted trace via `GET /trace`
(by `sessionId` + `messageId`, or directly by `X-Trace-Id`) and asserts:

  * The expected LTM event types are present.
  * Required fields used by the new UI are populated on each payload.
  * `model.request.userMessage` is non-empty (used by the write-card's
    "user input source" fallback chain).

Exits non-zero on any missing field. Intended to run from the repo root
after `./deploy/deploy-api.sh` + `./deploy/deploy-ui.sh`.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "deploy-manifest.json"


def log(msg: str) -> None:
    print(msg, flush=True)


def die(msg: str) -> None:
    print(f"VERIFY_FAILED: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def load_manifest() -> dict:
    path = Path(os.environ.get("DEPLOY_MANIFEST_PATH", str(DEFAULT_MANIFEST)))
    if not path.exists():
        die(f"deploy manifest not found at {path}")
    doc = json.loads(path.read_text())
    res = doc.get("resources") or {}
    res.setdefault("aws_region", doc.get("aws_region") or os.environ.get("AWS_REGION") or "us-east-1")
    return res


def cognito_token(client_id: str) -> str:
    import subprocess
    user = os.environ.get("E2E_USER", "alex@example.com")
    password = os.environ.get("E2E_PASS", "DemoUser#2026")
    out = subprocess.check_output(
        [
            "aws", "cognito-idp", "initiate-auth",
            "--client-id", client_id,
            "--auth-flow", "USER_PASSWORD_AUTH",
            "--auth-parameters", f"USERNAME={user},PASSWORD={password}",
            "--query", "AuthenticationResult.IdToken",
            "--output", "text",
        ],
        text=True, timeout=60,
    ).strip()
    if len(out) < 100:
        die("Cognito IdToken not returned (check E2E_USER/E2E_PASS)")
    return out


def post_chat(api_url: str, token: str, agent: str, session: str, message: str) -> tuple[str, str | None]:
    body = json.dumps({"agentId": agent, "sessionId": session, "message": message}).encode()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    req = urllib.request.Request(f"{api_url}/chat", data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=240) as resp:
        x_trace = resp.headers.get("X-Trace-Id") or resp.headers.get("x-trace-id")
        return resp.read().decode("utf-8", "replace"), x_trace


def get_trace_by_session(
    api_url: str,
    token: str,
    session_id: str,
    *,
    attempts: int = 10,
    include: str | None = None,
) -> tuple[dict, str | None]:
    """Find the most recent trace for `session_id` via GET /traces (user-scoped).

    The X-Trace-Id response header is the OTel span trace_id, which is distinct
    from the internal trace document's `traceId` (a UUID minted by
    TraceCollector). So we list the user's recent traces and match by sessionId.

    When `include` is set, append `?include=core|dev|full` to the trace fetch
    and return the `X-Trace-Include` response header alongside the doc so the
    caller can assert the projection round-trips correctly.
    """
    headers = {"Authorization": f"Bearer {token}"}
    last_err: Exception | None = None
    for i in range(1, attempts + 1):
        try:
            req = urllib.request.Request(f"{api_url}/traces?limit=25", headers=headers)
            with urllib.request.urlopen(req, timeout=30) as resp:
                index = json.loads(resp.read().decode("utf-8")).get("traces") or []
            match = next((t for t in index if t.get("sessionId") == session_id), None)
            if match and match.get("traceId"):
                tid = match["traceId"]
                url = f"{api_url}/traces/{tid}"
                if include:
                    url += f"?include={include}"
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=30) as resp:
                    doc = json.loads(resp.read().decode("utf-8"))
                    if doc.get("events"):
                        x_inc = resp.headers.get("X-Trace-Include") or resp.headers.get(
                            "x-trace-include"
                        )
                        return doc, x_inc
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
            last_err = exc
        time.sleep(2 * i)
    die(f"failed to fetch trace for sessionId={session_id}: {last_err}")
    raise SystemExit(1)  # unreachable; satisfies type checker


def events_of(events: list[dict], *types: str) -> list[dict]:
    return [e for e in events if e.get("type") in types]


def assert_field(payload: dict, key: str, *, ctx: str, predicate=lambda v: v is not None) -> None:
    if key not in payload:
        die(f"{ctx}: missing required field `{key}` (payload keys={sorted(payload.keys())})")
    if not predicate(payload[key]):
        die(f"{ctx}: field `{key}` failed predicate (value={payload[key]!r})")


def verify_read_event(read: dict) -> None:
    p = read.get("payload") or {}
    ctx = f"{read.get('type')}"
    for f in ("scope", "entryCount", "bytesInjected", "collectionsQueried", "latencyMs", "backend"):
        assert_field(p, f, ctx=ctx)
    # New UI uses these — they're optional in trace-types but should be present
    # for any hybrid-mode read on the deployed stack.
    if p.get("mode") and p["mode"] != "lexical":
        retrieval = p.get("retrieval")
        if not isinstance(retrieval, dict):
            die(f"{ctx}: mode=`{p.get('mode')}` but `retrieval` block missing/non-dict")
        for f in ("topK", "fetchK", "vectorHits", "lexicalHits", "rrfMergedCount", "perCollection"):
            assert_field(retrieval, f, ctx=f"{ctx}.retrieval")
        if not isinstance(retrieval["perCollection"], list):
            die(f"{ctx}.retrieval.perCollection must be a list")
        for i, c in enumerate(retrieval["perCollection"]):
            if not isinstance(c, dict):
                die(f"{ctx}.retrieval.perCollection[{i}] must be a dict")
            for f in ("collection", "vectorReturned", "lexicalReturned"):
                if f not in c:
                    die(f"{ctx}.retrieval.perCollection[{i}] missing `{f}`")
    log(f"  OK read event: mode={p.get('mode')} entries={p.get('entryCount')} bytes={p.get('bytesInjected')} backend={p.get('backend')}")


def verify_write_or_skip(events: list[dict]) -> None:
    writes = events_of(events, "memory.long_term_write")
    skips = events_of(events, "memory.long_term_skip")
    if not (writes or skips):
        die("plant turn produced neither memory.long_term_write nor memory.long_term_skip")
    for w in writes:
        p = w.get("payload") or {}
        ctx = "memory.long_term_write"
        for f in (
            "userId", "agentId", "factCandidates", "factsExtracted",
            "collection", "op", "docsInserted", "primaryBackend", "primaryOutcome",
            "userMessageBytes", "userMessageBytesStored",
            "assistantReplyBytes", "assistantReplyBytesStored",
            "ttlExpiresAt", "latencyMs",
        ):
            assert_field(p, f, ctx=ctx)
        if not isinstance(p["factCandidates"], list):
            die(f"{ctx}.factCandidates must be a list")
        log(
            f"  OK write event: outcome={p.get('primaryOutcome')} "
            f"inserted={p.get('docsInserted')} dup={p.get('duplicatesSkipped')} "
            f"latencyMs={p.get('latencyMs')}"
        )
    for s in skips:
        p = s.get("payload") or {}
        ctx = "memory.long_term_skip"
        for f in ("reason", "agentId", "userMessageExcerpt"):
            assert_field(p, f, ctx=ctx)
        log(f"  OK skip event: reason={p.get('reason')}")


def verify_model_request_user_message(events: list[dict]) -> None:
    """`model.request` is a span — start emits payload with `userMessage`, end
    emits an empty payload. We only need at least one event with a populated
    `userMessage` for the UI write-card to source the user input.
    """
    requests = events_of(events, "model.request")
    if not requests:
        die("trace has no model.request events — write-card user-input fallback will read 'not in trace'")
    populated = [
        r for r in requests
        if isinstance((r.get("payload") or {}).get("userMessage"), str)
        and (r.get("payload") or {}).get("userMessage")
    ]
    if not populated:
        die("no model.request event carries a non-empty `userMessage` — UI's user-input source fallback will be empty")
    log(f"  OK model.request.userMessage populated on {len(populated)}/{len(requests)} request span event(s)")


def parse_sse(body: str) -> tuple[str, list[str]]:
    tokens: list[str] = []
    events: list[str] = []
    for block in body.split("\n\n"):
        lines = block.strip().splitlines()
        if not lines:
            continue
        event = ""
        data_lines: list[str] = []
        for line in lines:
            if line.startswith("event: "):
                event = line[7:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
        if not event:
            continue
        events.append(event)
        if event == "token":
            try:
                tokens.append(str(json.loads("\n".join(data_lines)).get("text", "")))
            except Exception:
                pass
    return "".join(tokens), events


def verify_debug_grade_shape(trace: dict) -> None:
    """Assert the debug-grade fields the Developer details panel relies on.

    Covers the additions from the debug-grade Trace Viewer plan:
      * `trace.otel` — CloudWatch ServiceLens / X-Ray deep-link source for
        the Identifiers sub-section. Optional on traces that ran without an
        OTel exporter (DEV_MOCK_BACKENDS=1) but mandatory on the live stack.
      * `trace.spanTree` — pre-computed span hierarchy rendered by
        `_dev_span_tree`. The UI falls back to parentId reconstruction but
        the live stack always ships it.
      * `dev.environment` event — single shot environment snapshot.
    """
    otel = trace.get("otel") or {}
    if not (isinstance(otel, dict) and isinstance(otel.get("traceId"), str) and isinstance(otel.get("rootSpanId"), str)):
        die(
            "trace.otel missing or malformed — Developer details panel "
            "cannot build ServiceLens / X-Ray deep links "
            f"(got {otel!r})"
        )
    if not re.match(r"^[0-9a-f]{32}$", otel["traceId"], re.I):
        die(f"trace.otel.traceId must be a 32-char hex — got {otel['traceId']!r}")
    if not re.match(r"^[0-9a-f]{16}$", otel["rootSpanId"], re.I):
        die(f"trace.otel.rootSpanId must be a 16-char hex — got {otel['rootSpanId']!r}")
    log(f"  OK trace.otel: traceId={otel['traceId']} rootSpanId={otel['rootSpanId']}")

    spans = trace.get("spanTree")
    if not (isinstance(spans, list) and spans):
        die(
            "trace.spanTree missing — Developer details Span tree sub-section "
            "will fall back to parentId reconstruction (slower + lossy)"
        )

    def _walk(node: dict, depth: int = 0) -> int:
        if depth > 32:
            die("trace.spanTree depth > 32 — likely a cycle in parentId rewiring")
        if not isinstance(node, dict) or not node.get("id"):
            die(f"trace.spanTree node missing id at depth {depth}: {node!r}")
        # API shape ships `{ id, type, ts, durationMs, children }`. The UI
        # accepts `type` or legacy `name`; live traces must always ship `type`.
        if not node.get("type"):
            die(f"trace.spanTree node missing type at depth {depth}: id={node.get('id')!r}")
        n = 1
        for child in node.get("children") or []:
            n += _walk(child, depth + 1)
        return n

    total_nodes = sum(_walk(root) for root in spans)
    log(f"  OK trace.spanTree: {len(spans)} root(s), {total_nodes} total node(s)")

    env_events = events_of(trace.get("events") or [], "dev.environment")
    if not env_events:
        die("dev.environment event missing — Developer details Environment sub-section will be empty")
    env_p = (env_events[0].get("payload") or {})
    # Field names must match `DevEnvironmentPayload` in api/src/lib/trace-types.ts
    # and what `emitEnvironment()` in trace-collector.ts writes. The UI's
    # `_dev_environment` renders the payload as JSON so it tolerates additions,
    # but the four core knobs below MUST be present or the dev panel's
    # "Environment" sub-section will leave the demo screen guessing why a turn
    # diverged from local repro.
    for f in ("chatMode", "devMockBackends", "mongoUri", "voyageConfigured"):
        if f not in env_p:
            die(f"dev.environment payload missing `{f}` (UI Environment sub-section degrades to caption)")
    log(f"  OK dev.environment: chatMode={env_p.get('chatMode')} devMockBackends={env_p.get('devMockBackends')} mongoUri={env_p.get('mongoUri')}")


def verify_vector_search_index_name(events: list[dict]) -> None:
    """Assert every `mongo.vector_search` event surfaces `indexName`.

    `_dev_mongo_internals` renders this as a chip so reviewers can confirm
    the runtime is hitting the expected Atlas index. A missing `indexName`
    means the wrapper transform didn't forward the operand — silent
    correctness bug if the index name is wrong.
    """
    vec = events_of(events, "mongo.vector_search")
    if not vec:
        log("  note: no mongo.vector_search events on this turn — skipping indexName check")
        return
    missing = [e for e in vec if not (e.get("payload") or {}).get("indexName")]
    if missing:
        die(
            f"{len(missing)}/{len(vec)} mongo.vector_search events missing `indexName` — "
            "Developer details cannot show which Atlas index the runtime hit"
        )
    names = sorted({(e.get("payload") or {}).get("indexName") for e in vec})
    log(f"  OK mongo.vector_search.indexName populated on all {len(vec)} events: {names}")


def verify_include_projection_round_trip(api_url: str, token: str, session_id: str) -> None:
    """Round-trip `?include=core|dev|full` and the X-Trace-Include header.

    The Streamlit Trace Viewer asserts X-Trace-Include matches the requested
    mode; verifying it server-side here prevents a routing regression from
    silently downgrading the projection.
    """
    log("\n== Verifying ?include= projection round-trip ==")
    for mode in ("core", "dev", "full"):
        doc, header = get_trace_by_session(api_url, token, session_id, include=mode)
        if header != mode:
            die(f"GET /traces/...?include={mode} returned X-Trace-Include={header!r}")
        events = doc.get("events") or []
        if mode == "core":
            # Dev-only event types must not appear in core projection.
            dev_only = [e for e in events if e.get("type") in {
                "dev.environment",
                "dev.byte_cap_hit",
                "model.retry",
                "agentcore.retry",
                "model.text_delta_batch",
                "latency.checkpoint",
            }]
            if dev_only:
                die(
                    f"?include=core leaked {len(dev_only)} dev-only event(s) "
                    f"(types={sorted({e.get('type') for e in dev_only})})"
                )
            # Dev-only top-level fields must be stripped.
            for f in ("release", "correlation", "otel", "spanTree"):
                if f in doc:
                    die(f"?include=core leaked dev-only top-level field `{f}`")
        if mode == "dev":
            # Dev mode must include the otel + spanTree we just verified exist.
            if not doc.get("otel") or not doc.get("spanTree"):
                die("?include=dev dropped otel/spanTree — Developer details deep links will be empty")
        log(f"  OK ?include={mode}: X-Trace-Include={header}, events={len(events)}")


def main() -> int:
    res = load_manifest()
    api_url = str(res.get("ec2_api_url") or "").rstrip("/")
    client_id = str(res.get("cognito_client_id") or "")
    if not api_url or not client_id:
        die("manifest missing ec2_api_url or cognito_client_id")

    log(f"API={api_url}")
    log("== Acquiring Cognito token ==")
    token = cognito_token(client_id)
    log(f"  token len={len(token)}")

    plant_session = f"verify-trace-ui-plant-{int(time.time() * 1000)}"
    recall_session = f"verify-trace-ui-recall-{int(time.time() * 1000)}"
    needle = "AZURE-CARTOGRAPH"

    log("\n== Plant turn (expect memory.long_term_write or _skip) ==")
    body, x_trace = post_chat(
        api_url, token, "orchestrator", plant_session,
        f"Please remember this preference for future support tickets: my "
        f"favorite mnemonic phrase is {needle}. Treat it as a stable user "
        "preference, not a one-off.",
    )
    if not (isinstance(x_trace, str) and re.match(r"^[0-9a-f]{32}$", x_trace, re.I)):
        die(f"plant turn missing X-Trace-Id (got {x_trace!r})")
    text, evs = parse_sse(body)
    if "done" not in evs:
        die(f"plant turn did not complete: events={evs}")
    log(f"  reply head: {text[:120]!r}")
    log(f"  X-Trace-Id={x_trace}")

    # fact extraction is dangling off the user's clock — give it time
    time.sleep(8)
    trace, _x_inc = get_trace_by_session(api_url, token, plant_session)
    log(f"  trace events={len(trace.get('events') or [])} (traceId={trace.get('traceId')})")
    verify_write_or_skip(trace.get("events") or [])
    verify_model_request_user_message(trace.get("events") or [])
    verify_debug_grade_shape(trace)
    verify_include_projection_round_trip(api_url, token, plant_session)

    log("\n== Recall turn (expect memory.scoped_read with retrieval block) ==")
    body, x_trace2 = post_chat(
        api_url, token, "orchestrator", recall_session,
        "We talked earlier about a memorable phrase you should keep on file "
        "as one of my preferences. Quote that exact phrase back to me.",
    )
    if not (isinstance(x_trace2, str) and re.match(r"^[0-9a-f]{32}$", x_trace2, re.I)):
        die(f"recall turn missing X-Trace-Id (got {x_trace2!r})")
    text2, evs2 = parse_sse(body)
    if "done" not in evs2:
        die(f"recall turn did not complete: events={evs2}")
    log(f"  reply head: {text2[:120]!r}")
    log(f"  X-Trace-Id={x_trace2}")

    time.sleep(2)
    trace2, _x_inc2 = get_trace_by_session(api_url, token, recall_session)
    log(f"  trace events={len(trace2.get('events') or [])} (traceId={trace2.get('traceId')})")
    reads = events_of(trace2.get("events") or [], "memory.scoped_read", "memory.shared_read")
    if not reads:
        die("recall turn produced no memory.scoped_read / memory.shared_read")
    for r in reads:
        verify_read_event(r)
    verify_model_request_user_message(trace2.get("events") or [])
    verify_debug_grade_shape(trace2)
    verify_vector_search_index_name(trace2.get("events") or [])

    flat = re.sub(r"\s+", " ", text2).strip().upper()
    if needle in flat:
        log(f"  bonus: recall reply surfaced needle {needle}")
    else:
        log(f"  note: recall reply did not literally contain {needle} (UI test does not require this)")

    log("\nALL_TRACE_UI_SHAPE_CHECKS_PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
