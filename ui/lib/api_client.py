"""HTTP client for the Hono API (SSE chat, sessions, agents)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable, Generator, Literal

import requests

from lib import log as ui_log


TraceIncludeMode = Literal["core", "dev", "full"]


def _http_headers(access_token: str | None, request_id: str | None = None) -> dict[str, str]:
    h: dict[str, str] = {}
    if access_token:
        h["Authorization"] = f"Bearer {access_token}"
    h["X-Request-Id"] = request_id or ui_log.new_request_id()
    return h


class ChatStreamError(RuntimeError):
    """Raised when the API emits an SSE `error` event during POST /chat."""

    def __init__(self, code: str, message: str, request_id: str | None = None) -> None:
        self.code = code
        self.request_id = request_id
        super().__init__(message)


# ---------------------------------------------------------------------------
# Typed stream events
# ---------------------------------------------------------------------------

@dataclass
class TokenEvent:
    text: str


@dataclass
class AgentActiveEvent:
    agent_id: str
    agent_name: str


@dataclass
class HandoffEvent:
    from_agent: str
    to_agent: str


@dataclass
class ToolCallEvent:
    tool: str
    status: str  # "started" | "completed"


@dataclass
class SkillLoadedEvent:
    skill_name: str


@dataclass
class DoneEvent:
    session_id: str
    message_id: str | None = None
    error: dict | None = None
    trace_id: str | None = None


@dataclass
class TraceEvent:
    """A single trace event streamed over SSE during POST /chat.

    The full event shape is preserved as a dict so the UI can render any
    payload without losing fields the UI client doesn't know about yet.
    """

    type: str
    id: str
    ts: int
    payload: dict
    parent_id: str | None = None
    agent_id: str | None = None
    duration_ms: float | None = None


ChatStreamEvent = (
    TokenEvent
    | AgentActiveEvent
    | HandoffEvent
    | ToolCallEvent
    | SkillLoadedEvent
    | TraceEvent
    | DoneEvent
)


def stream_chat_events(
    api_base: str,
    message: str,
    session_id: str,
    *,
    agent_id: str | None = None,
    access_token: str | None = None,
    request_id: str | None = None,
    on_response_headers: Callable[[requests.Response], None] | None = None,
    timeout: float = 120.0,
) -> Generator[ChatStreamEvent, None, None]:
    """POST /chat and yield typed SSE events."""
    url = f"{api_base.rstrip('/')}/chat"
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        **_http_headers(access_token, request_id),
    }

    payload: dict[str, Any] = {
        "message": message,
        "sessionId": session_id,
    }
    if agent_id:
        payload["agentId"] = agent_id

    with requests.post(
        url,
        headers=headers,
        json=payload,
        stream=True,
        timeout=timeout,
    ) as resp:
        resp.raise_for_status()
        if on_response_headers:
            on_response_headers(resp)
        x_trace = resp.headers.get("X-Trace-Id")
        if x_trace:
            ui_log.info("api chat response headers", x_trace_id=x_trace, request_id=headers.get("X-Request-Id"))
        # SSE responses often omit charset, and requests may default to ISO-8859-1.
        # Force UTF-8 to avoid mojibake like â€™ / â€œ / â†’.
        resp.encoding = "utf-8"
        pending_event: str | None = None
        for line in resp.iter_lines(decode_unicode=True):
            if line is None:
                continue
            line = line.strip()
            if not line:
                pending_event = None
                continue
            if line.startswith("event:"):
                pending_event = line[6:].strip()
                continue
            if not line.startswith("data:"):
                continue
            raw = line[5:].strip()
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue
            ev = pending_event or "message"
            if ev == "error":
                code = str(data.get("code") or "UNKNOWN")
                msg = str(data.get("message") or "")
                rid = data.get("requestId")
                raise ChatStreamError(
                    code,
                    msg,
                    str(rid) if rid is not None else None,
                )
            if ev in ("token", "message") and "text" in data:
                yield TokenEvent(text=str(data["text"]))
            elif ev in ("agent_active", "agent_info"):
                yield AgentActiveEvent(
                    agent_id=str(data.get("agentId") or ""),
                    agent_name=str(data.get("agentName") or data.get("agentId") or "agent"),
                )
            elif ev == "handoff":
                yield HandoffEvent(
                    from_agent=str(data.get("from") or ""),
                    to_agent=str(data.get("to") or ""),
                )
            elif ev == "tool_call":
                yield ToolCallEvent(
                    tool=str(data.get("tool") or ""),
                    status=str(data.get("status") or "started"),
                )
            elif ev == "skill_loaded":
                yield SkillLoadedEvent(skill_name=str(data.get("skillName") or ""))
            elif ev == "trace":
                # SSE trace event — forward as TraceEvent for the UI to render.
                tev_type = str(data.get("type") or "")
                if not tev_type:
                    continue
                yield TraceEvent(
                    type=tev_type,
                    id=str(data.get("id") or ""),
                    ts=int(data.get("ts") or 0),
                    payload=data.get("payload") if isinstance(data.get("payload"), dict) else {},
                    parent_id=str(data["parentId"]) if data.get("parentId") else None,
                    agent_id=str(data["agentId"]) if data.get("agentId") else None,
                    duration_ms=float(data["durationMs"]) if data.get("durationMs") is not None else None,
                )
            elif ev == "done":
                yield DoneEvent(
                    session_id=str(data.get("sessionId") or session_id),
                    message_id=str(data.get("messageId")) if data.get("messageId") else None,
                    error=data.get("error") if isinstance(data.get("error"), dict) else None,
                    trace_id=str(data["traceId"]) if data.get("traceId") else None,
                )


def stream_chat(
    api_base: str,
    message: str,
    session_id: str,
    *,
    agent_id: str | None = None,
    access_token: str | None = None,
    request_id: str | None = None,
    on_response_headers: Callable[[requests.Response], None] | None = None,
    timeout: float = 120.0,
) -> Generator[str, None, None]:
    """POST /chat and yield assistant text chunks (backwards-compatible text-only view)."""
    for ev in stream_chat_events(
        api_base,
        message,
        session_id,
        agent_id=agent_id,
        access_token=access_token,
        request_id=request_id,
        on_response_headers=on_response_headers,
        timeout=timeout,
    ):
        if isinstance(ev, TokenEvent):
            yield ev.text
        elif isinstance(ev, AgentActiveEvent):
            yield f"\n\n*{ev.agent_name}*\n\n"
        elif isinstance(ev, HandoffEvent):
            yield f"\n\n*Handoff: {ev.from_agent} → {ev.to_agent}*\n\n"


def list_sessions(api_base: str, access_token: str | None = None, request_id: str | None = None) -> list[dict]:
    url = f"{api_base.rstrip('/')}/sessions"
    headers = _http_headers(access_token, request_id)
    r = requests.get(url, headers=headers, timeout=30.0)
    r.raise_for_status()
    return r.json().get("sessions", [])


def get_session(api_base: str, session_id: str, access_token: str | None = None, request_id: str | None = None) -> dict:
    url = f"{api_base.rstrip('/')}/sessions/{session_id}"
    headers = _http_headers(access_token, request_id)
    r = requests.get(url, headers=headers, timeout=30.0)
    r.raise_for_status()
    return r.json()


def delete_session(api_base: str, session_id: str, access_token: str | None = None, request_id: str | None = None) -> bool:
    """DELETE /sessions/:id. Returns False if the session was not found (404)."""
    url = f"{api_base.rstrip('/')}/sessions/{session_id}"
    headers = _http_headers(access_token, request_id)
    r = requests.delete(url, headers=headers, timeout=30.0)
    if r.status_code == 404:
        return False
    r.raise_for_status()
    return True


def list_agents(api_base: str, access_token: str | None = None, request_id: str | None = None) -> list[dict]:
    url = f"{api_base.rstrip('/')}/agents"
    headers = _http_headers(access_token, request_id)
    r = requests.get(url, headers=headers, timeout=30.0)
    r.raise_for_status()
    return r.json().get("agents", [])


def get_http_tools(api_base: str, access_token: str | None = None, request_id: str | None = None) -> dict[str, Any]:
    """GET /http-tools — configured global + per-skill HTTP (Lambda) tools metadata."""
    url = f"{api_base.rstrip('/')}/http-tools"
    headers = _http_headers(access_token, request_id)
    r = requests.get(url, headers=headers, timeout=30.0)
    r.raise_for_status()
    return r.json()


def get_health(api_base: str, access_token: str | None = None, request_id: str | None = None) -> dict[str, Any]:
    """GET /health — API health and dependency status."""
    url = f"{api_base.rstrip('/')}/health"
    headers = _http_headers(access_token, request_id)
    r = requests.get(url, headers=headers, timeout=10.0)
    # Return even on 503 (degraded) — the body has useful info
    try:
        return r.json()
    except Exception:
        return {"status": "unreachable", "error": r.text}


# ---------------------------------------------------------------------------
# Trace endpoints
# ---------------------------------------------------------------------------

def _trace_headers(access_token: str | None, request_id: str | None = None) -> dict[str, str]:
    return _http_headers(access_token, request_id)


def get_trace(
    api_base: str,
    *,
    trace_id: str | None = None,
    session_id: str | None = None,
    message_id: str | None = None,
    access_token: str | None = None,
    request_id: str | None = None,
    include: TraceIncludeMode | None = None,
    timeout: float = 10.0,
) -> dict | None:
    """GET /traces/:id or /trace?sessionId=…&messageId=…

    Returns None on 404 — the UI should fall back to its in-memory live
    buffer of SSE-streamed trace events. The live buffer covers the rare
    case where the API has already shipped the SSE `done` event but the
    background `persistTrace()` hasn't completed yet.

    `include` selects the server-side projection added in the debug-grade
    trace work:

    - ``"core"`` — slim demo payload (heavy fields stripped to
      `{ _omittedForCoreMode: true, bytesAvailable }` sentinels). Used by
      the Trace Viewer initial page load to keep client demos fast.
    - ``"dev"`` — every field present, no projection. Used by the on-demand
      "Show developer details" fetch.
    - ``"full"`` — identity projection. Used by smoke / verification scripts
      (e.g. ``verify-trace-ui-shape.py``) for back-compat with pre-PR2
      behaviour.

    When ``include`` is set, the helper also asserts the response
    ``X-Trace-Include`` header matches what was requested — that contract is
    set by the API in ``api/src/routes/trace.ts``. A mismatch is a sign the
    API is older than this client and would silently return a different
    projection than the caller asked for.
    """
    headers = _trace_headers(access_token, request_id)
    if trace_id:
        url = f"{api_base.rstrip('/')}/traces/{trace_id}"
    elif session_id and message_id:
        url = f"{api_base.rstrip('/')}/trace?sessionId={session_id}&messageId={message_id}"
    else:
        raise ValueError("Provide trace_id or both session_id+message_id")
    if include is not None:
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}include={include}"
    r = requests.get(url, headers=headers, timeout=timeout)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    if include is not None:
        echoed = r.headers.get("X-Trace-Include")
        if echoed and echoed != include:
            ui_log.warn(
                "api get_trace include mismatch",
                requested=include,
                served=echoed,
                trace_id=trace_id,
                request_id=headers.get("X-Request-Id"),
            )
    return r.json()


def trace_events_from_doc(trace_doc: dict | None) -> list[TraceEvent]:
    """Parse persisted ``GET /traces/:id`` events into ``TraceEvent`` objects."""
    if not trace_doc:
        return []
    raw_events = trace_doc.get("events")
    if not isinstance(raw_events, list):
        return []
    out: list[TraceEvent] = []
    for raw in raw_events:
        if not isinstance(raw, dict):
            continue
        ev_type = raw.get("type")
        if not ev_type:
            continue
        out.append(
            TraceEvent(
                type=str(ev_type),
                id=str(raw.get("id") or ""),
                ts=int(raw.get("ts") or 0),
                payload=raw.get("payload") if isinstance(raw.get("payload"), dict) else {},
                parent_id=str(raw["parentId"]) if raw.get("parentId") else None,
                agent_id=str(raw["agentId"]) if raw.get("agentId") else None,
                duration_ms=raw.get("durationMs"),
            )
        )
    return out


def get_trace_mongo(
    api_base: str,
    *,
    trace_id: str | None = None,
    session_id: str | None = None,
    message_id: str | None = None,
    access_token: str | None = None,
    request_id: str | None = None,
    timeout: float = 10.0,
) -> dict | None:
    """GET /trace/mongo — returns a trace projection with only mongo.* events.

    Returns None on 404.
    """
    headers = _trace_headers(access_token, request_id)
    params: list[str] = []
    if trace_id:
        params.append(f"traceId={trace_id}")
    elif session_id and message_id:
        params.append(f"sessionId={session_id}")
        params.append(f"messageId={message_id}")
    else:
        raise ValueError("Provide trace_id or both session_id+message_id")
    url = f"{api_base.rstrip('/')}/trace/mongo?" + "&".join(params)
    r = requests.get(url, headers=headers, timeout=timeout)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


def list_recent_traces(
    api_base: str,
    *,
    limit: int = 25,
    session_id: str | None = None,
    exclude_trace_id: str | None = None,
    access_token: str | None = None,
    request_id: str | None = None,
    timeout: float = 10.0,
) -> list[dict]:
    """GET /traces — recent traces visible to the caller.

    `session_id` adds the matching `?sessionId=` filter (used by the
    prev/next-turn nav in the Trace Viewer header). `exclude_trace_id`
    adds `?excludeTraceId=` so the current turn drops out of the result —
    handy for "other turns in this session".
    """
    params: list[str] = [f"limit={int(limit)}"]
    if session_id:
        params.append(f"sessionId={session_id}")
    if exclude_trace_id:
        params.append(f"excludeTraceId={exclude_trace_id}")
    url = f"{api_base.rstrip('/')}/traces?" + "&".join(params)
    r = requests.get(url, headers=_trace_headers(access_token, request_id), timeout=timeout)
    r.raise_for_status()
    return r.json().get("traces", [])


def get_demo_prompts(
    api_base: str,
    *,
    access_token: str | None = None,
    request_id: str | None = None,
    timeout: float = 5.0,
) -> list[dict]:
    """GET /demo-prompts — the sidebar's "Try a prompt" entries.

    Requires the same Bearer token as the rest of the API.
    Returns a list of `{ title, prompts: [{ label, text }] }` groups. Any
    network/parse failure → ``[]`` (the section just hides itself).
    """
    url = f"{api_base.rstrip('/')}/demo-prompts"
    try:
        r = requests.get(url, headers=_http_headers(access_token, request_id), timeout=timeout)
        r.raise_for_status()
    except (requests.RequestException, ValueError):
        return []
    groups = r.json().get("groups")
    return groups if isinstance(groups, list) else []
