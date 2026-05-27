#!/usr/bin/env python3
"""Long-term memory recall diagnostic harness.

Goal: determine why `chat_messages` recall under-performs while
`agent_memory_facts` recall works, and surface a verdict mapped to one of
seven hypotheses (index status, embedding-provider drift, missing vectors,
weight dominance, noisy long content, role filter, recency decay).

Run from the repository root after deployment:

    source .env
    python3 e2e-smoke/memory-recall-diagnostic.py            # full run
    python3 e2e-smoke/memory-recall-diagnostic.py --audit    # mongo audit only
    python3 e2e-smoke/memory-recall-diagnostic.py --scenarios A B C
    python3 e2e-smoke/memory-recall-diagnostic.py --json out/diag.json

The harness creates throwaway sessions tagged with the prefix
`mem-diag-<run_id>-` so they're trivially identifiable and bounded.

Environment overrides:
    DEPLOY_MANIFEST_PATH   Path to deploy-manifest.json (default: repo root)
    API_URL                Override deploy-manifest.ec2_api_url
    COGNITO_CLIENT_ID      Override deploy-manifest.cognito_client_id
    E2E_USER, E2E_PASS     Cognito credentials (defaults: alex/DemoUser#2026)
    MONGODB_URI_PUBLIC     Preferred. Public SRV URI used for off-VPC tooling
                           (chat_messages cleanup in scenarios C/F). Emitted by
                           deploy-api.sh into the env-file pair at the repo
                           root. The harness auto-loads `.env.docker` (or
                           falls back to `.env.live`) before reading env vars,
                           so no shell wiring is required.
    MONGODB_URI            Fallback. Used when MONGODB_URI_PUBLIC is unset.
                           The `MONGODB_URI` value is the PrivateLink direct
                           URI — usable only from inside the EC2 VPC.
                           If you're running the harness from your laptop and
                           see "scenarios C/F SKIPPED", it means the env file is
                           missing or out of date; rerun deploy-api.sh.
    MONGODB_DB             Database name (defaults to deploy manifest value)
    MEMORY_DIAG_SETTLE     Seconds to wait between plant and recall (default 6)
    MEMORY_DIAG_TRACE_WAIT Seconds to wait for trace persistence (default 2)
    MEMORY_DIAG_TRACE_RETRIES Trace fetch retries (default 5)

Exit code is 0 if every required scenario PASSes, 1 otherwise. The verdict
report is always written to stdout. Use `--json <file>` to also dump the
structured result for downstream tooling.
"""

from __future__ import annotations

import argparse
import dataclasses
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "deploy-manifest.json"

# Hypothesis identifiers used by the verdict engine. Keep stable; downstream
# alerts and docs reference them by id.
HYPOTHESES = {
    "H1": "Atlas Search / Vector index for chat_messages not READY/queryable",
    "H2": "Embedding-provider drift between write and read (vector spaces differ)",
    "H3": "Many chat_messages rows missing `embedding` field",
    "H4": "Fact-collection weight dominance crowds out chat_messages in MMR",
    "H5": "Long/noisy chat_messages content produces unhelpful embeddings",
    "H6": "MEMORY_INCLUDE_ASSISTANT_MESSAGES=0 excludes assistant replies",
    "H7": "Recency decay too aggressive against older chat_messages",
}


# ---------------------------------------------------------------------------
# Logging + structured result types
# ---------------------------------------------------------------------------


def log(msg: str) -> None:
    print(msg, flush=True)


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str = ""
    extra: dict[str, Any] = field(default_factory=dict)


@dataclass
class ScenarioResult:
    id: str
    title: str
    passed: bool
    checks: list[CheckResult] = field(default_factory=list)
    trace_summary: dict[str, Any] = field(default_factory=dict)
    text_preview: str = ""
    trace_id: str = ""
    skipped: bool = False
    skip_reason: str = ""

    def fail(self, name: str, detail: str = "", **extra: Any) -> None:
        self.checks.append(CheckResult(name, False, detail, extra))
        self.passed = False

    def ok(self, name: str, detail: str = "", **extra: Any) -> None:
        self.checks.append(CheckResult(name, True, detail, extra))

    def skip(self, reason: str) -> None:
        """Mark the scenario as skipped (e.g. missing prerequisites). Skipped
        scenarios are NOT counted as failures by `compute_verdict` and do not
        flip the harness exit code."""
        self.skipped = True
        self.skip_reason = reason
        self.passed = True  # not a failure for exit-code purposes


# ---------------------------------------------------------------------------
# Manifest / configuration loading
# ---------------------------------------------------------------------------


def load_manifest_resources(path: Path) -> dict[str, Any]:
    """Best-effort manifest loader. Returns {} if missing — env vars must fill the gap."""
    if not path.exists():
        log(f"warn: deploy-manifest.json not found at {path}; relying on env vars")
        return {}
    doc = json.loads(path.read_text())
    resources = doc.get("resources") or {}
    for key in ("aws_account", "aws_region", "environment"):
        resources.setdefault(key, doc.get(key) or os.environ.get(key.upper(), ""))
    return resources


def _load_env_live_into_environ() -> None:
    """Auto-load `.env.docker` (Docker `--env-file` format: plain KEY=VALUE,
    no quotes, no escapes) into `os.environ` for any keys not already set.

    Rationale: `.env.docker` is the canonical Docker format written by
    `deploy/scripts/_env-live.sh` — values pass through verbatim (no shell
    parsing, no escape sequences) so it's the safest source for Python.
    Reading the file directly here means `python3 e2e-smoke/...` "just
    works" after `deploy-api.sh`, no shell wiring required.

    `.env.live` (the bash-source-safe sibling) is also accepted as a
    fallback if only that file exists — single-layer surrounding quotes
    are stripped.

    Existing env vars win — explicit overrides from the caller's shell are
    never clobbered. Comment lines (`#`) and blank lines are skipped.
    """
    repo_root = Path(__file__).resolve().parents[1]
    docker_file = repo_root / ".env.docker"
    bash_file = repo_root / ".env.live"
    candidate = docker_file if docker_file.exists() else (bash_file if bash_file.exists() else None)
    if candidate is None:
        return
    try:
        for line in candidate.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            # `.env.docker` is unquoted by construction; `.env.live` wraps
            # every value in double quotes. Strip one outer layer if present.
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            if key and key not in os.environ:
                os.environ[key] = value
    except OSError as exc:
        log(f"warn: failed to read {candidate.name} ({exc}); falling back to current env")


