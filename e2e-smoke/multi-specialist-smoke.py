#!/usr/bin/env python3
"""Multi-specialist orchestration end-to-end harness.

Companion to ``post-deploy-smoke.py``. Validates the multi-specialist
orchestration changes against the live deployed stack.

Scenarios:
    S1  single-domain fast path
    S2  cross-domain synthesis + MCP/HTTP concurrency + embedded trace
        projection (core vs dev) check
    S3  ambiguous prompt → Haiku fallback
    S4  explicit specialist (no orchestrator hop, no classifier)
    S6  persistence + size cap (re-fetches S1 and S2 sessions)
    S7  streaming phase ordering (specialist tokens before synthesis tokens)
    S8  parallel turns — trace + LTM isolation
    S9  USE_ORCHESTRATOR_RUNTIME=1 parity (only when ``--include-s9``)

The harness loads ``deploy-manifest.json`` for API URL + Cognito client id,
authenticates as ``$E2E_USER`` / ``$E2E_PASS`` (defaults
``alex@example.com`` / ``DemoUser#2026``), and emits a per-scenario summary
with trace ids and latencies on stdout. Exit code is 0 only when every
selected scenario passes its hard assertions; any failure dumps the
relevant trace JSON to ``/tmp/multispec_smoke_<scenarioId>.json``.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "deploy-manifest.json"


class SmokeFailure(Exception):
    pass


def log(msg: str) -> None:
    print(msg, flush=True)


def run_cmd(cmd: list[str], *, timeout: int = 120) -> str:
    try:
        return subprocess.check_output(
            cmd, text=True, stderr=subprocess.STDOUT, timeout=timeout
        ).strip()
    except subprocess.CalledProcessError as exc:
        raise SmokeFailure(
            f"command failed ({exc.returncode}): {' '.join(cmd)}\n{exc.output}"
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise SmokeFailure(f"command timed out: {' '.join(cmd)}") from exc


def cognito_token(client_id: str) -> str:
    user = os.environ.get("E2E_USER", "alex@example.com")
    password = os.environ.get("E2E_PASS", "DemoUser#2026")
    token = run_cmd(
        [
            "aws",
            "cognito-idp",
            "initiate-auth",
            "--client-id",
            client_id,
            "--auth-flow",
            "USER_PASSWORD_AUTH",
            "--auth-parameters",
            f"USERNAME={user},PASSWORD={password}",
            "--query",
            "AuthenticationResult.IdToken",
            "--output",
            "text",
        ],
        timeout=60,
    )
    if len(token) <= 100:
        raise SmokeFailure("Cognito IdToken was not returned")
    return token


# ─────────────────────────────────────────────────────────────────────────────
# SSE helpers
# ─────────────────────────────────────────────────────────────────────────────


_USEFUL_SSE_EVENT_RE = re.compile(
    r"^event:\s*(?:handoff|agent_info|stream_error|done|message|token|trace|agent_active|error)\s*$",
    re.MULTILINE,
)


class ChatTurn:
    """Result of a single SSE chat turn.

    Stores raw events in order so phase-ordering and per-event-type assertions
    can run downstream. ``concat_tokens()`` returns the visible body the
    Streamlit UI would render.
    """

    def __init__(
        self,
        *,
        body: str,
        x_trace_id: str | None,
        elapsed_ms: int,
        ttfb_ms: int | None,
    ) -> None:
        self.body = body
        # `x_trace_id` here is the OTEL trace id from the X-Trace-Id response
        # header, NOT the collector trace id. The collector trace id (the one
        # `/traces/:id` is keyed by) lives in the `done` SSE frame payload —
        # we extract it in `_parse()` below into `self.collector_trace_id`.
        self.otel_trace_id = x_trace_id
        self.collector_trace_id: str | None = None
        self.done_payload: dict[str, Any] | None = None
        self.elapsed_ms = elapsed_ms
        self.ttfb_ms = ttfb_ms
        self.events: list[tuple[str, dict[str, Any]]] = []
        self.tokens: list[dict[str, Any]] = []
        self.traces: list[dict[str, Any]] = []
        self.handoffs: list[dict[str, Any]] = []
        self.errors: list[dict[str, Any]] = []
        self._parse()

    @property
    def x_trace_id(self) -> str | None:
        """The id callers should use to query `/traces/:id` (collector trace
        id from the `done` payload, falling back to OTEL trace id only when
        the `done` frame was missing — which itself is a failure)."""
        return self.collector_trace_id or self.otel_trace_id

    def _parse(self) -> None:
        for block in self.body.split("\n\n"):
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
            raw = "\n".join(data_lines)
            try:
                payload = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                payload = {"raw": raw}
            self.events.append((event, payload))
            if event == "token":
                self.tokens.append(payload)
            elif event == "trace":
                self.traces.append(payload)
            elif event == "handoff":
                self.handoffs.append(payload)
            elif event == "error":
                self.errors.append(payload)
            elif event == "done":
                self.done_payload = payload
                # collector trace id lives here per chat.ts:778-786
                tid = payload.get("traceId")
                if isinstance(tid, str) and tid:
                    self.collector_trace_id = tid

    def concat_tokens(self) -> str:
        return "".join(str(t.get("text", "")) for t in self.tokens)

    def trace_types(self) -> list[str]:
        return [str(t.get("type", "?")) for t in self.traces]

    def trace_events_by_type(self, t: str) -> list[dict[str, Any]]:
        return [tr for tr in self.traces if tr.get("type") == t]


def post_chat(
    api_url: str,
    token: str,
    message: str,
    *,
    session_id: str,
    agent_id: str | None = None,
    timeout: int = 240,
) -> ChatTurn:
    payload: dict[str, Any] = {"message": message, "sessionId": session_id}
    if agent_id:
        payload["agentId"] = agent_id
    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    request = urllib.request.Request(
        f"{api_url}/chat", data=data, headers=headers, method="POST"
    )
    start = time.time()
    first_byte: float | None = None
    chunks: list[bytes] = []
    x_trace: str | None = None
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            x_trace = response.headers.get("X-Trace-Id") or response.headers.get(
                "x-trace-id"
            )
            try:
                while True:
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    if first_byte is None:
                        first_byte = time.time()
                    chunks.append(chunk)
            except (http.client.IncompleteRead, TimeoutError, urllib.error.URLError) as exc:
                partial = getattr(exc, "partial", None)
                if isinstance(partial, (bytes, bytearray)) and partial:
                    chunks.append(bytes(partial))
                body_partial = b"".join(chunks).decode("utf-8", "replace")
                if not _USEFUL_SSE_EVENT_RE.search(body_partial):
                    raise SmokeFailure(
                        f"chat stream produced no useful events ({type(exc).__name__}: {exc})"
                    )
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read().decode("utf-8", "replace")
        except Exception:
            body = ""
        elapsed_ms = int((time.time() - start) * 1000)
        # HTTPError responses are not SSE — wrap as a synthetic stream_error event
        # so downstream assertions can still pattern-match.
        synthetic = f"event: error\ndata: {json.dumps({'http_status': exc.code, 'body': body})}\n\n"
        return ChatTurn(
            body=synthetic, x_trace_id=None, elapsed_ms=elapsed_ms, ttfb_ms=None
        )
    body = b"".join(chunks).decode("utf-8", "replace")
    elapsed_ms = int((time.time() - start) * 1000)
    ttfb_ms = (
        int((first_byte - start) * 1000) if first_byte is not None else None
    )
    return ChatTurn(
        body=body, x_trace_id=x_trace, elapsed_ms=elapsed_ms, ttfb_ms=ttfb_ms
    )


# ─────────────────────────────────────────────────────────────────────────────
# Generic HTTP helpers
# ─────────────────────────────────────────────────────────────────────────────


def http_get_json(
    url: str, *, token: str, timeout: int = 30
) -> tuple[int, dict[str, Any], dict[str, str]]:
    request = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
            return (
                response.status,
                json.loads(body) if body else {},
                {k.lower(): v for k, v in response.headers.items()},
            )
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        return (
            exc.code,
            json.loads(body) if body else {},
            {k.lower(): v for k, v in exc.headers.items()},
        )


def fetch_trace(
    api_url: str, token: str, trace_id: str, include: str
) -> tuple[dict[str, Any], dict[str, str]]:
    """Fetch a persisted trace. Tolerates a brief replication lag after
    `done` — the API awaits `persistTrace` inline (chat.ts:769) but the
    Mongo replicaSet read view can lag a few hundred ms behind the primary
    write."""
    last_status = 0
    last_body: dict[str, Any] = {}
    headers: dict[str, str] = {}
    for attempt in range(4):
        status, body, headers = http_get_json(
            f"{api_url}/traces/{trace_id}?include={include}", token=token
        )
        if status == 200:
            return body, headers
        last_status, last_body = status, body
        if status == 404:
            time.sleep(1.5 * (attempt + 1))
            continue
        break
    raise SmokeFailure(
        f"GET /traces/{trace_id}?include={include} returned {last_status}: {last_body}"
    )


def fetch_session(
    api_url: str, token: str, session_id: str
) -> tuple[int, dict[str, Any]]:
    status, body, _ = http_get_json(
        f"{api_url}/sessions/{urllib.parse.quote(session_id, safe='')}",
        token=token,
    )
    return status, body


# ─────────────────────────────────────────────────────────────────────────────
# Manifest + setup
# ─────────────────────────────────────────────────────────────────────────────


def load_manifest() -> dict[str, Any]:
    path = Path(os.environ.get("DEPLOY_MANIFEST_PATH", str(DEFAULT_MANIFEST)))
    return json.loads(path.read_text())


def make_session_id(scenario_id: str, run_ts: int, tag: str | None) -> str:
    base = f"smoke-multi-{scenario_id}-{run_ts}"
    return f"{base}-{tag}" if tag else base


# ─────────────────────────────────────────────────────────────────────────────
# Scenario assertions
# ─────────────────────────────────────────────────────────────────────────────


class ScenarioResult:
    def __init__(self, scenario_id: str) -> None:
        self.scenario_id = scenario_id
        self.passed = True
        self.notes: list[str] = []
        self.failures: list[str] = []
        self.trace_id: str | None = None
        self.session_id: str | None = None
        self.elapsed_ms: int | None = None
        self.ttfb_ms: int | None = None

    def assert_true(self, cond: bool, msg: str) -> None:
        if cond:
            self.notes.append(f"✓ {msg}")
        else:
            self.passed = False
            self.failures.append(f"✗ {msg}")

    def dump_on_fail(self, trace_doc: Any | None) -> None:
        if self.passed:
            return
        out_path = Path(f"/tmp/multispec_smoke_{self.scenario_id}.json")
        out_path.write_text(
            json.dumps(
                {
                    "scenario": self.scenario_id,
                    "trace_id": self.trace_id,
                    "session_id": self.session_id,
                    "failures": self.failures,
                    "trace": trace_doc,
                },
                indent=2,
                default=str,
            )
        )
        log(f"  dumped trace to {out_path}")

    def summary_line(self) -> str:
        status = "PASS" if self.passed else "FAIL"
        bits = [f"[{status}] {self.scenario_id}"]
        if self.trace_id:
            bits.append(f"trace={self.trace_id}")
        if self.elapsed_ms is not None:
            bits.append(f"elapsed={self.elapsed_ms}ms")
        if self.ttfb_ms is not None:
            bits.append(f"ttfb={self.ttfb_ms}ms")
        return " ".join(bits)


# ── S1 single-domain fast path (sweep across all 3 specialists) ─────────────


# Per-specialist single-intent probes. Each prompt is unambiguously
# single-domain and MUST route to exactly one specialist with no synthesis.
# The first entry (order-management) is the "primary" probe — its
# session_id / trace_id are exposed via the ScenarioResult so downstream
# scenarios (S6 persistence) can re-fetch it.
#
# `(expected_specialist, prompt, label)` — label is a short tag used in
# session ids and log output. The three baseline prompts cover one
# happy-path keyword per specialist; the two trailing probes lock in two
# anti-regression scenarios that previously misclassified:
#
#   - sku-compare: "what is the difference between sku-1 and sku-3 models"
#     used to bounce off the heuristic (no strong keywords) and not engage
#     Haiku fallback. Now Haiku correctly picks product-recommendation.
#   - two-orders: same-domain multi-entity ("orders ORD-1001 AND ORD-1003").
#     The synthesis path could have been triggered if the classifier mistook
#     two distinct order ids as two distinct intents — we lock in that it
#     does NOT fan out: one specialist handles both lookups inline.
S1_PROBES: tuple[tuple[str, str, str], ...] = (
    ("order-management",       "Where is my order ORD-1001?",
     "order-management"),
    ("product-recommendation", "Recommend a budget gaming laptop with a backlit keyboard for me.",
     "product-recommendation"),
    ("troubleshooting",        "My device will not power on. What should I check?",
     "troubleshooting"),
    ("product-recommendation", "what is the difference between sku-1 and sku-3 models",
     "sku-compare"),
    ("order-management",       "Tell me the status of my orders ORD-1001 and ORD-1003.",
     "two-orders"),
)


def _assert_single_intent_probe(
    r: ScenarioResult,
    expected: str,
    turn: ChatTurn,
    *,
    probe_label: str | None = None,
) -> None:
    """Apply the single-intent contract to one probe's ChatTurn. All
    assertions are pushed into the shared ScenarioResult so a single failed
    probe surfaces as an S1-level FAIL with a clear ✗ line.

    `probe_label` distinguishes probes that share an expected specialist
    (e.g. "product-recommendation" baseline vs "sku-compare" anti-regression
    probe — both expect product-recommendation, so the label is what
    identifies them in the summary)."""
    tag = f"{probe_label}→{expected}" if probe_label else expected
    invokes = turn.trace_events_by_type("agentcore.invoke")
    specialists_invoked = {
        ev.get("payload", {}).get("targetAgentId") for ev in invokes
    }
    multi_decision = turn.trace_events_by_type("orchestrator.multi_route_decision")
    synthesis_events = turn.trace_events_by_type("orchestrator.synthesis")
    drafts = turn.trace_events_by_type("orchestrator.specialist_draft")
    token_phases = {t.get("phase") for t in turn.tokens}

    r.assert_true(
        turn.collector_trace_id is not None,
        f"[{tag}] collector trace id in done frame",
    )
    r.assert_true(
        not turn.errors,
        f"[{tag}] no SSE error frames (errors={turn.errors!r})",
    )
    r.assert_true(
        any(ev == "done" for ev, _ in turn.events),
        f"[{tag}] stream emitted event: done",
    )
    # The orchestrator MUST pick exactly the expected specialist — and ONLY
    # the expected specialist. This is the anti-fanout guarantee: a clearly
    # single-domain prompt must not engage the synthesizer.
    r.assert_true(
        specialists_invoked == {expected},
        f"[{tag}] only {expected!r} invoked, no fanout (saw {specialists_invoked!r})",
    )
    r.assert_true(
        len(synthesis_events) == 0,
        f"[{tag}] no orchestrator.synthesis on fast path (saw {len(synthesis_events)})",
    )
    # Multi-route decision MUST be present (orchestrator IS the entry path)
    # and MUST report pathTaken='single' with exactly one selection.
    r.assert_true(
        len(multi_decision) == 1,
        f"[{tag}] exactly one multi_route_decision (saw {len(multi_decision)})",
    )
    if multi_decision:
        payload = multi_decision[0].get("payload", {})
        path_taken = payload.get("pathTaken")
        selected = payload.get("selected", []) or payload.get("selections", [])
        r.assert_true(
            path_taken == "single",
            f"[{tag}] pathTaken == 'single' (got {path_taken!r})",
        )
        r.assert_true(
            len(selected) == 1,
            f"[{tag}] exactly one specialist selected (got {len(selected)})",
        )
        if selected:
            picked = selected[0].get("agentId")
            r.assert_true(
                picked == expected,
                f"[{tag}] selected[0].agentId == {expected!r} (got {picked!r})",
            )
    # On single fast path, draft.status MUST be "final".
    r.assert_true(
        len(drafts) == 1
        and drafts[0].get("payload", {}).get("status") == "final",
        f"[{tag}] exactly one specialist_draft with status='final' "
        f"(saw {[d.get('payload', {}).get('status') for d in drafts]!r})",
    )
    # Token phase tagging only fires on the synthesis path; fast-path tokens
    # MUST have no phase metadata.
    r.assert_true(
        token_phases.issubset({None}),
        f"[{tag}] all tokens have no phase on fast path (saw {token_phases!r})",
    )


def scenario_s1(
    api_url: str, token: str, run_ts: int, tag: str | None
) -> ScenarioResult:
    """Single-domain fast-path sweep — verifies the orchestrator routes to
    EXACTLY ONE specialist (no fanout, no synthesis) for each of the three
    specialist domains. Anti-regression for the production fast path: a
    clearly single-intent prompt must never engage the synthesizer."""
    r = ScenarioResult("S1")
    log(f"\n-- S1 single-domain fast-path sweep ({len(S1_PROBES)} probes) --")
    primary_session: str | None = None
    primary_trace: str | None = None
    primary_elapsed: int | None = None
    primary_ttfb: int | None = None
    for idx, (expected, prompt, label) in enumerate(S1_PROBES):
        sid = make_session_id(f"S1-{label}", run_ts, tag)
        log(
            f"  -- probe {idx + 1}/{len(S1_PROBES)}: {label!r} → "
            f"expected={expected!r} sid={sid}"
        )
        log(f"     prompt: {prompt!r}")
        turn = post_chat(
            api_url, token, prompt, session_id=sid, agent_id="orchestrator"
        )
        log(
            f"     trace={turn.collector_trace_id} elapsed={turn.elapsed_ms}ms "
            f"ttfb={turn.ttfb_ms}ms"
        )
        _assert_single_intent_probe(r, expected, turn, probe_label=label)
        # Keep the first probe's identifiers as the S1 "primary" so S6
        # persistence reuses the existing session id (order-management).
        if idx == 0:
            primary_session = sid
            primary_trace = turn.collector_trace_id
            primary_elapsed = turn.elapsed_ms
            primary_ttfb = turn.ttfb_ms
    r.session_id = primary_session
    r.trace_id = primary_trace
    r.elapsed_ms = primary_elapsed
    r.ttfb_ms = primary_ttfb
    return r


# ── S2 cross-domain synthesis + projection ─────────────────────────────────


def scenario_s2(
    api_url: str,
    token: str,
    run_ts: int,
    tag: str | None,
    *,
    turn_out: dict[str, ChatTurn] | None = None,
) -> ScenarioResult:
    r = ScenarioResult("S2")
    sid = make_session_id("S2", run_ts, tag)
    r.session_id = sid
    log(f"\n-- S2 cross-domain synthesis + projection ({sid}) --")
    turn = post_chat(
        api_url,
        token,
        "Track my order ORD-1001 status AND recommend a waterproof outdoor headphone under $80 for me.",
        session_id=sid,
        agent_id="orchestrator",
        timeout=300,
    )
    if turn_out is not None:
        turn_out["s2"] = turn
    r.trace_id = turn.x_trace_id
    r.elapsed_ms = turn.elapsed_ms
    r.ttfb_ms = turn.ttfb_ms

    invokes = turn.trace_events_by_type("agentcore.invoke")
    specialists_invoked = {
        ev.get("payload", {}).get("targetAgentId") for ev in invokes
    }
    multi_decision = turn.trace_events_by_type("orchestrator.multi_route_decision")
    synthesis_events = turn.trace_events_by_type("orchestrator.synthesis")
    drafts = turn.trace_events_by_type("orchestrator.specialist_draft")
    mongo_q = turn.trace_events_by_type("mongo.query")
    mongo_vec = turn.trace_events_by_type("mongo.vector_search")
    tool_calls = turn.trace_events_by_type("tool.call")
    mcp_tool_calls = turn.trace_events_by_type("tool.mcp")
    token_phases = {t.get("phase") for t in turn.tokens}

    r.assert_true(turn.collector_trace_id is not None, "collector trace id in done frame")
    r.assert_true(not turn.errors, f"no SSE error frames (errors={turn.errors!r})")
    r.assert_true(
        any(ev == "done" for ev, _ in turn.events),
        "stream emitted event: done",
    )
    r.assert_true(
        "order-management" in specialists_invoked
        and "product-recommendation" in specialists_invoked,
        f"both specialists invoked (saw {specialists_invoked!r})",
    )
    r.assert_true(
        len(multi_decision) == 1,
        f"exactly one multi_route_decision (saw {len(multi_decision)})",
    )
    if multi_decision:
        path_taken = multi_decision[0].get("payload", {}).get("pathTaken")
        r.assert_true(
            path_taken == "synthesis",
            f"multi_route_decision.pathTaken == 'synthesis' (got {path_taken!r})",
        )
    success_drafts = [
        d for d in drafts if d.get("payload", {}).get("status") == "success"
    ]
    r.assert_true(
        len(success_drafts) >= 2,
        f">= 2 successful specialist_draft events (saw {len(success_drafts)})",
    )
    r.assert_true(
        len(synthesis_events) == 1,
        f"exactly one orchestrator.synthesis event (saw {len(synthesis_events)})",
    )
    r.assert_true(
        len(mongo_q) >= 1,
        f">= 1 mongo.query event (saw {len(mongo_q)})",
    )
    r.assert_true(
        len(mongo_vec) >= 1
        or any(
            tc.get("payload", {}).get("toolName", "").startswith("http_")
            or tc.get("payload", {}).get("name", "").startswith("http_")
            for tc in tool_calls + mcp_tool_calls
        ),
        f">= 1 mongo.vector_search or http tool call (vec={len(mongo_vec)} tool_calls={len(tool_calls)} mcp={len(mcp_tool_calls)})",
    )
    r.assert_true(
        "specialist" in token_phases,
        f"tokens with phase='specialist' present (phases={token_phases!r})",
    )
    r.assert_true(
        "synthesis" in token_phases,
        f"tokens with phase='synthesis' present (phases={token_phases!r})",
    )

    # ── Embedded projection check (was S5) ────────────────────────────────
    trace_doc: dict[str, Any] | None = None
    if turn.x_trace_id:
        try:
            core_doc, core_headers = fetch_trace(
                api_url, token, turn.x_trace_id, include="core"
            )
            dev_doc, dev_headers = fetch_trace(
                api_url, token, turn.x_trace_id, include="dev"
            )
            r.assert_true(
                core_headers.get("x-trace-include") == "core",
                f"core projection header set (got {core_headers.get('x-trace-include')!r})",
            )
            r.assert_true(
                dev_headers.get("x-trace-include") == "dev",
                f"dev projection header set (got {dev_headers.get('x-trace-include')!r})",
            )

            # Core projection replaces `answerPreview` with a sentinel object
            # `{ _omittedForCoreMode: true, bytesAvailable: N }` (per
            # trace-projection.ts:148-156). Dev projection keeps the raw
            # string. Probe both shapes explicitly.
            def _draft_preview_kind(doc: dict[str, Any]) -> str:
                """Return 'string' / 'sentinel' / 'absent' / 'mixed'."""
                kinds: set[str] = set()
                for ev in doc.get("events", []):
                    if ev.get("type") != "orchestrator.specialist_draft":
                        continue
                    v = ev.get("payload", {}).get("answerPreview")
                    if v is None:
                        kinds.add("absent")
                    elif isinstance(v, str):
                        kinds.add("string")
                    elif isinstance(v, dict) and v.get("_omittedForCoreMode"):
                        kinds.add("sentinel")
                    else:
                        kinds.add("other")
                if not kinds:
                    return "no_drafts"
                if len(kinds) == 1:
                    return kinds.pop()
                return f"mixed:{sorted(kinds)}"

            core_kind = _draft_preview_kind(core_doc)
            dev_kind = _draft_preview_kind(dev_doc)
            r.assert_true(
                core_kind == "sentinel",
                f"core projection replaces orchestrator.specialist_draft.answerPreview "
                f"with sentinel (got {core_kind!r})",
            )
            r.assert_true(
                dev_kind == "string",
                f"dev projection retains orchestrator.specialist_draft.answerPreview "
                f"as raw string (got {dev_kind!r})",
            )
            trace_doc = dev_doc
        except Exception as exc:
            r.passed = False
            r.failures.append(
                f"✗ trace projection fetch failed: {type(exc).__name__}: {exc}"
            )

    r.dump_on_fail(trace_doc)
    return r


# ── S3 ambiguous Haiku fallback ────────────────────────────────────────────


def scenario_s3(
    api_url: str, token: str, run_ts: int, tag: str | None
) -> ScenarioResult:
    r = ScenarioResult("S3")
    sid = make_session_id("S3", run_ts, tag)
    r.session_id = sid
    log(f"\n-- S3 ambiguous Haiku fallback ({sid}) --")
    turn = post_chat(
        api_url,
        token,
        "my thing is broken and I need help",
        session_id=sid,
        agent_id="orchestrator",
    )
    r.trace_id = turn.x_trace_id
    r.elapsed_ms = turn.elapsed_ms
    r.ttfb_ms = turn.ttfb_ms

    multi_decision = turn.trace_events_by_type("orchestrator.multi_route_decision")

    r.assert_true(turn.x_trace_id is not None, "X-Trace-Id present")
    r.assert_true(
        any(ev == "done" for ev, _ in turn.events),
        "stream emitted event: done",
    )
    r.assert_true(
        len(multi_decision) == 1,
        f"exactly one multi_route_decision (saw {len(multi_decision)})",
    )
    if multi_decision:
        payload = multi_decision[0].get("payload", {})
        selected = payload.get("selected", []) or payload.get("selections", [])
        r.assert_true(
            len(selected) == 1,
            f"exactly one specialist selected (got {len(selected)})",
        )
        if selected:
            sources = {s.get("source") for s in selected}
            # 'cache' is acceptable — the classifier caches earlier Haiku
            # outcomes, so a prior run pollutes today's run. The bad outcome
            # is `source == 'heuristic'`, which would mean the keyword-based
            # router matched on gibberish.
            r.assert_true(
                sources & {"haiku", "cache"} and "heuristic" not in sources,
                f"selected[0].source ∈ {{'haiku','cache'}} (saw sources={sources!r}) — "
                "heuristic must NOT match this gibberish",
            )
    return r


# ── S4 explicit specialist ─────────────────────────────────────────────────


def scenario_s4(
    api_url: str, token: str, run_ts: int, tag: str | None
) -> ScenarioResult:
    r = ScenarioResult("S4")
    sid = make_session_id("S4", run_ts, tag)
    r.session_id = sid
    log(f"\n-- S4 explicit specialist (troubleshooting) ({sid}) --")
    turn = post_chat(
        api_url,
        token,
        "My device will not turn on after I left it in the rain. What should I check?",
        session_id=sid,
        agent_id="troubleshooting",
    )
    r.trace_id = turn.x_trace_id
    r.elapsed_ms = turn.elapsed_ms
    r.ttfb_ms = turn.ttfb_ms

    multi_decision = turn.trace_events_by_type("orchestrator.multi_route_decision")
    invokes = turn.trace_events_by_type("agentcore.invoke")
    specialists_invoked = {
        ev.get("payload", {}).get("targetAgentId") for ev in invokes
    }

    r.assert_true(turn.collector_trace_id is not None, "collector trace id in done frame")
    r.assert_true(
        any(ev == "done" for ev, _ in turn.events),
        "stream emitted event: done",
    )
    r.assert_true(
        len(multi_decision) == 0,
        f"no multi_route_decision when agentId is explicit (saw {len(multi_decision)})",
    )
    r.assert_true(
        "troubleshooting" in specialists_invoked,
        f"explicit specialist 'troubleshooting' invoked (saw {specialists_invoked!r})",
    )
    return r


# ── S6 persistence + size cap ──────────────────────────────────────────────


def scenario_s6(
    api_url: str,
    token: str,
    s1_session: str,
    s2_session: str,
    s1_trace_id: str | None,
    s2_trace_id: str | None,
) -> ScenarioResult:
    r = ScenarioResult("S6")
    log("\n-- S6 persistence + size cap --")

    # Persistence: assistant text matches what the user would see.
    for label, sid in (("S1", s1_session), ("S2", s2_session)):
        status, sess = fetch_session(api_url, token, sid)
        r.assert_true(
            status == 200,
            f"GET /sessions/{label} returned 200 (got {status})",
        )
        messages = sess.get("messages") or sess.get("session", {}).get("messages") or []
        assistants = [m for m in messages if m.get("role") == "assistant"]
        r.assert_true(
            len(assistants) >= 1,
            f"{label} session has >= 1 assistant message (saw {len(assistants)})",
        )
        # For S2 (synthesis) the persisted assistant must NOT be a specialist
        # draft — verify by agentId attribution.
        if label == "S2" and assistants:
            agent_ids = {m.get("agentId") for m in assistants}
            r.assert_true(
                "orchestrator" in agent_ids,
                f"S2 persisted assistant.agentId == 'orchestrator' (saw {agent_ids!r})",
            )
        if label == "S1" and assistants:
            agent_ids = {m.get("agentId") for m in assistants}
            r.assert_true(
                "order-management" in agent_ids,
                f"S1 persisted assistant.agentId == 'order-management' (saw {agent_ids!r})",
            )

    # Size cap: both traces must have `summary.eventsDropped == 0`. Per-event
    # `dev.byte_cap_hit` is INFORMATIONAL — `shrinkPayload` truncates a single
    # event's payload to fit the per-event cap but does NOT drop the event;
    # production traces routinely carry a handful when a specialist returns a
    # large MCP/HTTP result blob. The real truncation signal is
    # `summary.eventsDropped` (event-level loss).
    for label, tid in (("S1", s1_trace_id), ("S2", s2_trace_id)):
        if not tid:
            r.assert_true(False, f"{label} had no trace id to verify size cap")
            continue
        try:
            doc, _ = fetch_trace(api_url, token, tid, include="dev")
        except Exception as exc:
            r.assert_true(False, f"{label} trace fetch failed: {exc}")
            continue
        summary = doc.get("summary", {}) or {}
        dropped = summary.get("eventsDropped", 0) or 0
        cap_hits = [
            ev for ev in doc.get("events", []) if ev.get("type") == "dev.byte_cap_hit"
        ]
        r.assert_true(
            dropped == 0,
            f"{label} trace summary.eventsDropped == 0 (saw {dropped})",
        )
        # Surface cap hits as a note (visible in the harness output) without
        # failing — they're useful diagnostic context but not a regression.
        if cap_hits:
            r.notes.append(
                f"  ℹ {label} trace has {len(cap_hits)} dev.byte_cap_hit event(s) "
                "(informational — payload shrunk, not dropped)"
            )
    return r


# ── S7 streaming phase ordering ────────────────────────────────────────────


def scenario_s7(s2_turn: ChatTurn | None) -> ScenarioResult:
    """Verify all phase='specialist' tokens precede all phase='synthesis'
    tokens in the S2 stream. Reuses S2's captured turn — re-running here
    can yield a different classifier outcome (collapsed to single
    specialist), which would mask a real phase-ordering regression."""
    r = ScenarioResult("S7")
    log("\n-- S7 streaming phase ordering --")
    if s2_turn is None:
        r.assert_true(False, "S2 turn not captured — cannot verify S7")
        return r

    # Walk events in arrival order. `ChatTurn.events` preserves order.
    last_specialist_idx = -1
    first_synthesis_idx = None
    saw_specialist = False
    saw_synthesis = False
    token_idx = 0
    for ev_name, payload in s2_turn.events:
        if ev_name != "token":
            continue
        phase = payload.get("phase")
        if phase == "specialist":
            saw_specialist = True
            last_specialist_idx = token_idx
        elif phase == "synthesis":
            saw_synthesis = True
            if first_synthesis_idx is None:
                first_synthesis_idx = token_idx
        token_idx += 1

    r.assert_true(
        saw_specialist,
        "S2 stream contained at least one phase='specialist' token",
    )
    r.assert_true(
        saw_synthesis,
        "S2 stream contained at least one phase='synthesis' token",
    )
    if saw_specialist and saw_synthesis:
        r.assert_true(
            first_synthesis_idx is not None
            and first_synthesis_idx > last_specialist_idx,
            f"all specialist tokens precede all synthesis tokens (last_spec={last_specialist_idx}, first_synth={first_synthesis_idx})",
        )
    return r


# ── S8 parallel turns — trace + LTM isolation ──────────────────────────────


def scenario_s8(
    api_url: str, token: str, run_ts: int, tag: str | None
) -> ScenarioResult:
    r = ScenarioResult("S8")
    log("\n-- S8 parallel turns (trace + LTM isolation) --")
    sid_a = make_session_id("S8a", run_ts, tag)
    sid_b = make_session_id("S8b", run_ts, tag)

    results: dict[str, ChatTurn] = {}
    errors: dict[str, BaseException] = {}

    def _fire(key: str, sid: str, message: str) -> None:
        try:
            results[key] = post_chat(
                api_url,
                token,
                message,
                session_id=sid,
                agent_id="orchestrator",
                timeout=300,
            )
        except Exception as exc:  # noqa: BLE001
            errors[key] = exc

    # Both turns use the S2-shaped prompt (which is empirically proven to
    # trigger the synthesis path) with distinct session ids and distinct
    # secondary asks. The point of S8 is to verify per-turn AsyncLocalStorage
    # scoping under concurrency — not to test routing diversity.
    t_a = threading.Thread(
        target=_fire,
        args=(
            "a",
            sid_a,
            "Track my order ORD-1001 status AND recommend a waterproof outdoor headphone under $80 for me.",
        ),
    )
    t_b = threading.Thread(
        target=_fire,
        args=(
            "b",
            sid_b,
            "Track my order ORD-1003 status AND recommend a budget gaming laptop with a backlit keyboard for me.",
        ),
    )
    t_a.start()
    t_b.start()
    t_a.join(timeout=400)
    t_b.join(timeout=400)

    r.assert_true(
        "a" in results and "b" in results,
        f"both parallel turns returned (errors={errors})",
    )
    if "a" in results and "b" in results:
        ta, tb = results["a"], results["b"]
        r.assert_true(
            ta.x_trace_id and tb.x_trace_id and ta.x_trace_id != tb.x_trace_id,
            f"trace ids distinct (a={ta.x_trace_id} b={tb.x_trace_id})",
        )
        # Per-turn synthesis events must be scoped to their own collector
        # (verifies AsyncLocalStorage isolation under concurrency). The
        # classifier may collapse one of the two turns to single-spec; we
        # assert that AT LEAST ONE turn hits synthesis (proving the path
        # works under concurrency) AND that the count is consistent with
        # the per-turn multi_route_decision.pathTaken.
        synth_counts: dict[str, int] = {}
        for label, turn_x in (("a", ta), ("b", tb)):
            synth = turn_x.trace_events_by_type("orchestrator.synthesis")
            decision = turn_x.trace_events_by_type(
                "orchestrator.multi_route_decision"
            )
            path = (
                decision[0].get("payload", {}).get("pathTaken")
                if decision
                else None
            )
            synth_counts[label] = len(synth)
            expected = 1 if path == "synthesis" else 0
            r.assert_true(
                len(synth) == expected,
                f"S8.{label} synthesis count consistent with pathTaken={path!r} "
                f"(expected {expected}, saw {len(synth)})",
            )
        r.assert_true(
            sum(synth_counts.values()) >= 1,
            f"at least one parallel turn hit synthesis path "
            f"(counts={synth_counts}) — proves AsyncLocalStorage scoping works",
        )
        # Persistence isolation: each session's text references only its own
        # domain keywords; A must not leak B's distinct laptop ask.
        time.sleep(2)
        _, sess_a = fetch_session(api_url, token, sid_a)
        _, sess_b = fetch_session(api_url, token, sid_b)
        msgs_a = " ".join(
            str(m.get("content", "")) for m in sess_a.get("messages", [])
        ).lower()
        msgs_b = " ".join(
            str(m.get("content", "")) for m in sess_b.get("messages", [])
        ).lower()
        r.assert_true(
            "ord-1001" in msgs_a,
            "session A persisted text references ORD-1001 (A's domain)",
        )
        r.assert_true(
            "ord-1003" in msgs_b or "gaming" in msgs_b or "laptop" in msgs_b,
            "session B persisted text references ORD-1003 / gaming / laptop (B's domain)",
        )
        r.assert_true(
            "ord-1003" not in msgs_a and "gaming laptop" not in msgs_a,
            "session A persisted text does NOT leak B's distinct 'ORD-1003' / 'gaming laptop' keywords",
        )
    return r


# ── S9 USE_ORCHESTRATOR_RUNTIME=1 parity ───────────────────────────────────


def _s9_parity_assertions(
    api_url: str,
    token: str,
    fast_turn: ChatTurn,
    multi_turn: ChatTurn,
    r: ScenarioResult,
) -> None:
    """S9 parity contract: assert on the **persisted trace doc**, not the
    live SSE event stream.

    Under USE_ORCHESTRATOR_RUNTIME=1 the in-API event-forwarding path emits
    nested events twice on the live SSE channel (collector.onEvent fires
    during the relay loop AND again when attachEventsNested re-fires the
    same events post-relay). The persisted trace doc, however, contains
    each event exactly once — that's the contract the Trace Viewer reads.

    Phase token tagging (phase='specialist'|'synthesis') is also an in-API
    feature — it requires the API to run runMultiSpecialistFlow itself.
    The two-hop path forwards plain text from the orchestrator runtime, so
    phase tokens are EXPECTED to be absent. We note this for the report
    but do not fail.
    """
    # Fast path — both turns must complete cleanly.
    r.assert_true(
        fast_turn.collector_trace_id is not None,
        "S9 fast turn: collector trace id present",
    )
    r.assert_true(
        not fast_turn.errors,
        f"S9 fast turn: no SSE error frames (errors={fast_turn.errors!r})",
    )
    r.assert_true(
        multi_turn.collector_trace_id is not None,
        "S9 multi turn: collector trace id present",
    )
    r.assert_true(
        not multi_turn.errors,
        f"S9 multi turn: no SSE error frames (errors={multi_turn.errors!r})",
    )

    # ── Multi-turn persisted trace contract ──
    if not multi_turn.collector_trace_id:
        return
    try:
        doc, _ = fetch_trace(api_url, token, multi_turn.collector_trace_id, include="dev")
    except Exception as exc:  # noqa: BLE001
        r.assert_true(False, f"S9 multi trace fetch failed: {exc}")
        return

    events = doc.get("events", [])

    def _events_of(t: str) -> list[dict[str, Any]]:
        return [e for e in events if e.get("type") == t]

    decisions = _events_of("orchestrator.multi_route_decision")
    drafts = _events_of("orchestrator.specialist_draft")
    synth = _events_of("orchestrator.synthesis")
    invokes = _events_of("agentcore.invoke")

    r.assert_true(
        len(decisions) == 1,
        f"S9 persisted trace has exactly one orchestrator.multi_route_decision (saw {len(decisions)})",
    )
    if decisions:
        path = decisions[0].get("payload", {}).get("pathTaken")
        r.assert_true(
            path == "synthesis",
            f"S9 multi_route_decision.pathTaken == 'synthesis' (got {path!r})",
        )
    success_drafts = [
        d for d in drafts if d.get("payload", {}).get("status") == "success"
    ]
    r.assert_true(
        len(success_drafts) >= 2,
        f"S9 persisted trace has >= 2 successful specialist_draft events (saw {len(success_drafts)})",
    )
    r.assert_true(
        len(synth) == 1,
        f"S9 persisted trace has exactly one orchestrator.synthesis (saw {len(synth)})",
    )
    targeted = {ev.get("payload", {}).get("targetAgentId") for ev in invokes}
    r.assert_true(
        "order-management" in targeted and "product-recommendation" in targeted,
        f"S9 nested agentcore.invoke spans cover both specialists (targeted={targeted!r})",
    )
    r.assert_true(
        "orchestrator" in targeted,
        f"S9 outer agentcore.invoke targets the orchestrator runtime (targeted={targeted!r})",
    )

    # Phase tokens are a documented in-API-only feature; the two-hop relay
    # path doesn't tag them. Surface as a note, not a failure.
    phases_seen = {t.get("phase") for t in multi_turn.tokens}
    if phases_seen == {None}:
        r.notes.append(
            "  ℹ S9 phase tokens absent (expected — two-hop relay path doesn't tag phase metadata; "
            "phase tagging is in-API-only)"
        )
    else:
        r.notes.append(
            f"  ℹ S9 phase tokens present: {sorted(p for p in phases_seen if p)!r} "
            "(orchestrator runtime is now propagating phase tags — parity extended)"
        )


def scenario_s9(
    api_url: str,
    token: str,
    instance_id: str,
    run_ts: int,
) -> ScenarioResult:
    r = ScenarioResult("S9")
    log("\n-- S9 USE_ORCHESTRATOR_RUNTIME=1 parity --")
    r.assert_true(bool(instance_id), "EC2 instance id available for SSM")
    if not instance_id:
        return r

    def _ssm(commands: list[str]) -> str:
        cmd = [
            "aws",
            "ssm",
            "send-command",
            "--instance-ids",
            instance_id,
            "--document-name",
            "AWS-RunShellScript",
            "--parameters",
            json.dumps({"commands": commands}),
            "--query",
            "Command.CommandId",
            "--output",
            "text",
        ]
        cid = run_cmd(cmd, timeout=60)
        # poll up to 60 s for completion
        deadline = time.time() + 90
        while time.time() < deadline:
            time.sleep(4)
            status = run_cmd(
                [
                    "aws",
                    "ssm",
                    "get-command-invocation",
                    "--instance-id",
                    instance_id,
                    "--command-id",
                    cid,
                    "--query",
                    "Status",
                    "--output",
                    "text",
                ],
                timeout=30,
            )
            if status in {"Success", "Failed", "TimedOut", "Cancelled"}:
                out = run_cmd(
                    [
                        "aws",
                        "ssm",
                        "get-command-invocation",
                        "--instance-id",
                        instance_id,
                        "--command-id",
                        cid,
                        "--query",
                        "StandardOutputContent",
                        "--output",
                        "text",
                    ],
                    timeout=30,
                )
                if status != "Success":
                    raise SmokeFailure(f"SSM command {cid} ended in {status}: {out}")
                return out
        raise SmokeFailure(f"SSM command {cid} timed out")

    try:
        log("  flipping USE_ORCHESTRATOR_RUNTIME=1 on EC2 via SSM...")
        _ssm(
            [
                "sudo sed -i '/^USE_ORCHESTRATOR_RUNTIME=/d' /opt/multiagent/.env.docker",
                "echo USE_ORCHESTRATOR_RUNTIME=1 | sudo tee -a /opt/multiagent/.env.docker",
                "sudo systemctl restart multiagent-api",
            ]
        )
        # wait for health
        for _ in range(20):
            try:
                with urllib.request.urlopen(
                    f"{api_url}/health", timeout=5
                ) as resp:
                    if resp.status == 200:
                        break
            except Exception:
                pass
            time.sleep(3)
        log("  running fast-path + synthesis-path probes under USE_ORCHESTRATOR_RUNTIME=1...")
        fast_sid = make_session_id("S9fast", run_ts, "uor1")
        multi_sid = make_session_id("S9multi", run_ts, "uor1")
        fast_turn = post_chat(
            api_url,
            token,
            "Where is my order ORD-1001?",
            session_id=fast_sid,
            agent_id="orchestrator",
        )
        multi_turn = post_chat(
            api_url,
            token,
            "Track my order ORD-1001 status AND recommend a waterproof outdoor headphone under $80 for me.",
            session_id=multi_sid,
            agent_id="orchestrator",
            timeout=300,
        )
        r.trace_id = multi_turn.collector_trace_id
        r.elapsed_ms = multi_turn.elapsed_ms
        r.ttfb_ms = multi_turn.ttfb_ms
        _s9_parity_assertions(api_url, token, fast_turn, multi_turn, r)
    finally:
        log("  restoring USE_ORCHESTRATOR_RUNTIME (deleting line)...")
        try:
            _ssm(
                [
                    "sudo sed -i '/^USE_ORCHESTRATOR_RUNTIME=/d' /opt/multiagent/.env.docker",
                    "sudo systemctl restart multiagent-api",
                ]
            )
            for _ in range(20):
                try:
                    with urllib.request.urlopen(
                        f"{api_url}/health", timeout=5
                    ) as resp:
                        if resp.status == 200:
                            break
                except Exception:
                    pass
                time.sleep(3)
        except Exception as exc:  # noqa: BLE001
            r.passed = False
            r.failures.append(f"✗ failed to restore USE_ORCHESTRATOR_RUNTIME: {exc}")
    return r


# ─────────────────────────────────────────────────────────────────────────────
# Main entry point
# ─────────────────────────────────────────────────────────────────────────────


ALL_SCENARIOS = ["S1", "S2", "S3", "S4", "S6", "S7", "S8", "S9"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--only",
        nargs="*",
        default=None,
        help="Subset of scenario ids to run (e.g. --only S1 S2). Default = all except S9.",
    )
    parser.add_argument(
        "--tag",
        default=None,
        help="Per-scenario sessionId suffix (used by S9 parity hop tagging).",
    )
    parser.add_argument(
        "--include-s9",
        action="store_true",
        help="Include the S9 USE_ORCHESTRATOR_RUNTIME=1 parity scenario (requires SSM perms).",
    )
    args = parser.parse_args()

    manifest = load_manifest()
    api_url = manifest["resources"]["ec2_api_url"].rstrip("/")
    client_id = manifest["resources"]["cognito_client_id"]
    instance_id = manifest["resources"].get("ec2_instance_id", "")

    token = cognito_token(client_id)
    log(f"api_url={api_url}")
    log(f"cognito_token_len={len(token)}")

    selected = args.only or [s for s in ALL_SCENARIOS if s != "S9"]
    if args.include_s9 and "S9" not in selected:
        selected.append("S9")

    run_ts = int(time.time() * 1000)
    results: list[ScenarioResult] = []
    s1_session: str | None = None
    s2_session: str | None = None
    s1_trace_id: str | None = None
    s2_trace_id: str | None = None
    s2_turn: ChatTurn | None = None

    # Sequence-dependent scenarios:
    #   - S6 needs S1+S2 session ids and trace ids.
    #   - S7 reuses S2's live ChatTurn (re-running risks a classifier flip).
    if "S1" in selected:
        r1 = scenario_s1(api_url, token, run_ts, args.tag)
        results.append(r1)
        s1_session = r1.session_id
        s1_trace_id = r1.trace_id
    if "S2" in selected:
        captured: dict[str, ChatTurn] = {}
        r2 = scenario_s2(api_url, token, run_ts, args.tag, turn_out=captured)
        results.append(r2)
        s2_session = r2.session_id
        s2_trace_id = r2.trace_id
        s2_turn = captured.get("s2")
    if "S3" in selected:
        results.append(scenario_s3(api_url, token, run_ts, args.tag))
    if "S4" in selected:
        results.append(scenario_s4(api_url, token, run_ts, args.tag))
    if "S6" in selected:
        if s1_session and s2_session:
            results.append(
                scenario_s6(
                    api_url, token, s1_session, s2_session, s1_trace_id, s2_trace_id
                )
            )
        else:
            log("  S6 skipped — S1 and S2 must be in --only to run S6.")
    if "S7" in selected:
        if s2_turn is None and "S2" not in selected:
            # Fall back to a fresh S2 turn so S7 still has data.
            log("\n-- S7 helper: running S2-shape turn for phase capture --")
            captured = {}
            scenario_s2(api_url, token, run_ts, args.tag, turn_out=captured)
            s2_turn = captured.get("s2")
        results.append(scenario_s7(s2_turn))
    if "S8" in selected:
        results.append(scenario_s8(api_url, token, run_ts, args.tag))
    if "S9" in selected:
        results.append(scenario_s9(api_url, token, instance_id, run_ts))

    # Report
    print()
    print("=" * 72)
    print("MULTI-SPECIALIST SCENARIO HARNESS — SUMMARY")
    print("=" * 72)
    all_passed = True
    for r in results:
        print(r.summary_line())
        for note in r.notes:
            print(f"    {note}")
        for fail in r.failures:
            print(f"    {fail}")
        if not r.passed:
            all_passed = False
    print("=" * 72)
    if all_passed:
        print("ALL_MULTI_SPECIALIST_SMOKE_CHECKS_PASSED")
        return 0
    print("MULTI_SPECIALIST_SMOKE_FAILED")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SmokeFailure as exc:
        log(f"FATAL: {exc}")
        sys.exit(2)
