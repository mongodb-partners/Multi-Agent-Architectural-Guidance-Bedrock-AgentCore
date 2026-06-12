# Smoke Tests — Reference

Live post-deploy verification scripts under [`e2e-smoke/`](../../e2e-smoke/). All scripts target an **already deployed** stack and read configuration from `deploy-manifest.json` (set `DEPLOY_MANIFEST_PATH` to override) and `.env.live`. They are the canonical "did the deploy actually work?" gate.

Pre-flight:

```bash
source .env                                           # AWS creds + region
python3 -m pip install -r requirements.txt            # if requirements.txt present per script
```

Most scripts also work with the Cognito test user provisioned by `modules/cognito` — defaults `E2E_USER=alex@example.com`, `E2E_PASS=DemoUser#2026`. Override per script if you rotated the test user.

---

## 1. Post-deploy smoke (`post-deploy-smoke.py`)

The canonical end-to-end gate after `./deploy/deploy-full-with-privatelink.sh` or `./deploy/deploy-full-with-vpc-peering.sh`. **`deploy-project.sh` Phase 11 runs this automatically** after writing `deploy-manifest.json` (unless `--skip-smoke`). Phases 9a–9b still run the faster deterministic `backend-smoke.py` gate first.

```bash
# Manual re-run (same checks as deploy Phase 11):
source .env && python3 e2e-smoke/post-deploy-smoke.py
```

Checks:

- `/health` for MongoDB, long-term memory, AgentCore Memory, MCP runtime (via Gateway), and (when `bedrock_kb_id` is in the manifest) Bedrock KB retrieve. `mcpServer=unreachable` is downgraded to a warning because the API only opens the Gateway connection lazily on the first JWT-scoped chat turn (see `docs/status/debugging.md` "MongoDB MCP prewarm singleton race").
- `/agents` metadata against the four configured agents.
- `deploy-manifest.json` aligns with the env (`embeddings_provider`, Voyage Marketplace ARN, default model).
- SageMaker endpoint `InService` when `EMBEDDINGS_PROVIDER=voyage`.
- Terraform outputs for Voyage endpoint + Bedrock KB connectivity.
- Bedrock KB in `ACTIVE` state with the correct Atlas endpoint service and a latest ingestion job that scanned exactly the local `deploy/kb-docs/*.txt` source count with `0` failures.
- **AgentCore Runtime env wiring** — every runtime (orchestrator + 3 specialists) has its full env set (≥ 18 vars on specialists, ≥ 22 on orchestrator). Catches the post-apply env-drift class permanently. See `docs/status/debugging.md` "AgentCore Runtime env vars get reset…".
- **Authenticated `/chat` flows** for `orchestrator`, `order-management`, `product-recommendation`, `troubleshooting`. Each turn must yield `token`, `done`, **no `stream_error`**, a `trace_id`, and either a `trace` event or a `handoff`. `product-recommendation` must also emit a real `mongo.vector_search` trace event; `troubleshooting` and `orchestrator` must emit `tool.mcp` (proves the AgentCore Gateway → MongoDB MCP path is live, with `_meta` passthrough working).
- **LTM cross-session recall** — plant turn writes a uniquely-tokened fact (e.g. `HELIOTROPE-LANTERN`), a second session in a fresh chat must surface that token. Verifies `agent_memory_facts` write + hybrid retrieval end-to-end.
- **CloudWatch trace_id join** — picks the live `x-trace-id` from the smoke chat and confirms `/multiagent/<env>/api` log streams contain ≥ 1 matching event in the smoke window. Validates `_trace` propagation from API → CloudWatch (the parallel scan against `/aws/bedrock-agentcore/runtimes/*` log groups is best-effort and warns rather than fails when AgentCore-side propagation is still in progress).
- **CloudWatch retention** — confirms shared log groups keep the expected retention split: API 30 days; UI, MCP, and shared AgentCore 7 days.
- The Phase 9b deterministic backend smoke (`deploy/scripts/backend-smoke.py`, invoked by `deploy-project.sh`) wraps two chat turns in a **3-attempt retry with 15s × attempt back-off** so a freshly-restarted API container doesn't fail the gate on cold-start latency.

Useful overrides:

