#!/usr/bin/env python3
"""Mongo audit for the LTM diagnostic — runs ON EC2 (PrivateLink-accessible).

Reads MONGODB_URI / MONGODB_DB from /opt/multiagent/.env.live and prints a JSON
report covering:
  - collection doc counts (agent_memory_facts, chat_messages)
  - vector index health for both collections
  - lexical (text) index health for both collections
  - vectorless-row counts (`embedding: null` or missing) for both collections
  - per-collection role distribution on chat_messages (user vs assistant)
  - sample rows for spot-check

Output: single JSON document on stdout, single line. Exit non-zero on hard
failure; print warnings inline for soft failures (e.g. listSearchIndexes not
supported on local replicas — fine, just degrades that field).
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from typing import Any

try:
    from pymongo import MongoClient
    from pymongo.errors import OperationFailure
except ImportError:
    print(json.dumps({"error": "pymongo missing on host"}))
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
            # Strip optional surrounding quotes (single or double).
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                v = v[1:-1]
            out[k.strip()] = v
    return out


def main() -> int:
    env = parse_env(ENV_FILE)
    uri = env.get("MONGODB_URI") or os.environ.get("MONGODB_URI") or ""
    db_name = env.get("MONGODB_DB") or os.environ.get("MONGODB_DB") or ""
    if not uri:
        print(json.dumps({"error": "MONGODB_URI not present in .env.live"}))
        return 1

    report: dict[str, Any] = {
        "timestamp": int(time.time()),
        "env_file": ENV_FILE,
        "db": db_name,
    }
    client = MongoClient(uri, serverSelectionTimeoutMS=10000)
    try:
        client.admin.command("ping")
    except Exception as exc:
        print(json.dumps({"error": f"ping failed: {exc.__class__.__name__}: {exc}"}))
        return 1

    db = client[db_name] if db_name else client.get_default_database()
    report["db_resolved"] = db.name

    for coll_name in ("agent_memory_facts", "chat_messages"):
        coll = db[coll_name]
        section: dict[str, Any] = {}
        try:
            section["count"] = coll.estimated_document_count()
        except Exception as exc:
            section["count_error"] = f"{exc.__class__.__name__}: {exc}"
        # vectorless rows
        try:
            section["vectorless_count"] = coll.count_documents(
                {"$or": [{"embedding": {"$exists": False}}, {"embedding": None}]},
                maxTimeMS=15000,
            )
        except Exception as exc:
            section["vectorless_error"] = f"{exc.__class__.__name__}: {exc}"
        # last-write timestamp (heuristic — `ts` is the canonical write field)
        try:
            latest = list(coll.find({}, {"ts": 1}).sort("ts", -1).limit(1))
            if latest:
                section["last_ts"] = latest[0].get("ts")
        except Exception as exc:
            section["last_ts_error"] = f"{exc.__class__.__name__}: {exc}"
        # search indexes (vector + text)
        try:
            indexes = list(coll.list_search_indexes())
            section["search_indexes"] = [
                {
                    "name": ix.get("name"),
                    "status": ix.get("status"),
                    "queryable": ix.get("queryable"),
                    "type": ix.get("type"),
                }
                for ix in indexes
            ]
        except OperationFailure as exc:
            section["search_indexes_error"] = f"OperationFailure: {exc.code} {exc.details}"
        except Exception as exc:
            section["search_indexes_error"] = f"{exc.__class__.__name__}: {exc}"
        # role distribution (only meaningful on chat_messages)
        if coll_name == "chat_messages":
            try:
                pipeline = [
                    {"$group": {"_id": "$role", "n": {"$sum": 1}}},
                    {"$sort": {"n": -1}},
                ]
                section["role_breakdown"] = list(coll.aggregate(pipeline, maxTimeMS=15000))
            except Exception as exc:
                section["role_breakdown_error"] = f"{exc.__class__.__name__}: {exc}"
        # sample (no embedding to keep output small)
        try:
            sample = list(coll.aggregate([
                {"$sample": {"size": 2}},
                {"$project": {"embedding": 0}},
            ], maxTimeMS=15000))
            # sanitize ObjectIds + datetimes for JSON
            for row in sample:
                for k, v in list(row.items()):
                    if hasattr(v, "isoformat"):
                        row[k] = v.isoformat()
                    elif type(v).__name__ == "ObjectId":
                        row[k] = str(v)
            section["sample"] = sample
        except Exception as exc:
            section["sample_error"] = f"{exc.__class__.__name__}: {exc}"
        report[coll_name] = section

    print(json.dumps(report, default=str))
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
