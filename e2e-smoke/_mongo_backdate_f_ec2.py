#!/usr/bin/env python3
"""Backdate a chat_messages row for Scenario F — runs ON EC2 (PrivateLink).

Reads RUN_ID and HARNESS_USER_ID from env. Inserts a synthetic chat row
75 days back with the harness "oldstone-meridian-<run_id>" needle so the
harness's Scenario F can validate recency-decay tolerance.

Prints JSON `{"inserted_at": iso, "messageId": id}` on success.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone

try:
    from pymongo import MongoClient
except ImportError:
    print(json.dumps({"error": "pymongo missing"}))
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
    uri = env.get("MONGODB_URI") or os.environ.get("MONGODB_URI") or ""
    db_name = env.get("MONGODB_DB") or os.environ.get("MONGODB_DB") or ""
    user_id = os.environ.get("HARNESS_USER_ID") or ""
    run_id = os.environ.get("RUN_ID") or ""
    if not uri or not user_id or not run_id:
        print(json.dumps({"error": "missing MONGODB_URI / HARNESS_USER_ID / RUN_ID"}))
        return 1

    backdate = datetime.now(timezone.utc) - timedelta(days=75)
    needle = f"oldstone-meridian-{run_id}"
    msg_id = f"diag-aged-{run_id}"
    sid = f"mem-diag-{run_id}-F"
    doc = {
        "messageId": msg_id,
        "sessionId": sid,
        "userId": user_id,
        "agentId": "product-recommendation",
        "role": "user",
        "content": f"My anniversary lighthouse codename is {needle}.",
        "timestamp": backdate.isoformat(),
        "ts": backdate,
    }
    client = MongoClient(uri, serverSelectionTimeoutMS=10000)
    db = client[db_name] if db_name else client.get_default_database()
    db["chat_messages"].replace_one({"messageId": msg_id}, doc, upsert=True)
    print(json.dumps({
        "inserted_at": backdate.isoformat(),
        "messageId": msg_id,
        "sessionId": sid,
        "needle": needle,
        "db": db.name,
    }))
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