| Variable | Effect |
|---|---|
| `DEPLOY_MANIFEST_PATH` | Override manifest location |
| `SKIP_TERRAFORM_CHECKS=1` | Skip the local `terraform output` reads (useful in CI without state access) |
| `SKIP_CHAT_CHECKS=1` | Skip authenticated `/chat` runs |
| `SKIP_LTM_CHECK=1` | Skip the long-term memory recall sub-test |
| `E2E_USER`, `E2E_PASS` | Cognito creds |

The runtime env wiring assertion and CloudWatch trace_id join intentionally have **no skip flags** — they're the cheapest checks to run and they catch the env-drift + trace-propagation classes that have repeatedly slipped past the chat-only smoke.

Exit code 0 = pass; non-zero = blocking failure. The terminal sentinel for a clean pass is `ALL_POST_DEPLOY_SMOKE_CHECKS_PASSED`.

---

## 2. Deep shell smoke (`e2e-smoke.sh`)

Older, more granular shell-driven smoke. Useful when isolating which sub-system is broken without the Python harness's grouping.

```bash
bash e2e-smoke/e2e-smoke.sh
```

Covers:

1. `/health` per-dependency (`mongodb`, `longTermMemory`, `agentcore`, `mcpServer`, optional `bedrockKnowledgeBase`).
2. Cognito JWT obtain for `alex@example.com`.
3. **Product recommendation** chat — asserts `mongodb_vector_search` fires via Voyage.
4. **Troubleshooting** chat — asserts `mongodb_vector_search` + optional `bedrock_kb_retrieve`.
5. **Order management** chat — asserts the `mongodb_query` path (no embedding).
6. **Long-term memory** — turn 1 sets a fact, turn 2 in a fresh session recalls it.
7. **Trace assertions** — `mongo.vector_search` events have the expected payload shape.

Set `RUN_LTM_DEEP=1` to chain the focused LTM hybrid suite afterwards.

---

## 3. Long-term memory vector smoke (`ltm/ltm-smoke.sh`)

Targeted at the hybrid retriever — writes fresh memory, recalls it across sessions, fetches persisted traces, and **fails unless both `agent_memory_facts` AND `chat_messages` participate in retrieval**. Source of truth for the "did hybrid actually work?" gate.

```bash
bash e2e-smoke/ltm/ltm-smoke.sh
```

See [`e2e-smoke/ltm/README.md`](../../e2e-smoke/ltm/README.md) for the per-scenario assertion list.

---

## 4. Memory recall diagnostic (`memory-recall-diagnostic.py`)

Diagnostic harness for "why is recall under-performing?" Maps observed retrieval metadata to one of seven hypotheses (`H1` index status → `H7` recency decay).

```bash
python3 e2e-smoke/memory-recall-diagnostic.py            # full run
python3 e2e-smoke/memory-recall-diagnostic.py --audit    # mongo audit only
python3 e2e-smoke/memory-recall-diagnostic.py --scenarios A B C
python3 e2e-smoke/memory-recall-diagnostic.py --json out/diag.json
python3 e2e-smoke/memory-recall-diagnostic.py --cleanup --cleanup-after  # clean re-run
```

