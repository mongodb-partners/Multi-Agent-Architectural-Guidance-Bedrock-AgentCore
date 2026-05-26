#!/usr/bin/env python3
"""Direct $vectorSearch probe — runs ON EC2.

Embeds a query string via the Voyage SageMaker endpoint, then queries the
chat_messages vector index with the same userId filter the retriever uses
in production. Prints the top-20 rows with content excerpts so we can see
exactly where C's plant lands.

Envelope contract: this probe MUST build the exact same request body as
`buildVoyageRequestBody` in api/src/adapters/voyage-embedding.ts. The
historical body here was `{"inputs": [<text>]}` which matches NEITHER the
legacy `{"input": [<text>], ...}` nor the multimodal
`{"inputs": [{"content": [{"type": "text", "text": "<text>"}]}], ...}`
envelope — so any operator running this script to diagnose a recall miss
got a confusing 400 instead of an answer. Fix lives in this file alongside
the preflight smoke check and the api adapter.

ENV inputs:
  HARNESS_USER_ID         e.g. e4987498-70b1-704e-a558-0aa201bf95b1
  QUERY_TEXT              the recall query string to embed + search
  NEEDLE                  the codename to highlight in results (optional)
  VOYAGE_REQUEST_FORMAT   (from .env.live) — 'multimodal' (default) or 'legacy'
  VOYAGE_OUTPUT_DIM       (from .env.live, legacy only) — defaults to 1024
"""
from __future__ import annotations

import json
import os
import sys

try:
    import boto3
    from pymongo import MongoClient
except ImportError as exc:
    print(json.dumps({"error": f"deps missing: {exc}"}))
    raise SystemExit(2)


ENV_FILE = "/opt/multiagent/.env.live"


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

    # Embed via SageMaker (Voyage) — body MUST match buildVoyageRequestBody
    # in api/src/adapters/voyage-embedding.ts. See module docstring.
    voyage_format = (env.get("VOYAGE_REQUEST_FORMAT") or "multimodal").strip().lower()
    if voyage_format != "legacy":
        voyage_format = "multimodal"
    truncated = (query_text or "")[:32_000]
    if voyage_format == "legacy":
        try:
            output_dim = int(env.get("VOYAGE_OUTPUT_DIM") or "1024")
        except ValueError:
            output_dim = 1024
        request_body = {
            "input": [truncated],
            "input_type": "query",
            "output_dimension": output_dim,
        }
    else:
        request_body = {
            "inputs": [{"content": [{"type": "text", "text": truncated}]}],
            "input_type": "query",
            "truncation": True,
            "output_encoding": None,
        }

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
            if voyage_format == "multimodal":
                hint = " — endpoint rejected the multimodal envelope; the deployed model package is probably text-only. Flip VOYAGE_REQUEST_FORMAT=legacy in .env.live or re-deploy with the correct Marketplace model."
            else:
                hint = " — endpoint rejected the legacy envelope; the deployed model package is multimodal. Flip VOYAGE_REQUEST_FORMAT=multimodal in .env.live or re-deploy with the correct Marketplace model."
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
