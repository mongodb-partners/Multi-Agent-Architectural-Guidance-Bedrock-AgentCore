#!/usr/bin/env python3
"""Deterministic backend smoke test used by deploy scripts.

This validates the live /chat path rather than just transport health:
- SSE emits token/handoff/done without error events.
- AgentCore runtime telemetry is present.
- MongoDB MCP tool counters are non-zero.
- The response includes seeded ORD-2002 order fields.
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
    # The seeded dataset for ORD-2002 always contains at least one of these.
    return any(needle in body for needle in ("TRK-2002-US", "Pro Gadget", "89.99"))


def validate_chat_smoke(api: str, session_id: str, id_token: str) -> None:
    last_err = "SSE smoke validation failed: unknown"
    for attempt in range(1, 4):
        first = post_chat(api, session_id, id_token, "I need help tracking an order.")
        second = post_chat(
            api,
            session_id,
            id_token,
            "Order ORD-2002 for casey@example.com. What is the tracking number and status?",
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
            elif (summary.get("mongoQueries") or 0) <= 0:
                last_err = (
                    "SSE smoke validation failed: mongoQueries == 0 - "
                    "counter rollup or Mongo path broken"
                )
            elif (summary.get("mcpCalls") or 0) <= 0:
                last_err = (
                    "SSE smoke validation failed: mcpCalls == 0 - "
                    "gateway MCP path or counter rollup broken"
                )
            elif not has_order_data(second):
                last_err = (
                    "SSE smoke validation failed: response for ORD-2002 lacks any seeded "
                    "order field (TRK-2002-US / Pro Gadget / 89.99). The MCP tool path is "
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--id-token", default="")
    parser.add_argument("--check-session-user", action="store_true")
    args = parser.parse_args()

    api = args.api_url.rstrip("/")
    validate_chat_smoke(api, args.session_id, args.id_token)
    if args.check_session_user:
        validate_session_user(api, args.session_id, args.id_token)
    print("smoke_ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