Runs seven scenarios (B → C → D → E → G → F → A — A last on purpose to avoid lexical collision with C's notebook-tag recall). Pins `MEMORY_VECTOR_TOPK=14`, `MEMORY_WEIGHT_FACTS=1.5`, `MEMORY_WEIGHT_CHAT_MESSAGES=1.2`.

Auto-loads `.env.live` and **prefers `MONGODB_URI_PUBLIC`** (public SRV) over `MONGODB_URI` (PrivateLink direct) so scenarios C/F (which write to `chat_messages` from a laptop or backdate `ts` for H7) work without an SSM-into-EC2 hop.

Exit 0 = every required scenario passes; non-zero = the verdict report names the failing hypothesis.

---

## 5. Trace shape verifier (`verify-trace-ui-shape.py`)

Tier-2 verification for the debug-grade LTM trace section. Runs a plant turn + a recall turn and asserts the persisted trace contains the field shape consumed by `ui/lib/developer_trace_view.py`'s `_render_memory_write` / `_render_memory_read`.

```bash
python3 e2e-smoke/verify-trace-ui-shape.py
```

Exits non-zero if the UI would render a blank card because of a backend regression.

---

## 6. Bedrock + AgentCore live audit (`bedrock-resource-live-audit.py`)

Combined live + static audit for the four Bedrock/AgentCore Terraform resources (KB, AgentCore Memory, AgentCore Gateway, AgentCore Runtime).

```bash
python3 e2e-smoke/bedrock-resource-live-audit.py
python3 e2e-smoke/bedrock-resource-live-audit.py --manifest deploy-manifest.json
SKIP_LIVE_CHECKS=1 python3 e2e-smoke/bedrock-resource-live-audit.py   # static only
```

Validates that each resource exists in AWS (not just in Terraform code), is in `ACTIVE`/`READY` state, and carries the expected associations (data sources, memory link, gateway targets).

---

## 7. Failure drills (`failure-drills/`)

Live, non-destructive failure-mode exercises against an already deployed stack. Each script restores state in a `finally` block.

```bash
python3 e2e-smoke/failure-drills/run_all.py
python3 e2e-smoke/failure-drills/run_all.py --skip-disruptive
```

| Script | What it does |
|---|---|
| `auth_edge_cases.py` | Missing / malformed / fake / empty / cross-user Bearer tokens |
| `force_alarm_states.py` | Forces every project alarm into a chosen state (default `ALARM`) and verifies the transition; resets to `OK` |
| `bedrock_throttling_alarm.py` | Validates the throttling alarm path **without** intentionally exhausting Bedrock quotas |
| `mongo_outage.py` | Temporarily breaks `MONGODB_URI` on EC2, verifies `/health` degrades, restores `.env.live`, restarts API |
| `agentcore_failure.py` | Temporarily points a specialist runtime ARN at a non-existent runtime, verifies `AGENTCORE_RUNTIME_ERROR`, restores, restarts |
| `api_rollback.py` | Retags ECR `latest` to the previous API image, restarts, verifies `/health`, retags back |

`run_all.py` resets all project alarms to `OK` after the suite. The outage and rollback drills have their own `finally` restore paths.

---

## 8. Security + scoping audits

```bash
bash e2e-smoke/security-audit-test.sh
bash e2e-smoke/userId-scoping-audit-test.sh
```

These shell scripts exercise:

- **`security-audit-test.sh`** — token enforcement, JWKS rotation, the SSRF guard on HTTP tools, MCP write-gate (`MONGODB_ALLOW_WRITE`), redaction in MCP logs (`MCP_LOG_RAW_ARGS`).
- **`userId-scoping-audit-test.sh`** — cross-user session access denial, `GET /sessions` filtering by JWT `sub`, `DELETE /sessions/:id` ownership enforcement, `chat_messages` cascade delete.

---

## 9. Internal helpers (`_*_ec2.py`)

Not run directly; they are uploaded onto the EC2 host via SSM and executed there by the harnesses above. They live next to the harness for transparency:

- `_mongo_audit_ec2.py` — Atlas index + vector probe from inside the VPC (used by `memory-recall-diagnostic.py --audit`).
- `_mongo_backdate_f_ec2.py` — backdates `ts` on scenario F's chat message to validate `H7` recency decay.
- `_mongo_cleanup_ec2.py` — purge harness-tagged rows after a `--cleanup` run.
- `_vector_probe_ec2.py` — direct `$vectorSearch` against Atlas to verify the vector index is queryable independent of the API path.

---

## 10. `get_token.py` — quick auth helper

```bash
python3 e2e-smoke/get_token.py                # prints a fresh access token
TOKEN=$(python3 e2e-smoke/get_token.py)
curl -H "Authorization: Bearer $TOKEN" "$API_URL/health"
```

Reads Cognito app id + creds from `.env.live` / env overrides. Convenient when scripting one-off API checks from a laptop.

---

## Recommended order after a deploy

1. `python3 e2e-smoke/post-deploy-smoke.py` (gate).
2. `bash e2e-smoke/e2e-smoke.sh` (granular when (1) fails).
3. `bash e2e-smoke/ltm/ltm-smoke.sh` (memory).
4. `python3 e2e-smoke/verify-trace-ui-shape.py` (UI debug surface).
5. `python3 e2e-smoke/failure-drills/run_all.py --skip-disruptive` (alarms / auth).

Run the disruptive failure drills (`mongo_outage`, `agentcore_failure`, `api_rollback`) explicitly when validating runbooks — not on every deploy.

---

*Last verified: 2026-05-23 against the script set in `e2e-smoke/` and `e2e-smoke/failure-drills/` (full deploy + post-deploy smoke green end-to-end on PrivateLink stack).*