def resolve_config() -> dict[str, Any]:
    _load_env_live_into_environ()
    manifest = load_manifest_resources(
        Path(os.environ.get("DEPLOY_MANIFEST_PATH", str(DEFAULT_MANIFEST)))
    )
    api_url = (os.environ.get("API_URL") or manifest.get("ec2_api_url") or "").rstrip("/")
    client_id = os.environ.get("COGNITO_CLIENT_ID") or manifest.get("cognito_client_id") or ""
    region = (
        os.environ.get("AWS_REGION")
        or manifest.get("aws_region")
        or "us-east-1"
    )
    # MONGODB_URI_PUBLIC is the public SRV URI emitted to .env.live by
    # deploy-api.sh for off-VPC tooling (this harness's cleanup of
    # chat_messages in scenarios C/F). The `MONGODB_URI` in .env.live is the
    # PrivateLink direct URI, only resolvable from inside the EC2 VPC. We
    # prefer the public URI when set so the harness works from a laptop
    # without requiring an SSM-into-EC2 step. Production code paths
    # (api/src/lib/mongo-data.ts, mongo-client.ts) always use MONGODB_URI.
    mongodb_uri = os.environ.get("MONGODB_URI_PUBLIC") or os.environ.get("MONGODB_URI", "")
    mongodb_db = (
        os.environ.get("MONGODB_DB")
        or manifest.get("mongodb_db")
        or ""
    )
    return {
        "api_url": api_url,
        "cognito_client_id": client_id,
        "aws_region": region,
        "mongodb_uri": mongodb_uri,
        "mongodb_db": mongodb_db,
        "e2e_user": os.environ.get("E2E_USER", "alex@example.com"),
        "e2e_pass": os.environ.get("E2E_PASS", "DemoUser#2026"),
        "settle_seconds": int(os.environ.get("MEMORY_DIAG_SETTLE", "6")),
        "trace_wait_seconds": int(os.environ.get("MEMORY_DIAG_TRACE_WAIT", "2")),
        "trace_retries": int(os.environ.get("MEMORY_DIAG_TRACE_RETRIES", "5")),
    }


# ---------------------------------------------------------------------------
# Cognito + API client (urllib only — no boto3 hard-dep)
# ---------------------------------------------------------------------------


def cognito_token(client_id: str, region: str, user: str, password: str) -> str:
    """Fetch a Cognito IdToken via the AWS CLI (matches post-deploy-smoke.py)."""
    import subprocess

    out = subprocess.check_output(
        [
            "aws",
            "cognito-idp",
            "initiate-auth",
            "--region",
            region,
            "--client-id",
            client_id,
            "--auth-flow",
            "USER_PASSWORD_AUTH",
            "--auth-parameters",
            f"USERNAME={user},PASSWORD={password}",
            "--query",
            "AuthenticationResult.IdToken",
            "--output",
            "text",
        ],
        text=True,
        stderr=subprocess.STDOUT,
        timeout=60,
    ).strip()
    if len(out) < 100:
        raise SystemExit(f"Cognito returned invalid token: {out[:200]}")
    return out


def post_chat(
    api_url: str, token: str, agent: str, session_id: str, message: str
) -> tuple[str, str | None]:
    """POST /chat and return (raw_sse_body, x_trace_id)."""
    payload = json.dumps(
        {"agentId": agent, "sessionId": session_id, "message": message}
    ).encode()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    last_error: BaseException | None = None
    for attempt in range(1, 4):
        try:
            req = urllib.request.Request(
                f"{api_url}/chat", data=payload, headers=headers, method="POST"
            )
            with urllib.request.urlopen(req, timeout=240) as resp:
                x_trace = resp.headers.get("X-Trace-Id") or resp.headers.get("x-trace-id")
                body = resp.read().decode("utf-8", "replace")
                return body, x_trace
        except (
            http.client.IncompleteRead,
            http.client.HTTPException,
            TimeoutError,
            urllib.error.URLError,
        ) as exc:
            last_error = exc
            if attempt < 3:
                time.sleep(5 * attempt)
    raise SystemExit(f"POST /chat failed after retries for {agent}: {last_error}")


def parse_sse(body: str) -> dict[str, Any]:
    tokens: list[str] = []
    events: list[str] = []
    trace_id = ""
    for block in body.split("\n\n"):
        lines = block.strip().splitlines()
        if not lines:
            continue
        event = ""
        data_lines: list[str] = []
        for line in lines:
            if line.startswith("event: "):
                event = line[7:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
        if not event:
            continue
        events.append(event)
        raw = "\n".join(data_lines)
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw}
        if event == "token":
            tokens.append(str(payload.get("text", "")))
        elif event == "done":
            tid = payload.get("traceId")
            if isinstance(tid, str):
                trace_id = tid
    return {
        "text": "".join(tokens),
        "events": events,
        "trace_id": trace_id,
    }


