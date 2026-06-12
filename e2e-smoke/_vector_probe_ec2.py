#!/usr/bin/env python3
"""Direct $vectorSearch probe — runs ON EC2.

Embeds a query string via the Voyage SageMaker endpoint, then queries the
chat_messages vector index with the same userId filter the retriever uses
in production. Prints the top-20 rows with content excerpts so we can see
exactly where C's plant lands.

Envelope contract: this probe shells out to `api/scripts/voyage-print.ts body`
so the request body is byte-for-byte identical to what
`buildVoyageRequestBody` in api/src/adapters/voyage-embedding.ts produces.
We never hand-roll the multimodal envelope in Python — that's the SSOT
guarantee enforced by `api/tests/unit/voyage-ssot-guard.test.ts`.

ENV inputs:
  HARNESS_USER_ID         e.g. e4987498-70b1-704e-a558-0aa201bf95b1
  QUERY_TEXT              the recall query string to embed + search
  NEEDLE                  the codename to highlight in results (optional)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

try:
    import boto3
    from pymongo import MongoClient
except ImportError as exc:
    print(json.dumps({"error": f"deps missing: {exc}"}))
    raise SystemExit(2)


ENV_FILE = "/opt/multiagent/.env.live"

# Locations where api/scripts/voyage-print.ts may live, in priority order.
# Production EC2 unpacks the repo at /opt/multiagent; local runs use cwd.
_VOYAGE_PRINT_CANDIDATES = (
    "/opt/multiagent/api/scripts/voyage-print.ts",
    os.path.join(os.path.dirname(__file__), "..", "api", "scripts", "voyage-print.ts"),
)


def _voyage_canonical_body(text: str, input_type: str = "query") -> dict:
    """Shell out to voyage-print.ts to build the canonical multimodal body.

    Returns the dict (not the raw JSON string) so the caller can pass it to
    json.dumps for the SageMaker invoke call.
    """
    bun = shutil.which("bun")
    if not bun:
        raise RuntimeError(
            "bun not on PATH — required to build the canonical Voyage body. "
            "Install bun or run this probe on an EC2 host where bun is present."
        )
    script = next((p for p in _VOYAGE_PRINT_CANDIDATES if os.path.exists(p)), None)
    if script is None:
        raise RuntimeError(
            "voyage-print.ts not found in any of: " + ", ".join(_VOYAGE_PRINT_CANDIDATES)
        )
    truncated = (text or "")[:32_000]
    proc = subprocess.run(
        [bun, script, "body", truncated, input_type],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(proc.stdout)


def parse_env(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            v = v.strip()
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                v = v[1:-1]
            out[k.strip()] = v
    return out


def main() -> int:
    env = parse_env(ENV_FILE)
    uri = env.get("MONGODB_URI") or ""
    db_name = env.get("MONGODB_DB") or ""
    sm_endpoint = (
        env.get("EMBEDDINGS_PROVIDER_VOYAGE_SM_ENDPOINT")
        or env.get("SAGEMAKER_VOYAGE_ENDPOINT")
        or env.get("VOYAGE_SAGEMAKER_ENDPOINT")
        # Final fallback: the shared SageMaker endpoint name now follows
        # "<voyage_endpoint_name_suffix>-<environment>" (no project_name prefix)
        # since envs/shared owns the singleton SageMaker endpoint.
        or "voyage-multimodal-3-dev"
    )
    region = env.get("AWS_REGION") or "us-east-1"
    user_id = os.environ.get("HARNESS_USER_ID") or ""
    query_text = os.environ.get("QUERY_TEXT") or ""
    needle = os.environ.get("NEEDLE") or ""
    if not uri or not user_id or not query_text:
        print(json.dumps({"error": "MONGODB_URI / HARNESS_USER_ID / QUERY_TEXT required"}))
        return 1

    # Embed via SageMaker (Voyage) — body is produced by the TS SSOT
    # (api/scripts/voyage-print.ts → buildVoyageRequestBody). No legacy
    # branch: this stack only supports voyage-multimodal-3/3.5.
    try:
        request_body = _voyage_canonical_body(query_text, "query")
    except Exception as exc:
        print(json.dumps({"error": f"voyage_canonical_body failed: {exc}"}))
        return 1

    sm = boto3.client("sagemaker-runtime", region_name=region)
    try:
        resp = sm.invoke_endpoint(
            EndpointName=sm_endpoint,
            ContentType="application/json",
            Accept="application/json",
            Body=json.dumps(request_body),
        )
    except Exception as exc:
        msg = str(exc)
        hint = ""
        if "Field required" in msg and ("input" in msg or "inputs" in msg):
            hint = (
                " — endpoint rejected the multimodal envelope; the deployed "
                "model package is text-only. This stack only supports "
                "voyage-multimodal-3 / voyage-multimodal-3.5. Set "
                "VOYAGE_MODEL_PACKAGE_ARN to a supported multimodal package, "
                "then run ./deploy/scripts/deploy-shared.sh."
            )
        print(json.dumps({"error": f"invoke_endpoint failed: {msg}{hint}"}))
        return 1

    body = json.loads(resp["Body"].read())
    # Canonical Voyage response (both legacy + multimodal listings):
    #   { "data": [{ "embedding": [...], "index": 0 }], "model": "...", "usage": {...} }
    # Older / forked listings sometimes return {"embeddings": [[...]]} or a
    # bare list-of-lists — keep those fallbacks so the probe is robust to
    # minor envelope drift, but prefer the canonical shape first.
    emb = None
    if isinstance(body, dict):
        data = body.get("data")
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict):
                emb = first.get("embedding")
        if emb is None and isinstance(body.get("embeddings"), list) and body["embeddings"]:
            emb = body["embeddings"][0]
    elif isinstance(body, list) and body:
        emb = body[0]
    if not isinstance(emb, list):
        print(json.dumps({"error": f"unexpected SageMaker response shape: {json.dumps(body)[:200]}"}))
        return 1

    client = MongoClient(uri, serverSelectionTimeoutMS=10000)
    db = client[db_name]
    pipeline = [
        {
            "$vectorSearch": {
                "index": "chat_messages-vector-index",
                "path": "embedding",
                "queryVector": emb,
                "numCandidates": 200,
                "limit": 20,
                "filter": {"userId": user_id},
            }
        },
        {
            "$project": {
                "_id": 0,
                "sessionId": 1,
                "role": 1,
                "ts": 1,
                "content": 1,
                "score": {"$meta": "vectorSearchScore"},
            }
        },
    ]
    results = list(db["chat_messages"].aggregate(pipeline, maxTimeMS=15000))
    print(f"=== Top {len(results)} vector hits for query ===")
    print(f"Query: {query_text[:120]!r}")
    print(f"Needle: {needle!r}")
    print()
    for i, r in enumerate(results):
        marker = "  ✓ NEEDLE" if needle and needle.lower() in (r.get("content") or "").lower() else ""
        print(f"[{i:2d}] score={r.get('score'):.4f} role={r.get('role')} sess={r.get('sessionId')}{marker}")
        print(f"     content={(r.get('content') or '')[:200]}")
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
