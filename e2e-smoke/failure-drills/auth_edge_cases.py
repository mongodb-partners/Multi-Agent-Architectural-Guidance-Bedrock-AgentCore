#!/usr/bin/env python3
"""Live auth edge-case drill.

Verifies protected endpoints reject missing/malformed/fake tokens, valid
Cognito tokens work, and session ownership is scoped by JWT subject.
"""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

from common import DrillFailure, chat_order_status, cognito_token, http_request, load_manifest, log, require


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=None)
    args = parser.parse_args()

    resources = load_manifest(args.manifest)
    alex = cognito_token(resources, "alex@example.com")
    blake = cognito_token(resources, "blake@example.com")

    checks: list[tuple[str, bool, int, str | int, str]] = []
    cases = [
        ("missing bearer rejects /agents", "/agents", None, 401),
        ("malformed bearer rejects /agents", "/agents", "not-a-jwt", 401),
        (
            "random jwt-shaped token rejects /agents",
            "/agents",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJldmlsIn0.sig",
            401,
        ),
        ("empty token rejects /sessions", "/sessions", "", 401),
        ("valid token allows /agents", "/agents", alex, 200),
    ]
    for label, path, token, expected in cases:
        status, text = http_request(resources, path, token=token)
        checks.append((label, status == expected, status, expected, text[:160]))

    session_id = "auth-edge-" + uuid.uuid4().hex[:8]
    status, text = chat_order_status(resources, alex, session_id)
    checks.append(("alex can create chat session", status == 200, status, 200, text[:160]))

    status, text = http_request(resources, f"/sessions/{session_id}", token=blake)
    checks.append(
        (
            "blake cannot read alex session",
            status in (403, 404),
            status,
            "403 or 404",
            text[:160],
        )
    )

    status, text = http_request(resources, f"/sessions/{session_id}", token=alex)
    checks.append(("alex can read own session", status == 200, status, 200, text[:160]))

    log("AUTH_EDGE_RESULTS")
    failed = False
    for label, ok, status, expected, sample in checks:
        log(json.dumps({"check": label, "ok": ok, "status": status, "expected": expected, "sample": sample}))
        failed = failed or not ok
    require(not failed, "one or more auth edge checks failed")
    log("PASS auth_edge_cases")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DrillFailure as exc:
        log(f"FAIL auth_edge_cases: {exc}")
        raise SystemExit(1)