def list_sessions(api_url: str, token: str) -> list[dict[str, Any]]:
    """GET /sessions for the current user (token's `sub`). Returns [] on failure."""
    headers = {"Authorization": f"Bearer {token}"}
    try:
        req = urllib.request.Request(f"{api_url}/sessions", headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            doc = json.loads(resp.read().decode("utf-8", "replace"))
            sessions = doc.get("sessions") if isinstance(doc, dict) else None
            if isinstance(sessions, list):
                return [s for s in sessions if isinstance(s, dict)]
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
        log(f"warn: list_sessions failed: {exc}")
    return []


def delete_session(api_url: str, token: str, session_id: str) -> bool:
    """DELETE /sessions/:id. Returns True on 204, False otherwise.

    DELETE on a session cascade-deletes the `chat_messages` mirror rows on the
    backend (session-store.ts wires that up), so this is the right cleanup
    primitive for harness pollution.
    """
    headers = {"Authorization": f"Bearer {token}"}
    try:
        req = urllib.request.Request(
            f"{api_url}/sessions/{session_id}", headers=headers, method="DELETE"
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status == 204
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return True  # already gone — treat as success
        log(f"warn: delete_session({session_id}) HTTP {exc.code}: {exc.reason}")
    except (urllib.error.URLError, TimeoutError) as exc:
        log(f"warn: delete_session({session_id}) failed: {exc}")
    return False


def cleanup_harness_sessions(
    api_url: str, token: str, prefix: str = "mem-diag-"
) -> dict[str, int]:
    """Delete every chat session owned by the current user whose id starts
    with the harness prefix. Returns a summary dict for the report."""
    sessions = list_sessions(api_url, token)
    targets = [
        s for s in sessions
        if isinstance(s.get("sessionId"), str)
        and s["sessionId"].startswith(prefix)
    ]
    deleted = 0
    failed = 0
    for s in targets:
        sid = s["sessionId"]
        if delete_session(api_url, token, sid):
            deleted += 1
        else:
            failed += 1
    log(
        f"cleanup: scanned {len(sessions)} sessions, matched {len(targets)} "
        f"with prefix {prefix!r}, deleted {deleted}, failed {failed}"
    )
    return {"scanned": len(sessions), "matched": len(targets), "deleted": deleted, "failed": failed}


def cleanup_harness_facts(uri: str, db_name: str, user_id: str | None = None) -> dict[str, int]:
    """Delete pollution from `agent_memory_facts` introduced by prior harness
    runs. Heuristic: facts whose text contains 'run-', 'mem-diag', or one of
    the codename prefixes the harness plants (heliotrope/aurora/deepfern/
    oldstone/crimson). Restricted to the supplied userId when known.

    Best-effort — returns `{"skipped": "<reason>"}` if pymongo isn't available
    or the connection fails. Read-only access is fine; only `delete_many`
    permission is required for the actual deletion.
    """
    try:
        from pymongo import MongoClient  # type: ignore
    except ImportError:
        return {"skipped": "pymongo not installed"}
    if not uri:
        return {"skipped": "MONGODB_URI not set"}
    client_kwargs: dict[str, Any] = {"serverSelectionTimeoutMS": 5000}
    try:
        import certifi  # type: ignore
        client_kwargs["tlsCAFile"] = certifi.where()
    except ImportError:
        pass
    client = None
    try:
        client = MongoClient(uri, **client_kwargs)
        client.admin.command("ping")
        db = client[db_name] if db_name else client.get_default_database()
        # Codename-prefix-based deletion (case-insensitive). Anchored on
        # tokens the harness uses so we don't nuke real user data.
        regex = "heliotrope|aurora-x9|deepfern|oldstone|crimson-mistral|mem-diag|RECALL-A-"
        flt: dict[str, Any] = {"fact": {"$regex": regex, "$options": "i"}}
        if user_id:
            flt["userId"] = user_id
        # chat_messages: any session id with the harness prefix.
        msg_flt: dict[str, Any] = {"sessionId": {"$regex": "^mem-diag-"}}
        if user_id:
            msg_flt["userId"] = user_id
        facts_res = db["agent_memory_facts"].delete_many(flt)
        msgs_res = db["chat_messages"].delete_many(msg_flt)
        return {
            "facts_deleted": facts_res.deleted_count,
            "chat_messages_deleted": msgs_res.deleted_count,
        }
    except Exception as exc:
        return {"skipped": f"{exc.__class__.__name__}: {exc}"}
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass


def fetch_trace(api_url: str, token: str, trace_id: str, retries: int = 5, sleep_s: float = 2.0) -> dict[str, Any] | None:
    """Poll /traces/:id with retries (trace persistence runs after `done`)."""
    if not trace_id:
        return None
    headers = {"Authorization": f"Bearer {token}"}
    last: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(f"{api_url}/traces/{trace_id}", headers=headers)
            with urllib.request.urlopen(req, timeout=30) as resp:
                doc = json.loads(resp.read().decode("utf-8", "replace"))
                if isinstance(doc, dict) and isinstance(doc.get("events"), list):
                    return doc
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
            last = exc
        time.sleep(sleep_s)
    log(f"warn: failed to fetch trace {trace_id} after {retries} retries: {last}")
    return None


# ---------------------------------------------------------------------------
# Trace event extraction
# ---------------------------------------------------------------------------


def find_events(trace: dict[str, Any], event_type: str) -> list[dict[str, Any]]:
    return [e for e in (trace.get("events") or []) if isinstance(e, dict) and e.get("type") == event_type]


def summarize_scoped_read(trace: dict[str, Any]) -> dict[str, Any]:
    events = find_events(trace, "memory.scoped_read")
    if not events:
        return {"ok": False, "error": "missing memory.scoped_read event"}
    p = (events[-1].get("payload") or {})
    r = (p.get("retrieval") or {})
    per = r.get("perCollection") or []
    by_coll = {row.get("collection"): row for row in per if isinstance(row, dict)}
    collections = set(p.get("collectionsQueried") or [])
    facts_row = by_coll.get("agent_memory_facts") or {}
    msgs_collection_name = next(
        (k for k in by_coll if k != "agent_memory_facts"),
        "chat_messages",
    )
    msgs_row = by_coll.get(msgs_collection_name) or {}
    return {
        "ok": True,
        "mode": p.get("mode"),
        "embedding_source": p.get("embeddingSource"),
        "embedding_model": p.get("embeddingModel"),
        "entry_count": int(p.get("entryCount") or 0),
        "bytes_injected": int(p.get("bytesInjected") or 0),
        "vector_hits": int(r.get("vectorHits") or 0),
        "lexical_hits": int(r.get("lexicalHits") or 0),
        "rrf_merged_count": int(r.get("rrfMergedCount") or 0),
        "has_facts_collection": "agent_memory_facts" in collections,
        "has_messages_collection": any(c.startswith("chat_messages") or c == "chat_messages" for c in collections),
        "facts_vector_returned": int(facts_row.get("vectorReturned") or 0),
        "facts_lexical_returned": int(facts_row.get("lexicalReturned") or 0),
        "messages_vector_returned": int(msgs_row.get("vectorReturned") or 0),
        "messages_lexical_returned": int(msgs_row.get("lexicalReturned") or 0),
        "messages_error": msgs_row.get("error"),
        "facts_error": facts_row.get("error"),
        "retrieval_error_class": p.get("retrievalErrorClass"),
        "retrieval_error_message": p.get("retrievalErrorMessage"),
    }


def summarize_long_term_write(trace: dict[str, Any]) -> dict[str, Any]:
    """Capture the memory.long_term_write event (if it landed in the persisted trace)."""
    events = find_events(trace, "memory.long_term_write")
    if not events:
        skips = find_events(trace, "memory.long_term_skip")
        if skips:
            return {"present": False, "skip_reason": (skips[-1].get("payload") or {}).get("reason")}
        return {"present": False, "skip_reason": None}
    p = (events[-1].get("payload") or {})
    return {
        "present": True,
        "facts_extracted": p.get("factsExtracted") or [],
        "docs_inserted": int(p.get("docsInserted") or 0),
        "duplicates_skipped": int(p.get("duplicatesSkipped") or 0),
        "embedded_count": int(p.get("embeddedCount") or 0),
        "embedding_model": p.get("embeddingModel"),
    }


# ---------------------------------------------------------------------------
# Mongo audit (read-only, optional)
# ---------------------------------------------------------------------------


def mongo_audit(uri: str, db_name: str) -> dict[str, Any]:
    """Run read-only audits against the live Mongo cluster.

    Returns a dict keyed by check name with a structured result. Each check
    is best-effort and won't bubble up an exception — failures land as
    `{"error": "..."}` so the harness can still run scenarios.
    """
    try:
        from pymongo import MongoClient  # type: ignore
    except ImportError:
        return {"_error": "pymongo not installed (pip install pymongo)"}

    if not uri:
        return {"_error": "MONGODB_URI env var not set"}

    # macOS system Python often has no system trust roots — point pymongo at
    # certifi when it's available so Atlas TLS handshakes don't fail.
    client_kwargs: dict[str, Any] = {"serverSelectionTimeoutMS": 5000}
    try:
        import certifi  # type: ignore
        client_kwargs["tlsCAFile"] = certifi.where()
    except ImportError:
        pass

    out: dict[str, Any] = {}
    client = None
    try:
        client = MongoClient(uri, **client_kwargs)
        client.admin.command("ping")
        db = client[db_name] if db_name else client.get_default_database()
        out["db_name"] = db.name

        for coll_name in ("agent_memory_facts", "chat_messages"):
            coll = db[coll_name]
            try:
                total = coll.estimated_document_count()
                missing_emb = coll.count_documents({"embedding": {"$exists": False}}, maxTimeMS=30_000)
                with_emb = max(total - missing_emb, 0)
                miss_pct = round((missing_emb / total) * 100, 2) if total > 0 else 0.0
                # embeddingModel distribution
                model_pipeline = [
                    {"$group": {"_id": "$embeddingModel", "n": {"$sum": 1}}},
                    {"$sort": {"n": -1}},
                    {"$limit": 10},
                ]
                models = list(coll.aggregate(model_pipeline, maxTimeMS=30_000))
                # Sample 3 docs without revealing content
                sample = list(
                    coll.find(
                        {},
                        {
                            "_id": 1,
                            "userId": 1,
                            "agentId": 1,
                            "role": 1,
                            "sessionId": 1,
                            "ts": 1,
                            "embeddingModel": 1,
                            "messageId": 1,
                        },
                    ).sort([("ts", -1)]).limit(3)
                )
                out[coll_name] = {
                    "total": total,
                    "with_embedding": with_emb,
                    "missing_embedding": missing_emb,
                    "missing_pct": miss_pct,
                    "embedding_models": [
                        {"model": m.get("_id") or "<none>", "n": int(m.get("n") or 0)} for m in models
                    ],
                    "sample_recent": [
                        {k: str(v) if k == "_id" else v for k, v in s.items()} for s in sample
                    ],
                }
            except Exception as exc:
                out[coll_name] = {"error": f"{exc.__class__.__name__}: {exc}"}

        # Atlas Search index status — listSearchIndexes is an Atlas-only helper.
        out["search_indexes"] = {}
        for coll_name, expected in (
            ("agent_memory_facts", ["agent_memory_facts-vector-index", "agent_memory_facts-text-index"]),
            ("chat_messages", ["chat_messages-vector-index", "chat_messages-text-index"]),
        ):
            try:
                indexes = list(db[coll_name].aggregate([{"$listSearchIndexes": {}}], maxTimeMS=30_000))
                summary = {}
                for idx in indexes:
                    name = idx.get("name")
                    if name in expected:
                        summary[name] = {
                            "status": idx.get("status"),
                            "queryable": bool(idx.get("queryable")),
                            "type": idx.get("type"),
                        }
                for exp in expected:
                    summary.setdefault(exp, {"status": "MISSING", "queryable": False})
                out["search_indexes"][coll_name] = summary
            except Exception as exc:
                out["search_indexes"][coll_name] = {"error": f"{exc.__class__.__name__}: {exc}"}
    except Exception as exc:
        out["_connection_error"] = f"{exc.__class__.__name__}: {exc}"
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
    return out


def render_audit_report(audit: dict[str, Any]) -> None:
    log("\n== Mongo audit ==")
    err = audit.get("_error") or audit.get("_connection_error")
    if err:
        log(f"  SKIP: {err}")
        return
    log(f"  database: {audit.get('db_name')}")
    for coll_name in ("agent_memory_facts", "chat_messages"):
        info = audit.get(coll_name) or {}
        if "error" in info:
            log(f"  {coll_name}: ERROR {info['error']}")
            continue
        log(
            f"  {coll_name}: total={info.get('total')} with_embedding={info.get('with_embedding')} "
            f"missing={info.get('missing_embedding')} ({info.get('missing_pct')}%)"
        )
        models = info.get("embedding_models") or []
        if models:
            mdesc = ", ".join(f"{m['model']}:{m['n']}" for m in models)
            log(f"     embedding_models: {mdesc}")
    log("  search_indexes:")
    for coll_name, summary in (audit.get("search_indexes") or {}).items():
        if isinstance(summary, dict) and "error" in summary:
            log(f"    {coll_name}: ERROR {summary['error']}")
            continue
        for idx_name, idx_info in summary.items():
            status = idx_info.get("status")
            queryable = idx_info.get("queryable")
            log(f"    {coll_name}.{idx_name}: status={status} queryable={queryable}")


# ---------------------------------------------------------------------------
# Scenario implementations
# ---------------------------------------------------------------------------


@dataclass
class HarnessContext:
    api_url: str
    token: str
    run_id: str
    settle_seconds: int
    trace_wait_seconds: int
    trace_retries: int


def _needle_match(text: str, positive: Iterable[str], negative: Iterable[str] = ()) -> bool:
    blob = text.lower()
    pos = any(p.lower() in blob for p in positive)
    neg = any(n.lower() in blob for n in negative)
    return pos and not neg


def _plant(ctx: HarnessContext, agent: str, session: str, message: str) -> dict[str, Any]:
    body, _ = post_chat(ctx.api_url, ctx.token, agent, session, message)
    return parse_sse(body)


def _recall(
    ctx: HarnessContext,
    agent: str,
    session: str,
    message: str,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    body, _ = post_chat(ctx.api_url, ctx.token, agent, session, message)
    parsed = parse_sse(body)
    time.sleep(ctx.trace_wait_seconds)
    trace = fetch_trace(
        ctx.api_url, ctx.token, parsed.get("trace_id", ""),
        retries=ctx.trace_retries, sleep_s=2.0,
    )
    return parsed, trace


def scenario_A(ctx: HarnessContext) -> ScenarioResult:
    """Intra-session — synchronous path."""
    s = ScenarioResult(id="A", title="Intra-session recall (synchronous path)", passed=True)
    needle = f"RECALL-A-{ctx.run_id}-7392"
    sid = f"mem-diag-{ctx.run_id}-A"
    _plant(ctx, "product-recommendation", sid, f"Remember this code: {needle}.")
    time.sleep(2)
    parsed, trace = _recall(
        ctx,
        "product-recommendation",
        sid,
        "What was the code I just gave you a moment ago? Repeat it exactly.",
    )
    s.text_preview = (parsed.get("text") or "")[:300]
    s.trace_id = parsed.get("trace_id", "")
    if trace:
        s.trace_summary = summarize_scoped_read(trace)
    if _needle_match(parsed.get("text", ""), [needle]):
        s.ok("intra-session needle present in reply", needle)
    else:
        s.fail("intra-session needle missing from reply", needle)
    return s


def scenario_B(ctx: HarnessContext) -> ScenarioResult:
    """Cross-session profile fact (baseline — should already work)."""
    s = ScenarioResult(id="B", title="Cross-session profile fact (baseline)", passed=True)
    sid1 = f"mem-diag-{ctx.run_id}-B-plant"
    sid2 = f"mem-diag-{ctx.run_id}-B-recall"
    _plant(
        ctx,
        "product-recommendation",
        sid1,
        f"Please remember: my favorite color is teal and my pet's name is Mango-{ctx.run_id}.",
    )
    time.sleep(ctx.settle_seconds)
    parsed, trace = _recall(
        ctx,
        "product-recommendation",
        sid2,
        "What is my favorite color? Answer in one sentence.",
    )
    s.text_preview = (parsed.get("text") or "")[:300]
    s.trace_id = parsed.get("trace_id", "")
    if trace:
        s.trace_summary = summarize_scoped_read(trace)
        if s.trace_summary.get("facts_vector_returned", 0) > 0 or s.trace_summary.get("facts_lexical_returned", 0) > 0:
            s.ok("facts collection returned hits")
        else:
            s.fail("facts collection returned zero hits", "baseline broken — LTM entirely down?")
    else:
        s.fail("trace not fetched", s.trace_id)
    if _needle_match(parsed.get("text", ""), ["teal"], ["don't know", "do not know", "no record"]):
        s.ok("reply contains 'teal'")
    else:
        s.fail("reply missing 'teal' or contains denial", s.text_preview)
    return s


def scenario_C(ctx: HarnessContext) -> ScenarioResult:
    """Cross-session conversational recall — THE H4 REGRESSION GUARD.

    Plants a needle in a `chat_messages`-only path (no fact extraction) and
    recalls it from a NEW session. Both the plant phrasing and the recall
    phrasing avoid the word "code" / "codename" / "debug" because scenario A
    also uses those words ("what was the code I just gave you") — same-run
    intra-session messages from A would otherwise compete for the same RRF
    space and crowd C's plant out of the top-K. The "lab notebook entry tag"
    framing keeps C semantically distinct from A while still exercising the
    same vector-search-on-chat_messages code path.
    """
    s = ScenarioResult(id="C", title="Cross-session conversational recall (chat_messages)", passed=True)
    sid1 = f"mem-diag-{ctx.run_id}-C-plant"
    sid2 = f"mem-diag-{ctx.run_id}-C-recall"
    anchor = f"run-{ctx.run_id}"
    needle = f"heliotrope-falcon-{anchor}"
    _plant(
        ctx,
        "product-recommendation",
        sid1,
        (
            f"Quick filing note for run {anchor}: please log the lab notebook "
            f"entry tag '{needle}' for this session so I can grep it later. "
            f"It's a notebook tag, not a coupon or a discount code."
        ),
    )
    time.sleep(ctx.settle_seconds)
    parsed, trace = _recall(
        ctx,
        "product-recommendation",
        sid2,
        (
            f"Earlier in run {anchor} I asked you to log a lab notebook entry "
            f"tag for this session. What was that exact tag string? It was "
            f"hyphenated and started with a flower name."
        ),
    )
    s.text_preview = (parsed.get("text") or "")[:300]
    s.trace_id = parsed.get("trace_id", "")
    if trace:
        s.trace_summary = summarize_scoped_read(trace)
        v = s.trace_summary.get("messages_vector_returned", 0)
        lx = s.trace_summary.get("messages_lexical_returned", 0)
        if v > 0 or lx > 0:
            s.ok("chat_messages collection returned hits", f"vector={v} lexical={lx}")
        else:
            err = s.trace_summary.get("messages_error") or "no hits and no per-leg error"
            s.fail("chat_messages collection returned zero hits", err)
    else:
        s.fail("trace not fetched", s.trace_id)
    if _needle_match(parsed.get("text", ""), [needle]):
        s.ok("recall reply contains the codename")
    else:
        s.fail("recall reply missing the codename", s.text_preview)
    return s


def scenario_D(ctx: HarnessContext) -> ScenarioResult:
    """Assistant-role recall — MEMORY_INCLUDE_ASSISTANT_MESSAGES probe.

    Plants the needle by stating a personal product preference and asking the
    assistant to confirm it (natural conversation, no verbatim-repeat
    instruction). The model's friendly confirmation reply echoes the needle
    back, which is what lands in `chat_messages` under the assistant role.
    Older revisions of this scenario asked the model to "reply with this
    exact sentence verbatim" — Bedrock now (correctly) refuses that pattern
    as a jailbreak attempt, so the planted needle never made it into
    chat_messages and the scenario looked like an LTM regression when it was
    actually a test-design flaw. See harness/git history for the migration.
    """
    s = ScenarioResult(id="D", title="Assistant-role recall (assistant-message vector indexing)", passed=True)
    sid1 = f"mem-diag-{ctx.run_id}-D-plant"
    sid2 = f"mem-diag-{ctx.run_id}-D-recall"
    anchor = f"run-{ctx.run_id}"
    needle = f"Aurora-X9-{anchor}"
    _plant(
        ctx,
        "product-recommendation",
        sid1,
        (
            f"For my outdoor headphones shortlist, the specific model I want "
            f"you to remember is the {needle}. Can you confirm you noted that "
            f"exact model name back to me, so I know it's on file?"
        ),
    )
    time.sleep(ctx.settle_seconds)
    parsed, trace = _recall(
        ctx,
        "product-recommendation",
        sid2,
        (
            f"Earlier I asked you to remember a specific headphone model for "
            f"my shortlist, with a name suffixed by '{anchor}'. Which exact "
            f"model name was it? Reply with the full string verbatim."
        ),
    )
    s.text_preview = (parsed.get("text") or "")[:300]
    s.trace_id = parsed.get("trace_id", "")
    if trace:
        s.trace_summary = summarize_scoped_read(trace)
        if (
            s.trace_summary.get("messages_vector_returned", 0) > 0
            or s.trace_summary.get("messages_lexical_returned", 0) > 0
        ):
            s.ok("chat_messages returned hits (assistant-role likely included)")
        else:
            s.fail("chat_messages returned zero hits in assistant-recall scenario", "")
    else:
        s.fail("trace not fetched", s.trace_id)
    if _needle_match(parsed.get("text", ""), [needle, "Aurora-X9"]):
        s.ok("recall reply contains the model name")
    else:
        s.fail("recall reply missing the model name", s.text_preview)
    return s


def scenario_E(ctx: HarnessContext) -> ScenarioResult:
    """Long-content recall — noisy embedding probe.

    The planted message is a single long user-side paragraph (no "include this
    phrase" gymnastics in the plant — that pattern triggers the model's
    prompt-injection guard at recall time and corrupts the signal).
    """
    s = ScenarioResult(id="E", title="Long-content recall (noisy embedding probe)", passed=True)
    sid1 = f"mem-diag-{ctx.run_id}-E-plant"
    sid2 = f"mem-diag-{ctx.run_id}-E-recall"
    anchor = f"run-{ctx.run_id}"
    needle = f"deepfern-cobalt-{anchor}"
    long_msg = (
        f"Diagnostic run {anchor}: here is some background you might want to "
        "remember for future product suggestions, all in my own words. "
        "I do a lot of work outdoors in damp conditions — coastal mornings, "
        "trail running in light rain, sometimes near boats. "
        "I usually look for over-ear waterproof headphones in the $80-$200 "
        "range, with at least 20 hours of battery and a secure but soft "
        "ear-pad fit because I have sensitive ears. "
        "My internal nickname for this kind of gear, which I'd like you to "
        f"remember verbatim, is '{needle}'. "
        "I currently own a pair I bought last year, and I'm considering an "
        "upgrade in the next few months. I prefer wireless but I tolerate "
        "USB-C wired for charging. I avoid in-ear earbuds because they fall "
        "out during running. I value tactile physical buttons over touch "
        "controls because gloves get in the way. I do not need ANC for these. "
        "Please acknowledge briefly and remember this for next time."
    )
    _plant(ctx, "product-recommendation", sid1, long_msg)
    time.sleep(ctx.settle_seconds)
    parsed, trace = _recall(
        ctx,
        "product-recommendation",
        sid2,
        (
            f"In diagnostic run {anchor} I told you about a personal nickname "
            f"I use for outdoor waterproof headphone gear. The nickname starts "
            f"with 'deepfern' and is suffixed with '{anchor}'. What was it? "
            f"Repeat it verbatim if you remember it."
        ),
    )
    s.text_preview = (parsed.get("text") or "")[:300]
    s.trace_id = parsed.get("trace_id", "")
    if trace:
        s.trace_summary = summarize_scoped_read(trace)
    if _needle_match(parsed.get("text", ""), [needle]):
        s.ok("recall reply contains the buried phrase")
    else:
        s.fail("recall reply missing the buried phrase (noisy long-content embedding suspected)", s.text_preview)
    return s


def scenario_F(ctx: HarnessContext) -> ScenarioResult:
    """Aged conversation recall — recency decay probe.

    Requires direct Mongo write to backdate a `chat_messages` row by ~75
    days. When MONGODB_URI is unreachable from the harness host (e.g. running
    from a laptop against an Atlas PrivateLink endpoint, or under a user that
    lacks write perms), the scenario is SKIPPED — not failed. That keeps the
    verdict engine from false-positive-flagging H7 (recency decay) when the
    real cause is "harness can't write to Atlas from this network".
    """
    s = ScenarioResult(id="F", title="Aged conversation recall (recency decay probe)", passed=True)
    # Prefer the public SRV URI emitted to .env.live (works from laptops).
    # Fall back to MONGODB_URI for the EC2-via-SSM path. See module header
    # for the resolution rules.
    uri = os.environ.get("MONGODB_URI_PUBLIC") or os.environ.get("MONGODB_URI", "")
    if not uri:
        s.skip("neither MONGODB_URI_PUBLIC nor MONGODB_URI set — ensure .env.docker or .env.live is present at repo root, or re-run from EC2 SSM")
        return s
    try:
        from pymongo import MongoClient  # type: ignore
        from datetime import datetime, timedelta, timezone
    except ImportError:
        s.skip("pymongo not installed locally — re-run from a host with pymongo")
        return s
    sid = f"mem-diag-{ctx.run_id}-F"
    needle = f"oldstone-meridian-{ctx.run_id}"
    # Insert a synthetic backdated chat_messages doc.
    backdate = datetime.now(timezone.utc) - timedelta(days=75)
    db_name = os.environ.get("MONGODB_DB", "")
    client_kwargs: dict[str, Any] = {"serverSelectionTimeoutMS": 5000}
    try:
        import certifi  # type: ignore
        client_kwargs["tlsCAFile"] = certifi.where()
    except ImportError:
        pass
    client = None
    try:
        client = MongoClient(uri, **client_kwargs)
        db = client[db_name] if db_name else client.get_default_database()
        # Pull a userId — we don't have a way to know jwt.sub without decoding the token.
        # Use the smoke user e2e_user; assume its sub matches a recent session.
        recent = db["chat_messages"].find_one({}, sort=[("ts", -1)])
        if not recent or not recent.get("userId"):
            s.skip("no recent chat_messages to derive userId from — seed traffic first")
            return s
        user_id = recent["userId"]
        doc = {
            "messageId": f"diag-aged-{ctx.run_id}",
            "sessionId": sid,
            "userId": user_id,
            "agentId": "product-recommendation",
            "role": "user",
            "content": f"My anniversary lighthouse codename is {needle}.",
            "timestamp": backdate.isoformat(),
            "ts": backdate,
        }
        db["chat_messages"].replace_one({"messageId": doc["messageId"]}, doc, upsert=True)
    except Exception as exc:
        s.skip(
            f"backdate row write failed ({exc.__class__.__name__}: {exc}); "
            "re-run from a host with Atlas write perms"
        )
        return s
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
    # Recall (without an embedding it won't survive vector; lexical might).
    parsed, trace = _recall(
        ctx,
        "product-recommendation",
        f"mem-diag-{ctx.run_id}-F-recall",
        "What's my anniversary lighthouse codename?",
    )
    s.text_preview = (parsed.get("text") or "")[:300]
    s.trace_id = parsed.get("trace_id", "")
    if trace:
        s.trace_summary = summarize_scoped_read(trace)
    if _needle_match(parsed.get("text", ""), [needle]):
        s.ok("aged row recalled (recency decay tolerable)")
    else:
        s.fail("aged row not recalled (probable recency-decay suppression)", s.text_preview)
    return s


def scenario_G(ctx: HarnessContext) -> ScenarioResult:
    """Fact-vs-message tie-breaker."""
    s = ScenarioResult(id="G", title="Fact-vs-message tie-breaker (weight dominance probe)", passed=True)
    sid1 = f"mem-diag-{ctx.run_id}-G-plant"
    sid2 = f"mem-diag-{ctx.run_id}-G-recall"
    needle = f"crimson-mistral-{ctx.run_id}"
    # Plant the same content in such a way that it both becomes a fact AND
    # lives in chat_messages. Stating it as a clear personal preference should
    # trigger fact extraction.
    _plant(
        ctx,
        "product-recommendation",
        sid1,
        f"Please remember about me: my project codename for upcoming work is '{needle}'.",
    )
    time.sleep(ctx.settle_seconds)
    parsed, trace = _recall(
        ctx,
        "product-recommendation",
        sid2,
        "What is the project codename I asked you to remember about my upcoming work?",
    )
    s.text_preview = (parsed.get("text") or "")[:300]
    s.trace_id = parsed.get("trace_id", "")
    if trace:
        s.trace_summary = summarize_scoped_read(trace)
    facts_in = s.trace_summary.get("facts_vector_returned", 0) + s.trace_summary.get("facts_lexical_returned", 0)
    msgs_in = s.trace_summary.get("messages_vector_returned", 0) + s.trace_summary.get("messages_lexical_returned", 0)
    s.checks.append(CheckResult("hit counts", True, f"facts={facts_in} messages={msgs_in}"))
    if _needle_match(parsed.get("text", ""), [needle]):
        s.ok("recall reply contains the codename")
    else:
        s.fail("recall reply missing the codename", s.text_preview)
    return s


# Execution order — NOT alphabetical on purpose. Scenario A uses the word
# "code" / "code I just gave you", which lexically collides with C's
# "lab notebook entry tag" recall query under BM25 + hybrid retrieval. When
# A runs before C, A's own chat-message rows (still warm in the index) get
# pulled into C's top-10 and push C's plant out. Running A LAST keeps C/D/E/G
# clean for cross-session recall tests while still exercising A in every
# sweep. Empirically validated with MEMORY_TRACE_VALUES=1 on EC2 — see the
# diagnostic notes inside scenarios C and D for the full story.
SCENARIO_ORDER: list[str] = ["B", "C", "D", "E", "G", "F", "A"]

SCENARIOS: dict[str, Any] = {
    "A": scenario_A,
    "B": scenario_B,
    "C": scenario_C,
    "D": scenario_D,
    "E": scenario_E,
    "F": scenario_F,
    "G": scenario_G,
}


# ---------------------------------------------------------------------------
# Verdict engine
# ---------------------------------------------------------------------------


def compute_verdict(audit: dict[str, Any], scenarios: list[ScenarioResult]) -> dict[str, Any]:
    """Map observations to one or more hypotheses with evidence strings."""
    matched: list[dict[str, Any]] = []

    # H1: index not READY.
    si = (audit.get("search_indexes") or {}).get("chat_messages") or {}
    if isinstance(si, dict) and "error" not in si:
        bad = [
            (name, info)
            for name, info in si.items()
            if not (isinstance(info, dict) and info.get("status") == "READY" and info.get("queryable"))
        ]
        if bad:
            matched.append({
                "id": "H1",
                "title": HYPOTHESES["H1"],
                "evidence": [
                    f"{name}: status={info.get('status')!r} queryable={info.get('queryable')}"
                    for name, info in bad
                ],
                "fix": "Re-run `bun db-seeding/seed-indexes.ts` with WAIT_FOR_ATLAS_SEARCH_INDEXES=1, or recreate in Atlas UI.",
            })

    # H2: embedding model drift.
    facts_info = audit.get("agent_memory_facts") or {}
    msgs_info = audit.get("chat_messages") or {}
    facts_models = {m["model"] for m in (facts_info.get("embedding_models") or [])}
    msgs_models = {m["model"] for m in (msgs_info.get("embedding_models") or [])}
    distinct_msgs_models = {m for m in msgs_models if m and m != "<none>"}
    if facts_models and distinct_msgs_models and not (facts_models & distinct_msgs_models):
        matched.append({
            "id": "H2",
            "title": HYPOTHESES["H2"],
            "evidence": [
                f"agent_memory_facts.embeddingModel ∈ {sorted(facts_models)}",
                f"chat_messages.embeddingModel ∈ {sorted(distinct_msgs_models)}",
            ],
            "fix": "Backfill chat_messages embeddings with the canonical provider (see db-seeding/backfill-chat-message-embeddings.ts).",
        })

    # H3: many chat_messages missing embedding.
    msg_miss = msgs_info.get("missing_pct")
    if isinstance(msg_miss, (int, float)) and msg_miss > 15.0:
        matched.append({
            "id": "H3",
            "title": HYPOTHESES["H3"],
            "evidence": [f"chat_messages missing_embedding={msg_miss}%"],
            "fix": "Backfill missing chat_messages embeddings; investigate intermittent SageMaker / Bedrock failures.",
        })

    # H6: assistant-role excluded — scenario D fails AND scenario C passes vector for user-only?
    sc_by_id = {s.id: s for s in scenarios}
    d = sc_by_id.get("D")
    if d and not d.passed and d.trace_summary.get("messages_vector_returned", 0) == 0:
        matched.append({
            "id": "H6",
            "title": HYPOTHESES["H6"],
            "evidence": ["Scenario D (assistant-recall) returned zero chat_messages hits"],
            "fix": "Verify MEMORY_INCLUDE_ASSISTANT_MESSAGES is not set to '0' / 'false' in .env.live.",
        })

    # H4: weight dominance — chat_messages content is retrieved by vector + lexical but evicted
    # from the final top-K by the RRF + MMR layer. Signal: scenario C or D failed AND chat_messages
    # returned ≥5 hits AND entry_count is at/below the post-fix MEMORY_VECTOR_TOPK default (14).
    # Diagnosed by inspecting the per-collection breakdown: the retriever found the row but the
    # final top-K was crowded out by facts (MEMORY_WEIGHT_FACTS=1.5 vs CHAT_MESSAGES=1.2 default).
    weight_evidence: list[str] = []
    for sc_id in ("C", "D"):
        sc = sc_by_id.get(sc_id)
        if not sc or sc.passed:
            continue
        msgs_hits = (sc.trace_summary.get("messages_vector_returned", 0) or 0) + (
            sc.trace_summary.get("messages_lexical_returned", 0) or 0
        )
        entry = sc.trace_summary.get("entry_count", 0) or 0
        if msgs_hits >= 5 and entry <= 12:
            weight_evidence.append(
                f"{sc_id}: msgs_hits={msgs_hits} entry={entry} "
                f"(content retrieved but evicted from top-K)"
            )
    if weight_evidence:
        matched.append({
            "id": "H4",
            "title": HYPOTHESES["H4"],
            "evidence": weight_evidence,
            "fix": (
                "Raise MEMORY_WEIGHT_CHAT_MESSAGES toward parity with facts (1.5), or raise "
                "MEMORY_VECTOR_TOPK further (16-18). Both restore chat_messages presence in "
                "the injected context. Current defaults: TOPK=14, chat_weight=1.2."
            ),
        })

    # H5: long content recall — scenario E fails but C passes.
    c = sc_by_id.get("C")
    e = sc_by_id.get("E")
    if e and not e.passed and c and c.passed:
        matched.append({
            "id": "H5",
            "title": HYPOTHESES["H5"],
            "evidence": ["Scenario E (long-content recall) FAILED while C (short-content) PASSED"],
            "fix": "Introduce chunking in session-store.ts mirrorMessageToMongo for content > ~800 chars.",
        })

    # H7: aged recall failed. SKIPPED scenarios do NOT trigger H7 — a skip
    # means the harness couldn't backdate the row at all (typically Mongo
    # write perms issue), not that recency decay actually evicted it.
    f = sc_by_id.get("F")
    if f and not f.passed and not f.skipped:
        matched.append({
            "id": "H7",
            "title": HYPOTHESES["H7"],
            "evidence": ["Scenario F (75-day-aged chat_messages row) was not recalled"],
            "fix": "Bump MEMORY_RECENCY_HALFLIFE_DAYS from 30 → 90, or set to 0 to disable decay.",
        })

    return {
        "hypotheses_matched": matched,
        # Skipped scenarios don't count as failures: re-running on a different
        # host (with proper Atlas perms) is the user-visible remediation.
        "any_failures": any((not s.passed) and (not s.skipped) for s in scenarios),
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def render_scenario_report(scenarios: list[ScenarioResult]) -> None:
    log("\n== Scenario results ==")
    for s in scenarios:
        if s.skipped:
            status = "SKIP"
        elif s.passed:
            status = "PASS"
        else:
            status = "FAIL"
        log(f"\n{s.id} {status} — {s.title}")
        if s.skipped and s.skip_reason:
            log(f"  -- skipped: {s.skip_reason}")
        for c in s.checks:
            tag = "  ok " if c.passed else "  !! "
            log(f"{tag}{c.name}{(': ' + c.detail) if c.detail else ''}")
        if s.trace_summary:
            ts = s.trace_summary
            log(
                f"  trace: mode={ts.get('mode')} entry={ts.get('entry_count')} "
                f"facts(v/l)={ts.get('facts_vector_returned')}/{ts.get('facts_lexical_returned')} "
                f"msgs(v/l)={ts.get('messages_vector_returned')}/{ts.get('messages_lexical_returned')} "
                f"embedding={ts.get('embedding_source')}:{ts.get('embedding_model')}"
            )
        if s.text_preview:
            log(f"  reply[:300]={s.text_preview!r}")


def render_verdict_report(verdict: dict[str, Any]) -> None:
    log("\n== VERDICT ==")
    if not verdict.get("hypotheses_matched"):
        if verdict.get("any_failures"):
            log("  Failures observed but no hypothesis matched cleanly.")
            log("  Re-run with --json out.json and attach the file when reporting.")
        else:
            log("  All scenarios PASSED. No hypothesis triggered.")
        return
    for h in verdict["hypotheses_matched"]:
        log(f"\n  [{h['id']}] {h['title']}")
        for ev in h.get("evidence", []):
            log(f"    evidence: {ev}")
        log(f"    fix: {h['fix']}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def to_jsonable(obj: Any) -> Any:
    if dataclasses.is_dataclass(obj):
        return {k: to_jsonable(v) for k, v in dataclasses.asdict(obj).items()}
    if isinstance(obj, dict):
        return {k: to_jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [to_jsonable(v) for v in obj]
    return obj


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scenarios",
        nargs="+",
        default=SCENARIO_ORDER,
        choices=list(SCENARIOS.keys()),
        help=(
            "Scenarios to run, in execution order. Default = SCENARIO_ORDER "
            "(B → C → D → E → G → F → A), which keeps lexically-collidey A "
            "from polluting C's top-K. Pass scenarios in any order to override."
        ),
    )
    parser.add_argument("--audit-only", action="store_true", help="Run only the Mongo audit and exit")
    parser.add_argument("--skip-audit", action="store_true", help="Skip the Mongo audit (when MONGODB_URI is unavailable)")
    parser.add_argument("--json", dest="json_out", default=None, help="Write structured result JSON to this path")
    parser.add_argument("--run-id", default=str(int(time.time())))
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help=(
            "Delete prior harness chat sessions (via DELETE /sessions) BEFORE running "
            "scenarios, and attempt to nuke harness-tagged rows in agent_memory_facts "
            "+ chat_messages when MONGODB_URI is reachable. Use for a clean re-run."
        ),
    )
    parser.add_argument(
        "--cleanup-after",
        action="store_true",
        help="Same as --cleanup but runs AFTER scenarios complete (keeps the env tidy).",
    )
    parser.add_argument(
        "--cleanup-only",
        action="store_true",
        help="Run cleanup and exit. No scenarios, no audit.",
    )
    args = parser.parse_args()

    cfg = resolve_config()

    audit: dict[str, Any] = {}
    if not args.skip_audit and not args.cleanup_only:
        audit = mongo_audit(cfg["mongodb_uri"], cfg["mongodb_db"])
        render_audit_report(audit)
    if args.audit_only:
        if args.json_out:
            Path(args.json_out).write_text(json.dumps({"audit": audit}, indent=2, default=str))
        return 0

    if not cfg["api_url"]:
        log("error: API_URL is empty (and deploy-manifest.json missing). Set API_URL or run from a deployed checkout.")
        return 2
    if not cfg["cognito_client_id"]:
        log("error: COGNITO_CLIENT_ID is empty. Set COGNITO_CLIENT_ID or restore deploy-manifest.json.")
        return 2

    log(f"\nAPI={cfg['api_url']}  user={cfg['e2e_user']}  run_id={args.run_id}")
    token = cognito_token(cfg["cognito_client_id"], cfg["aws_region"], cfg["e2e_user"], cfg["e2e_pass"])
    log(f"cognito_token_len={len(token)}")

    # Resolve userId once for facts cleanup (Cognito access tokens carry `sub`).
    user_sub: str | None = None
    try:
        # Bare-bones JWT payload decode (no signature check — we just need `sub`
        # to scope MongoDB cleanup to this harness user).
        parts = token.split(".")
        if len(parts) >= 2:
            import base64
            pad = "=" * (-len(parts[1]) % 4)
            payload = json.loads(base64.urlsafe_b64decode(parts[1] + pad))
            sub = payload.get("sub")
            if isinstance(sub, str):
                user_sub = sub
    except Exception:
        pass

    cleanup_before_report: dict[str, Any] = {}
    cleanup_after_report: dict[str, Any] = {}

    def _do_cleanup(stage: str) -> dict[str, Any]:
        log(f"\n-- Cleanup ({stage}) --")
        report = {"sessions": cleanup_harness_sessions(cfg["api_url"], token)}
        # Best-effort Mongo cleanup; gracefully degrades when Atlas is unreachable.
        report["mongo"] = cleanup_harness_facts(
            cfg["mongodb_uri"], cfg["mongodb_db"], user_id=user_sub
        )
        log(f"cleanup: mongo={report['mongo']}")
        return report

    if args.cleanup_only:
        report = _do_cleanup("only")
        if args.json_out:
            Path(args.json_out).write_text(json.dumps({"cleanup": report}, indent=2, default=str))
        return 0

    if args.cleanup:
        cleanup_before_report = _do_cleanup("before")

    ctx = HarnessContext(
        api_url=cfg["api_url"],
        token=token,
        run_id=args.run_id,
        settle_seconds=cfg["settle_seconds"],
        trace_wait_seconds=cfg["trace_wait_seconds"],
        trace_retries=cfg["trace_retries"],
    )

    results: list[ScenarioResult] = []
    for sid in args.scenarios:
        log(f"\n-- Scenario {sid} --")
        try:
            results.append(SCENARIOS[sid](ctx))
        except SystemExit:
            raise
        except Exception as exc:
            sr = ScenarioResult(id=sid, title="(crashed)", passed=False)
            sr.fail("scenario crashed", f"{exc.__class__.__name__}: {exc}")
            results.append(sr)

    render_scenario_report(results)
    verdict = compute_verdict(audit, results)
    render_verdict_report(verdict)

    if args.cleanup_after:
        cleanup_after_report = _do_cleanup("after")

    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps(
                {
                    "run_id": args.run_id,
                    "config": {k: v for k, v in cfg.items() if k not in ("e2e_pass",)},
                    "audit": audit,
                    "scenarios": [to_jsonable(r) for r in results],
                    "verdict": verdict,
                    "cleanup_before": cleanup_before_report,
                    "cleanup_after": cleanup_after_report,
                },
                indent=2,
                default=str,
            )
        )

    return 0 if not verdict.get("any_failures") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("\nInterrupted.")
        raise SystemExit(130)
