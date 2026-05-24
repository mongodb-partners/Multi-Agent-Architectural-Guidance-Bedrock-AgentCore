#!/usr/bin/env python3
"""Smoke: session API returns traceId; traces fetchable (session trace replay UI)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API_URL = os.environ.get("API_URL", "http://44.215.34.82:3000").rstrip("/")
CLIENT_ID = os.environ.get(
    "STREAMLIT_COGNITO_CLIENT_ID",
    os.environ.get("COGNITO_CLIENT_ID", "227flpb3hus8v9badj9f6rq5o3"),
)
UI_URL = os.environ.get("UI_URL", "http://44.215.34.82:8501").rstrip("/")


def log(msg: str) -> None:
    print(msg, flush=True)


def die(msg: str) -> None:
    log(f"FAIL: {msg}")
    sys.exit(1)


def cognito_token() -> str:
    user = os.environ.get("E2E_USER", "alex@example.com")
    password = os.environ.get("E2E_PASS", "DemoUser#2026")
    out = subprocess.run(
        [
            "aws",
            "cognito-idp",
            "initiate-auth",
            "--client-id",
            CLIENT_ID,
            "--auth-flow",
            "USER_PASSWORD_AUTH",
            "--auth-parameters",
            f"USERNAME={user},PASSWORD={password}",
            "--query",
            "AuthenticationResult.IdToken",
            "--output",
            "text",
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if out.returncode != 0:
        die(f"Cognito auth failed: {out.stderr.strip()}")
    token = (out.stdout or "").strip()
    if len(token) < 100:
        die("Cognito IdToken missing or too short")
    return token


def http_json(method: str, url: str, token: str, body: dict | None = None) -> tuple[int, dict | list]:
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw}
        return e.code, payload


def main() -> None:
    log("== Session trace replay smoke ==")
    log(f"API_URL={API_URL} UI_URL={UI_URL}")

    # UI health (deploy-ui Phase 5 equivalent)
    try:
        urllib.request.urlopen(f"{UI_URL}/_stcore/health", timeout=10)
        log("PASS ui health")
    except Exception as exc:
        die(f"UI health check failed: {exc}")

    token = cognito_token()
    log("PASS cognito token")

    status, sessions_payload = http_json("GET", f"{API_URL}/sessions", token)
    if status != 200:
        die(f"GET /sessions -> {status}: {sessions_payload}")
    sessions = sessions_payload.get("sessions", []) if isinstance(sessions_payload, dict) else []
    log(f"sessions listed: {len(sessions)}")
    if not sessions:
        die("No sessions — send a chat from the UI first")

    picked = None
    picked_trace = None
    for row in sorted(
        sessions,
        key=lambda r: str(r.get("updatedAt") or r.get("createdAt") or ""),
        reverse=True,
    ):
        sid = row.get("sessionId")
        if not isinstance(sid, str):
            continue
        st_code, detail = http_json("GET", f"{API_URL}/sessions/{sid}", token)
        if st_code != 200:
            continue
        msgs = detail.get("messages", [])
        for m in msgs:
            if m.get("role") == "assistant" and m.get("traceId"):
                picked = sid
                picked_trace = m["traceId"]
                break
        if picked:
            break

    if not picked or not picked_trace:
        die("No assistant message with traceId in any session")

    log(f"PASS session {picked} has assistant traceId={picked_trace}")

    st_code, trace_doc = http_json("GET", f"{API_URL}/traces/{picked_trace}", token)
    if st_code != 200 or not isinstance(trace_doc, dict):
        die(f"GET /traces/{picked_trace} -> {st_code}")
    events = trace_doc.get("events") or []
    if not events:
        die(f"Trace {picked_trace} has no events")
    log(f"PASS trace fetch ({len(events)} events)")

    log("== All session trace replay API checks passed ==")


if __name__ == "__main__":
    main()
