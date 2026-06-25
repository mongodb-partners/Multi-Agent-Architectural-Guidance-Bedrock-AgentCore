#!/usr/bin/env python3
"""Deterministic backend smoke test used by deploy scripts.

This validates the live /chat path rather than just transport health:
- SSE emits token/handoff/done without error events.
- AgentCore runtime telemetry is present.
- MongoDB MCP tool counters are non-zero.
- The response includes seeded ORD-1005 order fields.

The smoke prompt MUST query an order that belongs to the authenticated
COGNITO_SMOKE_USER_EMAIL (defaults to alex@example.com). The order-management
specialist enforces a per-user authorization guardrail and will refuse to
look up another customer's order, returning a polite refusal without ever
calling `mongodb_query`. That refusal is correct app behaviour, not a bug,
so the fixture is pinned to alex's own ORD-1005 (Pro Gadget @ $89.99,
tracking TRK-9005-US). See seed-orders.ts for the full owner→order map.

Agent-aware skip (generic): each specialist check runs only when that
specialist is present in the live `/agents` roster. Any specialist that is not
deployed in this environment is SKIPPED (not failed) — so a partial agent
config (orchestrator-only, orchestrator+one-specialist, etc.) does not fail the
smoke for agents that simply do not exist. The order-management case keeps the
deep deterministic assertions (handoff, MCP/Mongo counters, seeded ORD-1005
fields); other specialists get a lighter route+respond check. When no
specialist at all is deployed, a single orchestrator liveness + auth check runs
instead. This mirrors the per-agent skip behaviour in
e2e-smoke/post-deploy-smoke.py.
"""

import argparse
import http.client
import json
import sys
import time
import urllib.error
import urllib.request


def post_chat(api: str, session_id: str, id_token: str, message: str) -> str:
    headers = {"Content-Type": "application/json"}
    if id_token:
        headers["Authorization"] = f"Bearer {id_token}"

    last_error: Exception | None = None
    for attempt in range(1, 4):
        req = urllib.request.Request(
            f"{api}/chat",
            data=json.dumps({"sessionId": session_id, "message": message}).encode(),
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=180) as response:
                return response.read().decode("utf-8", "replace")
        except (
            http.client.IncompleteRead,
            http.client.HTTPException,
            TimeoutError,
            urllib.error.URLError,
        ) as exc:
            last_error = exc
            # Right after EC2 service restart, the first SSE request can lose the
            # chunked terminator while the API/AgentCore runtime is still warming.
            if attempt == 3:
                break
            time.sleep(5 * attempt)

    raise SystemExit(
        f"SSE smoke validation failed: chat stream transport error after retries: {last_error}",
    )


