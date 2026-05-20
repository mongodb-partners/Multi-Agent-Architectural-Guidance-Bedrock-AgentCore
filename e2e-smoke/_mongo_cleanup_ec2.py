#!/usr/bin/env python3
"""LTM harness cleanup — runs ON EC2 (PrivateLink-accessible).

Deletes harness-tagged pollution from both `agent_memory_facts` and
`chat_messages` for the supplied userId, so the diagnostic harness sees a
clean state for scenarios C/D/G whose needle uniqueness depends on no prior
identical codenames being present.

Heuristic match: facts/messages whose text matches one of the harness
"codename family" prefixes. Scoped to the harness user via `userId`.

Prints a JSON summary {"facts_deleted": N, "chat_messages_deleted": M}.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Any

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
    if not uri:
        print(json.dumps({"error": "MONGODB_URI missing"}))
        return 1

    # Harness-specific token prefixes. ANCHORED on tokens the harness uses
    # so we never accidentally nuke real user-generated data. CASE-INSENSITIVE.
    codename_regex = (
        "heliotrope|aurora-x9|deepfern|oldstone-meridian|crimson-mistral|"
        "mem-diag|RECALL-A-|mnemonic phrase"
    )
    sess_regex = "^(mem-diag-|post-deploy-smoke-ltm-)"

    client = MongoClient(uri, serverSelectionTimeoutMS=10000)
    try:
        client.admin.command("ping")
    except Exception as exc:
        print(json.dumps({"error": f"ping failed: {exc}"}))
        return 1

    db = client[db_name] if db_name else client.get_default_database()

    facts_filter: dict[str, Any] = {"fact": {"$regex": codename_regex, "$options": "i"}}
    msgs_filter: dict[str, Any] = {
        "$or": [
            {"sessionId": {"$regex": sess_regex}},
            {"content": {"$regex": codename_regex, "$options": "i"}},
        ]
    }
    if user_id:
        facts_filter["userId"] = user_id
        msgs_filter = {"$and": [{"userId": user_id}, msgs_filter]}

    f_count = db["agent_memory_facts"].count_documents(facts_filter, maxTimeMS=15000)
    m_count = db["chat_messages"].count_documents(msgs_filter, maxTimeMS=15000)
    f_res = db["agent_memory_facts"].delete_many(facts_filter)
    m_res = db["chat_messages"].delete_many(msgs_filter)

    print(json.dumps({
        "db": db.name,
        "user_id_scope": user_id or "(global — no userId filter)",
        "facts_matched": f_count,
        "facts_deleted": f_res.deleted_count,
        "chat_messages_matched": m_count,
        "chat_messages_deleted": m_res.deleted_count,
    }))
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