def fetch_agent_ids(api: str, id_token: str) -> set[str] | None:
    """Return the set of agent ids the API currently exposes via GET /agents,
    or None if the roster could not be determined.

    Used to SKIP (not fail) domain-specific smoke checks when the relevant
    specialist is not deployed in this environment. On any error we return None
    so the caller falls back to the legacy (order-management) smoke path rather
    than masking a real outage.
    """
    headers = {}
    if id_token:
        headers["Authorization"] = f"Bearer {id_token}"
    req = urllib.request.Request(f"{api}/agents", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            doc = json.loads(response.read().decode("utf-8", "replace"))
    except (
        urllib.error.URLError,
        http.client.HTTPException,
        TimeoutError,
        json.JSONDecodeError,
        ValueError,
    ) as exc:
        print(f"smoke: could not fetch /agents roster ({exc}); skipping skip-logic")
        return None

    if isinstance(doc, list):
        items = doc
    elif isinstance(doc, dict):
        items = doc.get("agents", [])
    else:
        items = []
    return {a.get("id") for a in items if isinstance(a, dict) and a.get("id")}


def validate_specialist_route(
    api: str, session_id: str, id_token: str, agent: str, message: str
) -> None:
    """Lightweight per-specialist check: send one domain prompt and require the
    orchestrator to hand off and the specialist to respond (token + handoff +
    done, no error event). Used for specialists without deterministic seeded
    fixtures so the deploy-time smoke stays fast and non-flaky.
    """
    last_err = f"SSE smoke validation failed: {agent} unknown"
    for attempt in range(1, 4):
        body = post_chat(api, session_id, id_token, message)
        has_token, has_handoff, has_done = check_sse(body)
        if "event: error" in body:
            last_err = f"SSE smoke validation failed: {agent} error event present"
        elif not (has_token and has_handoff and has_done):
            last_err = (
                f"SSE smoke validation failed: {agent} missing token/handoff/done events"
            )
        else:
            return
        if attempt < 3:
            time.sleep(10 * attempt)
            continue
        raise SystemExit(last_err)


def validate_liveness_chat(api: str, session_id: str, id_token: str) -> None:
    """Lightweight chat liveness check used when NO specialist is deployed.

    Sends one generic message (handled by the always-present orchestrator) and
    requires token + done without an error event. Also creates the session so
    the optional --check-session-user auth check can still run.
    """
    last_err = "SSE liveness validation failed: unknown"
    for attempt in range(1, 4):
        body = post_chat(api, session_id, id_token, "Hello, what can you help me with?")
        has_token, _, has_done = check_sse(body)
        if "event: error" in body:
            last_err = "SSE liveness validation failed: error event present"
        elif not (has_token and has_done):
            last_err = "SSE liveness validation failed: missing token/done events"
        else:
            return
        if attempt < 3:
            time.sleep(10 * attempt)
            continue
        raise SystemExit(last_err)


def parse_turn_end(body: str) -> dict:
    """Return the chat.turn.end summary from an SSE body."""
    for raw in body.split("\n\n"):
        lines = raw.strip().splitlines()
        event_name = next((line[7:].strip() for line in lines if line.startswith("event: ")), "")
        if event_name != "trace":
            continue
        data_line = next((line[5:].lstrip() for line in lines if line.startswith("data:")), "")
        if not data_line:
            continue
        try:
            payload = json.loads(data_line)
        except json.JSONDecodeError:
            continue
        if payload.get("type") == "chat.turn.end":
            return payload.get("payload", {}).get("summary", {}) or {}
    return {}


def check_sse(body: str) -> tuple[bool, bool, bool]:
    return "event: token" in body, "event: handoff" in body, "event: done" in body


def has_order_data(body: str) -> bool:
    # The seeded dataset for ORD-1005 (alex's Pro Gadget order) always contains
    # at least one of these. We also keep ORD-2002's tracking number in the
    # needle set so a legacy / overridden COGNITO_SMOKE_USER_EMAIL=casey@...
    # run still satisfies the assertion.
    return any(
        needle in body
        for needle in ("TRK-9005-US", "TRK-2002-US", "Pro Gadget", "89.99")
    )


def validate_chat_smoke(api: str, session_id: str, id_token: str) -> None:
    last_err = "SSE smoke validation failed: unknown"
    for attempt in range(1, 4):
        first = post_chat(api, session_id, id_token, "I need help tracking an order.")
        # The order MUST belong to the authenticated COGNITO_SMOKE_USER_EMAIL
        # (default alex@example.com). The order-management specialist refuses
        # cross-account lookups by design — see backend-smoke.py module docstring.
        second = post_chat(
            api,
            session_id,
            id_token,
            "Order ORD-1005 for alex@example.com. What is the tracking number and status?",
        )

        first_has_token, _, first_has_done = check_sse(first)
        second_has_token, second_has_handoff, second_has_done = check_sse(second)
        if not (
            first_has_token
            and first_has_done
            and second_has_token
            and second_has_handoff
            and second_has_done
        ):
            last_err = "SSE smoke validation failed: missing token/handoff/done events"
        elif "event: error" in first or "event: error" in second:
            last_err = "SSE smoke validation failed: error event present"
        else:
            first_summary = parse_turn_end(first)
            summary = parse_turn_end(second)
            if not summary:
                last_err = "SSE smoke validation failed: chat.turn.end summary missing for second turn"
            elif (summary.get("agentcoreRuntimeMs") or 0) <= 0:
                last_err = (
                    "SSE smoke validation failed: agentcoreRuntimeMs <= 0 "
                    "(Hono never called the runtime)"
                )
            elif (summary.get("bytesOut") or 0) <= 0:
                last_err = (
                    "SSE smoke validation failed: bytesOut == 0 "
                    "(runtime returned an empty response)"
                )
            elif (summary.get("agentcoreHops") or 0) < 1:
                hops = summary.get("agentcoreHops") or 0
                last_err = (
                    f"SSE smoke validation failed: agentcoreHops={hops} < 1 for an "
                    "order question (expected Hono -> specialist, or legacy "
                    "Hono -> orchestrator -> specialist when USE_ORCHESTRATOR_RUNTIME=1)."
                )
            # The second turn is intentionally a follow-up. A healthy agent may
            # answer it from the order data fetched during the first turn rather
            # than querying MongoDB again, so require Mongo/MCP evidence across
            # the two-turn conversation instead of only on the second response.
            elif ((first_summary.get("mongoQueries") or 0) + (summary.get("mongoQueries") or 0)) <= 0:
                last_err = (
                    "SSE smoke validation failed: mongoQueries == 0 across both turns - "
                    "counter rollup or Mongo path broken"
                )
            elif ((first_summary.get("mcpCalls") or 0) + (summary.get("mcpCalls") or 0)) <= 0:
                last_err = (
                    "SSE smoke validation failed: mcpCalls == 0 across both turns - "
                    "gateway MCP path or counter rollup broken"
                )
            elif not has_order_data(second):
                last_err = (
                    "SSE smoke validation failed: response for ORD-1005 lacks any seeded "
                    "order field (TRK-9005-US / Pro Gadget / 89.99). The MCP tool path is "
                    "almost certainly broken - check AgentCore Runtime logs for "
                    "'no MCP tools loaded' and Lambda logs for 'Unrecognized event shape'."
                )
            else:
                return

        if attempt < 3:
            time.sleep(15 * attempt)
            continue
        raise SystemExit(last_err)


def validate_session_user(api: str, session_id: str, id_token: str) -> None:
    if not id_token:
        return
    req = urllib.request.Request(
        f"{api}/sessions/{session_id}",
        headers={"Authorization": f"Bearer {id_token}"},
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        session_doc = json.loads(response.read().decode("utf-8", "replace"))
    if not session_doc.get("userId"):
        raise SystemExit("Auth propagation failed: session.userId missing under Cognito auth")


# Per-specialist smoke cases. `deep` cases run the deterministic, fixture-backed
# assertions (only order-management today); every other present specialist gets
# a lightweight route+respond check. Each case is SKIPPED when its agent is not
# in the live /agents roster.
SPECIALIST_CASES: tuple[dict, ...] = (
    {"agent": "order-management", "deep": True, "message": None},
    {
        "agent": "product-recommendation",
        "deep": False,
        "message": "I need waterproof outdoor headphones or rugged audio gear under $80 for rain.",
    },
    {
        "agent": "troubleshooting",
        "deep": False,
        "message": "My device will not turn on after I left it in the rain. What should I check?",
    },
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--id-token", default="")
    parser.add_argument("--check-session-user", action="store_true")
    args = parser.parse_args()

    api = args.api_url.rstrip("/")
    present = fetch_agent_ids(api, args.id_token)

    # Session id used for the optional auth check — set to whatever case ran.
    created_session_id: str | None = None

    if present is None:
        # Could not determine the roster — preserve the legacy deterministic
        # order-management smoke rather than masking a real outage.
        validate_chat_smoke(api, args.session_id, args.id_token)
        created_session_id = args.session_id
    else:
        ran_any = False
        for case in SPECIALIST_CASES:
            agent = str(case["agent"])
            if agent not in present:
                print(
                    f"smoke: {agent} specialist not deployed "
                    f"(agents={sorted(present)}); skipping its check"
                )
                continue
            session_id = f"{args.session_id}-{agent}"
            if case["deep"]:
                validate_chat_smoke(api, session_id, args.id_token)
            else:
                validate_specialist_route(
                    api, session_id, args.id_token, agent, str(case["message"])
                )
            created_session_id = session_id
            ran_any = True

        if not ran_any:
            print(
                f"smoke: no specialist deployed (agents={sorted(present)}); "
                "running orchestrator liveness check instead"
            )
            validate_liveness_chat(api, args.session_id, args.id_token)
            created_session_id = args.session_id

    if args.check_session_user and created_session_id:
        validate_session_user(api, created_session_id, args.id_token)
    print("smoke_ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
