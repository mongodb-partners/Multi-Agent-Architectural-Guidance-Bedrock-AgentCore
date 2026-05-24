# Developer Debugging Playbook

A developer- and SRE-oriented guide for diagnosing problems in the deployed stack. The reading order is shallowest → deepest: get a shell, tail logs, then move into trace-driven debugging.

> When the symptom is "deploy refused to start", read [`deployment-guide.md`](../deployment-guide.md) first — most boot failures are surfaced by `assertJwksAuthConfigured()` / `assertAgentcoreOrchestratorArn()` / `assertShortTermBackendConfigured()` / `assertEmbeddingsProvider()` and the message points directly at the missing env var.

## 1. Where state lives

| Layer | Where | How to access |
|---|---|---|
| EC2 host filesystem | `/opt/multiagent/` | `aws ssm start-session --target <instance-id>` |
| API + UI + ADOT systemd units | `journalctl -u multiagent-api / -u multiagent-ui / -u multiagent-adot` | Via SSM session or `aws ssm send-command` |
| Runtime env file | `/opt/multiagent/.env.live` | Rewritten by `deploy-api.sh`; **do not hand-edit** |
| API + UI logs | CloudWatch `/<SHARED_RESOURCE_PREFIX>/<env>/{api,ui}` | CloudWatch Logs Insights (queries in [`observability-runbook.md`](../observability-runbook.md)) |
| AgentCore Runtime logs | CloudWatch `/<SHARED_RESOURCE_PREFIX>/<env>/agentcore` and `/aws/bedrock/agentcore/runtime/<runtime-id>` | CloudWatch Logs Insights |
| Bedrock invocation logs | `/aws/bedrock/invocations` (+ `-audit`) | Bedrock model usage + per-user cost dashboard |
| OTel collector logs | `/<SHARED_RESOURCE_PREFIX>/<env>/otel` | Atlas Prometheus metrics ship to `otel-atlas` |
| MongoDB Atlas | `MONGODB_URI` (PrivateLink or peering URI in `.env.live`; public SRV via `MONGODB_URI_PUBLIC` only for off-VPC tooling) | `mongosh` from EC2; or harness via `MONGODB_URI_PUBLIC` |
| AgentCore Memory Store | AgentCore Memory id from TF outputs | `aws bedrock-agentcore-control list-events --memory-id …` |
| Cross-stack SSM | `/<SHARED_VPC_NAME>/<region>/…` | `aws ssm get-parameters-by-path` — see [`reference/ssm-parameters.md`](../reference/ssm-parameters.md) |
| ECR repos | `<account>.dkr.ecr.<region>.amazonaws.com/<project>-{api,ui}-<env>` | `aws ecr list-images` |
| Trace docs | Mongo `traces` collection (TTL `TRACE_TTL_DAYS=30`) + in-process ring buffer | `GET /traces/:id`, `GET /trace`, `GET /trace/mongo` |

## 2. Get a shell on EC2 (no SSH needed)

```bash
# Discover the instance id from deploy-manifest.json
INSTANCE_ID=$(jq -r '.ec2.instance_id' deploy-manifest.json)
aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
```

If SSM isn't returning the instance, check that the EC2 role has `AmazonSSMManagedInstanceCore` and the agent is running:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID"
```

Common follow-on commands (run inside the session):

```bash
sudo systemctl status multiagent-api multiagent-ui multiagent-adot mongodb-mcp
sudo journalctl -u multiagent-api -n 200 --no-pager
sudo cat /opt/multiagent/.env.live | head -40
docker ps
docker logs --tail 200 multiagent-api
```

## 3. Tail logs without a shell

Use `aws ssm send-command` to run `journalctl` and stream the result back without opening a session.

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "tail api" \
  --parameters 'commands=["journalctl -u multiagent-api -n 500 --no-pager"]'
# wait ~5s then:
aws ssm list-command-invocations --command-id <id> --details \
  --query 'CommandInvocations[].CommandPlugins[].Output' --output text
```

Or jump straight into CloudWatch Logs Insights — the canonical queries live in [`observability-runbook.md`](../observability-runbook.md). The most useful for live debug:

```
fields @timestamp, level, msg, sessionId, traceId, agentId, error
| filter level in ["error", "warn"]
| sort @timestamp desc
| limit 100
```

## 4. Trace-driven debugging

Every chat turn returns an `X-Trace-Id` HTTP header. Capture it (or read it off the SSE summary) and feed it to the Streamlit Trace Viewer (page **2 Trace Viewer**) or the API:

```bash
TRACE_ID=...
curl -H "Authorization: Bearer $TOKEN" "$API_URL/traces/$TRACE_ID?include=dev" | jq .
```

Projections:

- `?include=core` — UI default. Lite event set with heavy fields replaced by `{ _omittedForCoreMode: true, bytesAvailable: N }` sentinels.
- `?include=dev` — fetched on "Show developer details". Includes `release`, `correlation`, `otel`, `spanTree`, debug-only event types, raw payloads (subject to redaction gates).
- `?include=full` — every event, no projection. Reserved for support; SOC2 audit channel logs `[trace] fetch` with the `include` field.

The `X-Trace-Include` response header echoes the projection; `ui/lib/api_client.py:get_trace` asserts the header matches so routing regressions surface as UI test failures rather than silently downgraded data.

**What's in a trace:**
- `chat.turn.start/end` — wall clock, model usage cost rollup.
- `prompt.assembled` — system prompt assembly (`body` only when `TRACE_PROMPT_BODY=1`).
- `model.request / model.text_delta_batch / model.usage / model.stop / model.retry` — Bedrock invocation + token usage.
- `tool.call` — Strands tool calls (`tool.call.input`/`result` capped at 64 KB).
- `mongo.intent / mongo.query / mongo.result / mongo.vector_search` — MCP tool execution. The `documentPreviews[]` is the user-visible source-preview contract surfaced by `inline_summary.py`.
- `agentcore.invoke / agentcore.classification / agentcore.nested_trace / agentcore.retry` — runtime forwarding.
- `handoff.decision` — classifier or orchestrator handoff with the preceding pending-text snapshot.
- `memory.scoped_read / memory.shared_read / memory.long_term_write / memory.long_term_skip` — LTM read/write (raw values only when `MEMORY_TRACE_VALUES=1`).
- `latency.checkpoint` — per-leg timings (auth, classify, runtime invoke, mongo, model).
- `dev.byte_cap_hit` — emitted (max 50/turn) when a payload exceeded a per-event / per-turn byte cap.
- `error` — any thrown error in the chat pipeline.

Byte caps (read once per turn from env):

- Default per-event cap: **16 KB** (`TRACE_MAX_EVENT_BYTES`).
- Debug-field cap (prompt body, `agentcore.invoke.payload`, `tool.call.input`, …): **64 KB** (the per-event-type table in `trace-collector.ts`).
- Per-turn cap: **2 MB** (`TRACE_MAX_TURN_BYTES`).

When the per-turn cap is exceeded, low-priority events are dropped first; protected types (`chat.turn.start/end`, `handoff.decision`, `model.usage`, `model.stop`, `agentcore.invoke`, `agentcore.classification`, `agentcore.nested_trace`, `latency.checkpoint`, `error`, `tool.call`, `mongo.*`) are retained.

## 5. Common failures and fixes

> **Pre-deploy guards.** Most of the failure modes in this section also have a corresponding pre/post-apply guard in [`deploy/scripts/_preflight-checks.sh`](../../deploy/scripts/_preflight-checks.sh). When you hit one of them inside a deploy, the failure envelope already names the matching `pf_check_*` and an anchor in [`deployment-preflight-checks.md`](../deployment-preflight-checks.md). Override knobs (`PREFLIGHT_SKIP=<id>`, `PREFLIGHT_JSON=1`, `PREFLIGHT_DRY_RUN=1`) are documented there.

### "API refuses to boot"
- `AGENTCORE_ORCHESTRATOR_ARN must be set` → run `deploy-agents.sh` (or `deploy-project.sh`) so the ARN is injected into `.env.live`.
- `AUTH_JWKS_URI / AUTH_ISSUER must be set` → run `deploy-project.sh`; both come from `module.cognito` outputs. No bypass.
- `EMBEDDINGS_PROVIDER must be voyage or titan` → set in `.env`, re-run `deploy-api.sh`.
- `SHORT_TERM_MEMORY_BACKEND=agentcore requires AGENTCORE_MEMORY_STORE_ID` → unset `SHORT_TERM_MEMORY_BACKEND` to fall back to in-memory `Map`, or run `deploy-project.sh` to provision AgentCore Memory.

### `/chat` returns `event: error` with `INVALID_TOKEN`
JWT verification failed. Check:

- Token is not expired (`exp` claim).
- Token issuer matches `AUTH_ISSUER` (Cognito hosted UI returns ID tokens by default — set `AUTH_TOKEN_USE=id` if you switched to ID tokens explicitly).
- JWKS endpoint is reachable from EC2 (`curl -sS $AUTH_JWKS_URI`).

### `/chat` SSE looks fluent but the assistant narrates "I'd like to query the database…" with `toolCalls: 0`
The MongoDB tool path is broken. Walk the four-place checklist:

1. **`userJwt` not scoped in the runtime container** — `agent-runtime-code.ts` must wrap the agent run in `withGatewayJwt(userJwt, …)`. Pinned by `tests/unit/agent-construction-invariants.test.ts`.
2. **MCP tool name aliasing** — Gateway publishes `mongodb-mcp___<tool>`; the API wraps each in `AliasedMcpTool` so the LLM sees `mongodb_query`. Pinned by `tests/unit/mongodb-mcp-tool-alias.test.ts`. Coupled to `target_name = "mongodb-mcp"` in `modules/agentcore-gateway/main.tf`.
3. **Agent constructed without MCP tools** — every `new Agent(…)` site must `await getMcpTools()` and spread it into `tools`. Pinned by `agent-construction-invariants.test.ts` (deny-list).
4. **Lambda envelope mismatch** (only when running through a Lambda target — not the default path) — `parseEvent` must accept lowercase `context.clientContext.custom.bedrockAgentCoreToolName`, not just uppercase `Custom`. Pinned by `tests/unit/lambda-parse-event.test.ts`.

The deploy-time smoke (`deploy-project.sh` Phase 9, `e2e-smoke/e2e-smoke.sh`) asserts `mongodb_query` actually returned the seed order — a SSE-event-presence-only smoke would pass on all four failure modes.

### Bedrock KB ingestion fails every doc with `Write failure with error code -3`
Looks like a network/PrivateLink issue, **is** a Mongo `E11000 duplicate key error on { docId: null }` masked by the Bedrock connector. The fix lives in [`db-seeding/seed-indexes.ts`](../../db-seeding/seed-indexes.ts) — `troubleshooting_docs.docId` must be a **partial-unique** index scoped to `{ docId: { $exists: true, $type: "string" } }`. The seeder also includes an `IndexOptionsConflict` heal path that drops + recreates a stale plain-unique `docId_1`.

To confirm: enable Bedrock KB `APPLICATION_LOGS` (`aws logs put-delivery-source --resource-arn <kb-arn> --log-type APPLICATION_LOGS …`) and grep `status_reasons` for the driver error before chasing PrivateLink.

### Voyage embeddings degraded to Titan ("the catalog appears empty" / scores ~0.5)
Four surfaces must line up:

1. **EC2 API** `.env.live` has `VOYAGE_SAGEMAKER_ENDPOINT` set.
2. **AgentCore Runtime env vars** also have `VOYAGE_SAGEMAKER_ENDPOINT` — written by `deploy-agents.sh` Phase 8 via `aws bedrock-agentcore-control update-agent-runtime`.
3. **Runtime IAM role** grants `sagemaker:InvokeEndpoint` on the endpoint ARN — wired by the `voyage_sagemaker_endpoint_arn` input in `modules/agentcore-agent-runtime`. Without it the runtime gets `AccessDenied` and `embedQueryText` silently falls back to Bedrock Titan (visible in traces as `embeddingSource: "bedrock"`).
4. **Vector index dimensions** match the request `output_dimension`. SoW pins `voyage-multimodal-3` at 1024-d; index must be 1024-d. When changing provider/dim, re-seed with `REWIRE_EMBEDDINGS=1`.

Regression check: against the `product-recommendation` agent, send "I need waterproof outdoor headphones, IP67, under $80" and look for `mongo.vector_search` events with `embeddingSource: "voyage"`, `length: 1024`, top scores in `0.7–0.8`.

### `memory.long_term_skip` with `reason: "llm_extractor_failed"`
Bedrock model access denied for the fact-extractor model. The default is `us.anthropic.claude-haiku-4-5-20251001-v1:0` (CRI form). On freshly granted accounts, the older `claude-3-5-haiku-20241022` is deprecated and ticking it in the Bedrock console does not actually grant access. Set `MEMORY_EXTRACTION_MODEL_ID` on the API process (not the runtime — the extractor runs in the API container) to a model that is enabled and supports tool use.

### `gen_ai.*` spans missing from `aws/spans` (CloudWatch GenAI Observability "Agents" tab empty)
OTel peer-dep drift. Strands TS SDK 0.7 pins `@opentelemetry/{sdk-trace-*,resources}` on the **1.30.x** line and exporters on `^0.57.x`. When `api/package.json` strays outside that range, npm/bun installs two copies of `sdk-trace-base` (one nested under `node_modules/@strands-agents/sdk/node_modules/`) and our `initOtel()` only binds the top-level provider; Strands' shadow provider stays Noop.

Run `bun run validate:strands-otel` to catch full-Noop globals. Dual-provider drift (top-level real, Strands shadow-Noop) is not caught by the validator — check `ls node_modules/@strands-agents/sdk/node_modules/@opentelemetry` exists; if it does, downgrade until it disappears. See [`AGENTS.md § Strands / Bedrock touchpoints`](../../AGENTS.md) for the dep matrix.

### CloudWatch fleet dashboard widgets empty / alarms in `INSUFFICIENT_DATA`
The Phase 3 dashboards depend on the API's EMF emitter writing to stdout. Check `METRICS_EMITTER_ENABLED` (default `true`) — it's set to `0` in CI to silence noise; the same value can accidentally land in `.env.live` after a wrongly-merged env file. Restart the API after fixing.

### Network mode mismatch — `envs/ec2` `check` block fails
The `envs/ec2` `check "network_mode_matches_shared"` block compares its `var.network_mode` against the SSM `/network_mode` canary. If they disagree, the plan fails before resources change. Either:

- Re-run the matching orchestrator (`deploy-full-with-privatelink.sh` or `deploy-full-with-vpc-peering.sh`) — they export `NETWORK_MODE` correctly.
- Or run `deploy-network.sh --allow-mode-switch` after destroying every per-project EC2 env.

### CIDR overlap — `envs/network` `check "peering_cidr_non_overlap"` fails
`ATLAS_PEERING_CIDR` (default `192.168.248.0/21`) overlaps `VPC_CIDR` (default `10.0.0.0/16`) — shouldn't happen with defaults, but custom CIDRs trigger this. The Python CIDR pre-flight in `deploy-network.sh` and the TF check both refuse to proceed. Change `ATLAS_PEERING_CIDR` (or `VPC_CIDR`) so they do not overlap, then re-run.

### `mongodb_*` tool calls silently return 0 docs in peering mode
The peering mode wires `MONGODB_URI` from `module.mongodb_atlas.peering_connection_string`. If the Atlas mongod IPs change (cluster scale, version upgrade, region restart), the peering NLB target group drifts. Symptom: tool calls succeed but return empty; CloudWatch shows no connection errors. Recovery:

```bash
./deploy/deploy-full-with-vpc-peering.sh --skip-network --skip-shared --auto-approve
```

This re-runs `envs/ec2`, which re-`dig`s the SRV and re-pins the NLB targets.

### `bedrock-kb-peering` TLS failure
The peering KB path is **EXPERIMENTAL** and not partner-validated. If KB ingestion fails with TLS errors, the only remediations are:

- Destroy + redeploy in PrivateLink mode (recommended).
- Set `TF_VAR_enable_kb_peering=false` and re-apply. KB ingestion falls back to public Atlas SRV — **this is a privacy regression** (KB traffic leaves the private fabric; TLS + Atlas auth still apply). Document the deviation.

### SSM canary missing on `deploy-shared.sh` (`cw_api_log_group` not found)
`deploy-shared.sh` reads its own canary `/<SHARED_VPC_NAME>/<region>/cw_api_log_group`. If the parameter exists but the value is `_empty_`, the shared stack ran but Bedrock invocation logging was disabled. If the parameter doesn't exist at all, the shared stack has never applied — run `deploy-shared.sh`.

### Trace UI shows `_omittedForCoreMode` instead of payload
Expected for `core` mode (UI default). Click **Show developer details** in the Trace Viewer to fetch `?include=dev`. If the dev view also shows the sentinel, the payload exceeded the per-event byte cap — look for a `dev.byte_cap_hit` event in the same trace.

## 6. Memory debugging

The `memory-recall-diagnostic.py` harness exercises seven scenarios and maps observed retrieval metadata to one of seven hypotheses (`H1` index status → `H7` recency decay).

```bash
source .env
python3 e2e-smoke/memory-recall-diagnostic.py
python3 e2e-smoke/memory-recall-diagnostic.py --audit              # mongo audit only
python3 e2e-smoke/memory-recall-diagnostic.py --scenarios B C D
python3 e2e-smoke/memory-recall-diagnostic.py --cleanup --cleanup-after
```

Scenarios run in `B → C → D → E → G → F → A` order — A last because its "what was the code I just gave you" recall lexically collides with C's notebook-tag recall. Pins `MEMORY_VECTOR_TOPK=14`, `MEMORY_WEIGHT_FACTS=1.5`, `MEMORY_WEIGHT_CHAT_MESSAGES=1.2`.

Reads each scenario's persisted `memory.scoped_read` event for retrieval metadata. The harness prefers `MONGODB_URI_PUBLIC` over `MONGODB_URI` so scenarios C/F (which write to `chat_messages` / backdate `ts` to validate H7) work from a laptop without an SSM-into-EC2 step.

The seven hypotheses (see source for the full mapping):

| Hyp | Signal | First check |
|---|---|---|
| H1 | Index status | `bun db-seeding/seed-indexes.ts` + Atlas Search index status `READY` |
| H2 | Embedding provider drift | Trace `embeddingSource: "voyage" \| "bedrock"`; should not flap mid-session |
| H3 | Missing vectors on `chat_messages` | Mongo query for `embedding: { $exists: false }` in the harness session |
| H4 | Weight dominance | `MEMORY_WEIGHT_CHAT_MESSAGES` vs `MEMORY_WEIGHT_FACTS` — defaults 1.2/1.5 |
| H5 | Noisy long content | Chat message > 4 KB — see `MEMORY_TRACE_VALUES` redaction interplay |
| H6 | Role filter mismatch | `MEMORY_INCLUDE_ASSISTANT_MESSAGES=false` excludes assistant turns |
| H7 | Recency decay | `MEMORY_RECENCY_HALFLIFE_DAYS=90` (default) — very old backdated rows may still decay below recall threshold; set `0` to disable |

## 7. Auth debugging

```bash
# /health is public (no Bearer required)
curl -sS "$API_URL/health" | jq .

# Issue a fresh access token from a Cognito test user (for protected routes)
TOKEN=$(python3 e2e-smoke/get_token.py)
```

### `/health` dependency fields

`GET /health` returns only **probed** integrations. It does not report short-term memory backend (`SHORT_TERM_MEMORY_BACKEND`) or MCP hosting mode.

| Field | Green (`connected`) | Common false alarms |
|---|---|---|
| `mongodb` | Atlas ping via `MONGODB_URI` | `unreachable` → PrivateLink/URI wrong on EC2; `not_configured` → no URI |
| `longTermMemory` | Mongo up + ≥1 agent with `memory.longTerm: true` | `no_agents` → enable LTM on an `.agent.md`; `not_configured` → no Mongo URI |
| `agentcore` | Memory store reachable (`ListSessions` probe) | `inactive` → memory id in env but store not `ACTIVE`/`DELETING`; `unreachable` → IAM or wrong `AGENTCORE_MEMORY_STORE_ID` |
| `mcpServer` | MCP connect + `listTools` | `unreachable` → VPC endpoints, runtime ARN, or cold-start > 2.5s |
| `bedrockKnowledgeBase` | `BEDROCK_KB_ID` set + `Retrieve` ok | `not_configured` → env unset; `unreachable` → IAM or KB not ready (grep `[health] bedrock KB probe` in API logs) |

Top-level `status: degraded` (HTTP 503) is set only when `mongodb` is `unreachable`. Other fields can be yellow on a still-live API.

```bash
# Validate the JWT locally
python3 -c "import json, base64, sys; t=sys.argv[1]; p=t.split('.')[1]+'==='; print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))" "$TOKEN"
```

`GET /health` does not require auth. When **protected** routes return `401`:

- Confirm `AUTH_JWKS_URI` is reachable from EC2.
- Confirm `AUTH_ISSUER` matches `iss` claim exactly (trailing slash matters).
- Confirm `AUTH_APP_CLIENT_ID` matches `aud` / `client_id` (one or the other depending on Cognito access vs ID token).

`auth_edge_cases.py` (in `e2e-smoke/failure-drills/`) covers missing, malformed, fake, empty, expired, and cross-user tokens.

## 8. Tool execution

- **MCP `mongo.*` events** — every Mongo tool call emits `mongo.intent` (the planning step), `mongo.query` (the wire), and `mongo.result` (rows-returned via `mongo.result.docCount`). When the count is `0` and you expected hits, check the `embeddingSource` + `length` on the matching `mongo.vector_search` first.
- **HTTP tools SSRF guard** — skill-scoped `http-tools.json` files declare `security.allowedHosts`. The runtime refuses requests outside the allow-list. The global config is `config/http-tools.json` with an account-wide host allowlist.
- **Skill `scripts/*.mjs` dynamic import** — the `run_skill_script` tool dynamically imports `.mjs` modules in `config/skills/<name>/scripts/` at call time. **Treat skill scripts as trusted code.** Keep them pure (no network, no filesystem) unless explicitly designed otherwise.
- **`read_skill_resource` activation gate** — `skillName` must be in the agent's `.agent.md` `skills:` list AND the skill must be activated (`activate_skill` or specialist `preActivateSkills`). Errors: `skill_not_allowed_for_agent`, `skill_not_activated`.

## 9. Validation scripts

Run before merging any change that touches model invocation, OTel, Bun compatibility, or AgentCore Memory wiring.

| Command | What it checks |
|---|---|
| `cd api && bun run typecheck` | TypeScript strict |
| `cd api && bun run test` | Unit tests in `tests/unit/` |
| `cd api && bun run test:integration` | Integration tests (real backends behind flags) |
| `cd api && bun run validate:bun` | Bun + Node 22 compat smoke (top-level `await`, fetch streaming, AsyncLocalStorage) |
| `cd api && bun run validate:agentcore` | AgentCore Memory contract — `CreateEvent` / `ListEvents` shape matches the SDK version pinned in `package.json` |
| `cd api && bun run validate:strands-otel` | Strands TS SDK ↔ OTel SDK version drift — `ProxyTracerProvider → NodeTracerProvider OK`, emitted `gen_ai.*` span lands |
| `cd api && bun run validate:strands-retries` | `AfterModelCallEvent.retry` surface still exported (catches Strands SDK bumps that break `TracingRetryStrategy`) |
| `cd api && bun run bench:ttfb` | TTFB benchmark against the stub server (catches regressions in the SSE pipeline) |

`bun run typecheck` is also part of the GitHub Actions `ci.yml` workflow — see [`docs/deployment-guide.md § CI/CD`](../deployment-guide.md).

## 10. Known persistent pitfalls

These are non-obvious failure modes that have recurred more than twice or are severe one-off regressions. Treat them as permanent guardrails.

### Preflight deploy lock must survive later `EXIT` traps
`deploy/scripts/_preflight-checks.sh` acquires `s3://<project>-<env>-<account>/.preflight-locks/deploy.lock` and installs `_pf_release_lock_on_exit` as an `EXIT` trap. Bash only keeps one trap per signal, so any later `trap '...' EXIT` in a deploy script replaces the lock-release trap. If a deploy succeeds but leaves a lock whose PID is no longer running, check for a later temp-file cleanup trap that forgot to chain `_pf_release_lock_on_exit`.

Permanent guardrail: targeted deploy scripts that add their own `EXIT` cleanup after `preflight_validate` must chain the preflight release, for example `trap 'rm -rf "$DOCKER_CONFIG_DIR"; _pf_release_lock_on_exit' EXIT`.

### Bedrock KB — `troubleshooting_docs.docId` must be partial-unique
See § 5 above. Code: [`db-seeding/seed-indexes.ts`](../../db-seeding/seed-indexes.ts).

### AgentCore Runtime trace path — observability summary, not just events
`TraceCollector.attachEventsNested(...)` must update both the spliced events AND the parent's tally counters (`toolCallCount`, `mongoQueryCount`, `mcpCallCount`, `mongoDocsReturned`, `agentcoreHops`). Two emission shapes mix in the same stream:

- **Span pairs** (`start(...)/end(...)` — count completions only, where `durationMs != null`, to avoid double-counting).
- **One-off events** (`event(...)` — no `durationMs`, count every occurrence).

`mongo.result.docCount` (not `count`) is the rows-returned tally. `agentcoreRuntimeMs` must NOT be rolled up from spliced events because the parent's outer wall-clock already includes the inner hop. Pinned by `tests/unit/trace-collector.test.ts` "rolls up tool / mongo / mcp counters and mongoDocsReturned from spliced events".

### Two runtime entrypoints — drift is the bug
The runtime has **exactly one** entrypoint: [`api/src/agent-runtime-code.ts`](../../api/src/agent-runtime-code.ts). Both `Dockerfile.agentcore` and the direct-code S3 bundle invoke this file. `agent-runtime-server.ts` has been deleted. If `deployment_mode = "container"` ever needs to come back, add a thin wrapper around `agent-runtime-code.ts`, never a parallel implementation.

### MCP MongoDB URI must be the mode-correct private form (not public SRV)
In privatelink mode the runtime `MONGODB_URI` is the **multi-host non-SRV** PL URI with `tlsAllowInvalidHostnames=true`. In peering mode it is `connectionStrings.privateSrv` (or the matching multi-host form). Public `mongodb+srv://` URIs do not resolve from the private VPC and surface as `MongoAPIError: No addresses found at host`. The TF outputs in `modules/mongodb-atlas` (`privatelink_connection_string` and `peering_connection_string` / `peering_connection_srv_string`) feed the right value into `MONGODB_URI` — do not patch post-apply.

### Voyage AI — three env surfaces, all required
EC2 API `.env.live`, AgentCore Runtime env vars, runtime IAM `sagemaker:InvokeEndpoint`. Atlas vector index dimensions must match request `output_dimension`. See § 5 for the regression check.

### Bedrock model defaults rot
The default fact-extractor model is currently `us.anthropic.claude-haiku-4-5-20251001-v1:0`. When AWS deprecates it, move the default forward in the same change as the docs (`docs/memory-architecture.md`, `docs/reference/env-vars.md`, `AGENTS.md`). Override at runtime via `MEMORY_EXTRACTION_MODEL_ID`.

### Strands TS SDK + OTel — peer-dep version drift
Stay inside `sdk-trace-*` `^1.30.1` + exporters `^0.57.x`. When bumping any `@opentelemetry/*` dep:

1. Read `node_modules/@strands-agents/sdk/package.json` `peerDependencies` first.
2. `bun install`, then `ls node_modules/@strands-agents/sdk/node_modules/@opentelemetry` — if it exists, downgrade.
3. `bun run validate:strands-otel`.

The validator catches the full-Noop case; the dual-provider case (top-level real, Strands shadow-Noop) is not caught — the directory check above is the reliable signal.

### Networking — subnets must use standard AZs only (not Local/Wavelength)
Unfiltered `aws_availability_zones` can return Local Zones (`*-bos-1a`) or Wavelength Zones (`*-wl1-*`) first in accounts that enable them. Subnets land in unsupported zones → Atlas PrivateLink VPCE create fails; `map_public_ip_on_launch` on public subnets may fail. Fix: [`deploy/terraform/modules/networking/main.tf`](../../deploy/terraform/modules/networking/main.tf) filters `zone-type = availability-zone` and `opt-in-status = opt-in-not-required`, then `sort()`s names before subnet assignment. **Recovery:** re-apply network stack; if Terraform cannot move immutable subnets, destroy/recreate networking-layer resources (or clean network apply), then recreate PrivateLink endpoints. Validate: `terraform plan` shows AZs like `us-east-1a`, not `us-east-1-bos-1a` or `us-east-1-wl1-*`.

### Specialist AgentCore Runtime env reset to 4 vars after `terraform apply`
**Symptom.** Every `mongodb_*` tool call on a specialist runtime fails. Runtime logs show repeating `[mcp] listTools failed` / `[mcp] failed to load tools — agents will run without MCP tools` with `AGENTCORE_GATEWAY_URL is required`. `aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id <id> --query environmentVariables` returns only `AWS_REGION`, `AGENT_ID`, `LOG_LEVEL`, `AGENTCORE_MEMORY_STORE_ID`.

**Cause.** The 4 vars above are the only ones declared statically inside `module "acr_specialists"` and `module "acr_orchestrator"` in [`deploy/terraform/envs/ec2/main.tf`](../../deploy/terraform/envs/ec2/main.tf). The remaining dynamic vars (`AGENTCORE_GATEWAY_URL`, `MONGODB_URI`, `BEDROCK_KB_ID`, `EMBEDDINGS_PROVIDER`, …) are layered on **after** TF apply by `update_runtime_env_dynamic` in [`deploy/scripts/_agents-common.sh`](../../deploy/scripts/_agents-common.sh) (Phase 6b of `deploy-project.sh`). Without `lifecycle { ignore_changes = [environment_variables] }` on the runtime module, any subsequent `terraform apply` that does not run the full Phase 6b orchestrator wipes the runtime back to the 4 declared vars. The MongoDB MCP client now fails fast when Gateway env is missing (see `resolveMcpEndpoint()` in [`api/src/adapters/mongodb-mcp-client.ts`](../../api/src/adapters/mongodb-mcp-client.ts)); there is no localhost fallback. `MCP_SERVER_URL` is local-development only and is not part of deployed runtime wiring.

**Permanent guardrails (do not remove):**
- The runtime module declares `ignore_changes = [environment_variables]` in its `lifecycle` block — TF must not own this field.
- `update_runtime_env_dynamic` / `verify_runtime_env_dynamic` require `AGENTCORE_GATEWAY_URL` to be present on *every* runtime regardless of caller shell state. Mongo tool calls must go through AgentCore Gateway; the MongoDB MCP runtime ARN/endpoint are Gateway-target infrastructure wiring, not app runtime env.
- `deploy-project.sh` Phase 6b and `deploy-agents.sh` Phase 8 hard-fail before calling `update-agent-runtime` when the Gateway URL is empty in the caller env.
- `runChatStream` (`api/src/lib/run-chat-stream.ts`) emits a `tools.degraded` trace + SSE `stream_error` with `code: TOOLS_UNAVAILABLE` when an agent declared `mongodb_*` tools but `getMcpTools()` returned `[]`. `getAgentTemplate(...)` does NOT cache degraded templates so the next chat turn re-attempts MCP and self-heals once the runtime is reachable.
- `e2e-smoke/post-deploy-smoke.py::check_agentcore_runtime_env` validates the required vars on every runtime ARN listed in `.env.live` before the live chat checks.

**Recovery for an already-broken stack:** `source .env && source .env.live && ./deploy/deploy-agents.sh --auto-approve`. The script bumps the code artifact pointer, so AgentCore drops the poisoned containers and the next invocation rebuilds the agent template against a populated MCP tool list.

### AgentCore Gateway target stuck `FAILED` — Terraform must not silently skip
**Symptom.** Specialist runtimes log `[mcp] connected` followed by `[mcp] loaded tools — tools: []`, then refuse to run with `tools.degraded` / SSE `stream_error` (`TOOLS_UNAVAILABLE`). Post-deploy smoke times out waiting for an assistant reply. `aws bedrock-agentcore-control get-gateway-target` reports `status: FAILED` with reasons such as:
- `Gateway service is not authorized to assume the execution role` — IAM trust/permission lag (target was created before the gateway role policy propagated).
- `User: arn:aws:sts::…:assumed-role/…-gw-…/mcp-iam-auth-session is not authorized to perform: bedrock-agentcore:InvokeAgentRuntime on resource: <runtime arn>` — IAM grant references a stale runtime ARN after the MCP runtime was replaced.
- `Failed to connect and fetch tools from the provided MCP target server` — runtime endpoint unreachable, or AgentCore Runtime version is stuck (see the "AgentCore Runtime VPC mode" pitfall below).

**Cause.** The Terraform `null_resource` at [`deploy/terraform/modules/agentcore-gateway/main.tf`](../../deploy/terraform/modules/agentcore-gateway/main.tf) used to skip creation whenever a target with the same `name` already existed, regardless of status. A target stuck in `FAILED` therefore survived every subsequent `terraform apply`, so the Gateway returned an empty `tools/list` for hours with no surfaced error.

**Permanent guardrails (do not remove):**
- The null_resource now branches on `status`: `READY`/`ACTIVE` skip, `FAILED` triggers `delete-gateway-target` + recreate (with the `statusReasons` logged for the operator), `CREATING`/`UPDATING`/`DELETING` exit 0 to avoid racing the API. Any other status logs the value and exits 0.
- Whenever the MCP runtime is replaced, force the same apply to recreate the Gateway target — either delete the failed target manually or `terraform state rm 'module.agentcore_gateway.null_resource.mcp_server_gateway_target[0]'` before re-applying.

**Recovery for an already-failed target:** delete it directly and let the next apply recreate it.
```bash
GW=$(terraform -chdir=deploy/terraform/envs/ec2 output -raw agentcore_gateway_id)
TID=$(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GW" --region "$AWS_REGION" --query "items[?name=='mongodb-mcp'].targetId | [0]" --output text)
aws bedrock-agentcore-control delete-gateway-target --gateway-identifier "$GW" --region "$AWS_REGION" --target-id "$TID"
terraform -chdir=deploy/terraform/envs/ec2 state rm 'module.agentcore_gateway.null_resource.mcp_server_gateway_target[0]'
terraform -chdir=deploy/terraform/envs/ec2 apply -target=module.agentcore_gateway -auto-approve
```

### AgentCore Gateway target create fails — stale AWS CLI service model
**Symptom.** `terraform apply` for `module.agentcore_gateway.null_resource.mcp_server_gateway_target` fails partway through phase 5 of `deploy-project.sh` with:
```
Parameter validation failed:
Unknown parameter in targetConfiguration.mcp: "mcpServer", must be one of: openApiSchema, smithyModel, lambda
Unknown parameter in credentialProviderConfigurations[0].credentialProvider: "iamCredentialProvider", must be one of: oauthCredentialProvider, apiKeyCredentialProvider
```
The deployment looks healthy through earlier phases — Atlas, EC2, Bedrock KB, AgentCore runtimes all apply — and only the gateway target step blows up. `aws --version` reports something like `aws-cli/2.28.21`.

**Cause.** The Terraform `null_resource` at [`deploy/terraform/modules/agentcore-gateway/main.tf`](../../deploy/terraform/modules/agentcore-gateway/main.tf) shells out to `aws bedrock-agentcore-control create-gateway-target` with `targetConfiguration.mcp.mcpServer` and `credentialProviderConfigurations[].credentialProvider.iamCredentialProvider`. Both keys were added to the AWS service model in a recent `botocore` release. AWS CLI 2.28.x and earlier ship an older model that simply does not know those fields and rejects the request client-side. The generic `aws-cli >= 2.15` floor in `pf_check_tool_versions` was not sufficient — the CLI is on PATH, it just speaks an outdated dialect.

**Permanent guardrails (do not remove):**
- [`deploy/scripts/_preflight-checks.sh`](../../deploy/scripts/_preflight-checks.sh) ships `pf_check_aws_cli_agentcore_gateway_model`, registered in `orchestrator-privatelink`, `orchestrator-peering`, and `project-pre-apply`. It runs `aws bedrock-agentcore-control create-gateway-target --generate-cli-skeleton input` (offline; no auth, no network), parses the JSON with `python3`, and hard-fails with `--exit-class tool` if either `targetConfiguration.mcp.mcpServer` or `credentialProviderConfigurations[].credentialProvider.iamCredentialProvider` is missing from the local service model. A failing run prints the parsed `aws --version`, the missing field paths, and the macOS / Linux / CI upgrade steps from [`docs/deployment-preflight-checks.md`](../deployment-preflight-checks.md#aws-cli-agentcore-gateway-model) before any Terraform state is mutated.
- `_pf_self_test` Test 12 pins the parser against three fixtures (healthy skeleton, missing `mcpServer`, missing `iamCredentialProvider`), so the negative path is regression-covered without needing a stale CLI host.
- Never patch around the failure by hand-editing the gateway module to switch back to the legacy keys. The Terraform shim is the canonical create shape; the operator's CLI is the thing that needs to move.

**Recovery for an in-flight broken deploy:** upgrade the CLI and re-run.
```bash
# macOS / Homebrew
brew update && brew upgrade awscli && aws --version
# macOS pkg / Linux: reinstall AWS CLI v2 from the official bundle
#   https://awscli.amazonaws.com/AWSCLIV2.pkg            (macOS)
#   https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
#   https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip

source .env && ./deploy/deploy-full-with-privatelink.sh --auto-approve
```
The retry wrapper inside `deploy-project.sh` re-plans against current state, so a half-applied gateway target is reconciled by the next apply (the null_resource branches on existing target status — see the previous pitfall).

### AgentCore Runtime VPC mode — disable Docker BuildKit attestation manifests
**Symptom.** A previously healthy VPC-mode AgentCore Runtime (e.g. `mongodb_mcp`) suddenly refuses to cold-start. Every `InvokeAgentRuntime` returns after 120 s with `{"jsonrpc":"2.0","error":{"code":-32010,"message":"Runtime initialization time exceeded. Please make sure that initialization completes in 120s."}}`. The container task is never scheduled — no new log streams appear under `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT`. The runtime status stays `READY` at the control plane the whole time. Pulling the same image with `docker run --platform linux/arm64 …:latest` locally works in <2 s.

**Cause.** Default `docker build` (Docker 23+) wraps the output in an OCI image index that carries two entries: the real arm64 manifest **and** an `attestation-manifest` with `architecture: unknown, os: unknown`. AgentCore's puller has been observed to follow the attestation entry, which has no runnable layers, so the task launch silently fails. The legacy `docker buildx` push produced a single-platform v2 manifest, which is what AgentCore expects.

**Permanent guardrails (do not remove):**
- [`deploy/scripts/_docker-build.sh`](../../deploy/scripts/_docker-build.sh) forces `--provenance=false --sbom=false` on every build. Do not delete those flags or revert to `docker buildx` without the same flags — the next push will reintroduce the attestation entry and the next VPC-mode cold start will fail with no logs.
- Verify a freshly pushed image is a clean v2 manifest, not an index, with `aws ecr batch-get-image --repository-name <repo> --image-ids imageTag=latest --query 'images[].imageManifest' --output text | head -3` — expect `mediaType: …manifest.v2+json`, not `…image.index.v1+json`.

**Recovery once a runtime is wedged:** rebuilding/pushing the image alone is not enough; AgentCore may keep the bad task scheduling state for the existing runtime resource. Replace the runtime so the AgentCore control-plane state is rebuilt from scratch.
```bash
terraform -chdir=deploy/terraform/envs/ec2 apply \
  -replace='module.mongodb_mcp_runtime.aws_bedrockagentcore_agent_runtime.this' \
  -target=module.mongodb_mcp_runtime -target=module.agentcore_gateway -auto-approve
```
The Gateway target's IAM grant is rebound to the new runtime ARN by the same module; if the target was already in `FAILED` before the replace, also delete it (see the previous pitfall) so the apply recreates a clean one.

### MongoDB MCP server schemas must allow MCP-spec `_meta` passthrough
**Symptom.** Every `mongodb_*` tool call routed through the AgentCore Gateway fails immediately with `tool.mcp.result` text:
```
ValidationException - Parameter validation failed: Invalid request parameters:
- additionalProperties validation failed: property '_meta' is not defined in the schema and the schema does not allow additional properties
```
The model retries with cosmetic variations of the same arguments (`operation: "find"`, `operation: "findOne"`, …) and eventually gives up with a hallucinated "I couldn't find that order" reply. The `mongo.*` runtime logs show the failure happens **before** the request reaches the MongoDB MCP container — the gateway service rejects it server-side.

**Cause.** MCP spec §2.4 reserves `_meta` on request `params`. The AgentCore Gateway populates `_meta` (correlation IDs, progress tokens, etc.) when proxying `tools/call` upstream, and AWS validates the forwarded `arguments` against the tool's registered `inputSchema`. The MongoDB MCP server's Zod input schemas in [`mcp-runtimes/mongodb-mcp/src/server.ts`](../../mcp-runtimes/mongodb-mcp/src/server.ts) must declare `_meta` as an optional unknown record (`META_PASSTHROUGH`) or every gateway-routed call fails before the handler ever runs.

**Permanent guardrails (do not remove):**
- The `META_PASSTHROUGH = { _meta: z.record(z.string(), z.unknown()).optional() }` literal in [`mcp-runtimes/mongodb-mcp/src/server.ts`](../../mcp-runtimes/mongodb-mcp/src/server.ts) is spread into every `mongodb_*InputSchema`. Pinned by `mcp-runtimes/mongodb-mcp/tests/server-meta-passthrough.test.ts`.
- `dispatch()` strips `_meta` before invoking handlers so per-tool guard code never sees the envelope key.
- **Any new MCP runtime added to the gateway must apply the same `_meta` passthrough on every tool's input schema.** Without it the gateway rejects the very first call and the failure mode looks like a tool-name bug rather than a schema-shape bug.

**Recovery for an already-broken stack:** rebuild the MCP runtime image, force-update the AgentCore runtime, and delete+recreate the gateway target so it re-discovers tool schemas. `deploy-project.sh` Phase 4d's `force_mcp_runtime_image_sync` helper now does all three steps automatically when the image digest changes.

### AgentCore Gateway target caches tool schemas — refresh after MCP runtime change
**Symptom.** MongoDB MCP runtime was rebuilt and updated to a new container version, but `tools/call` from agents still fails against the OLD upstream schema (e.g. a tool that used to reject `_meta` keeps rejecting after the upstream schema was fixed). `aws bedrock-agentcore-control get-gateway-target` returns `status: READY` so nothing looks wrong at the gateway control plane.

**Cause.** The Gateway calls `tools/list` against the upstream MCP server **at target-create time** and caches the resulting schema for routing/validation. Subsequent upstream changes (input schema edits, new tools, removed tools) are not auto-discovered. Without a force-refresh, the gateway will keep validating against the schema captured on `create-gateway-target`.

**Permanent guardrails (do not remove):**
- `_agents-common.sh::force_mcp_runtime_image_sync` (called from `deploy-project.sh` Phase 4d) compares the pushed image digest with the runtime's currently-deployed digest. When they differ it: (a) calls `update-agent-runtime` to bump the runtime version, (b) waits for `READY`, (c) deletes the gateway target so the null_resource in [`deploy/terraform/modules/agentcore-gateway/main.tf`](../../deploy/terraform/modules/agentcore-gateway/main.tf) recreates it with fresh tool schemas on the same apply.
- The null_resource's `triggers.mcp_server_image_digest` makes the schema cache lifecycle visible in `terraform plan` even outside the deploy script.

**Recovery for an already-broken stack:** delete the target manually and let TF recreate it.
```bash
GW=$(terraform -chdir=deploy/terraform/envs/ec2 output -raw agentcore_gateway_id)
TID=$(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GW" --region "$AWS_REGION" --query "items[?name=='mongodb-mcp'].targetId | [0]" --output text)
aws bedrock-agentcore-control delete-gateway-target --gateway-identifier "$GW" --region "$AWS_REGION" --target-id "$TID"
terraform -chdir=deploy/terraform/envs/ec2 apply -target=module.agentcore_gateway -auto-approve
```

### AgentCore Runtime image push does not auto-trigger a runtime version bump
**Symptom.** `mcp-runtimes/mongodb-mcp/src/*.ts` was edited and a deploy ran successfully. `docker push` reports a new digest. But the AgentCore runtime keeps serving the old behaviour because it never pulled the new image. `aws bedrock-agentcore-control get-agent-runtime --query 'lastUpdatedAt'` shows a timestamp from hours/days before the deploy.

**Cause.** The runtime's `container_uri` is `${repo}:latest` in Terraform. Terraform compares the URI string and sees no diff, so it never replaces the runtime, so AgentCore never re-pulls the image. The image digest behind `:latest` changed but Terraform has no visibility into that.

**Permanent guardrails (do not remove):**
- `_agents-common.sh::force_mcp_runtime_image_sync` always calls `update-agent-runtime` (with the same role/network/protocol/env config) when a new image was pushed in the same apply. AgentCore treats every `update-agent-runtime` call as a new version, which forces a pull of `:latest` on the next cold start.
- The helper writes the update payload to a temp file and passes `file://${path}` to the AWS CLI. **Do not** pipe JSON to `file:///dev/stdin` — macOS aws-cli rejects it with `ParamValidation: Invalid JSON received` even though Linux often accepts it.
- Skip with `MCP_RUNTIME_FORCE_SYNC=0` only in incident response — leaving it skipped will silently freeze the MCP runtime at whatever version was last force-synced.

**Recovery for a wedged runtime:**
```bash
source .env && source .env.live
RUNTIME_ID=$(echo "$MONGODB_MCP_RUNTIME_ARN" | awk -F/ '{print $NF}')
REPO_NAME="${PROJECT_NAME}-mongodb-mcp-${ENVIRONMENT}"
GATEWAY_ID=$(terraform -chdir=deploy/terraform/envs/ec2 output -raw agentcore_gateway_id 2>/dev/null || true)
# Bash helpers must be sourced; you cannot call functions with `script.sh::fn` syntax.
source deploy/scripts/_agents-common.sh
force_mcp_runtime_image_sync "$RUNTIME_ID" "$REPO_NAME" "latest" "$GATEWAY_ID" "mongodb-mcp"
```
Or, equivalently, re-run `./deploy/deploy-full-with-privatelink.sh --auto-approve` (skip-network and skip-shared are safe shortcuts).

### MongoDB MCP prewarm singleton race — boot connects without a JWT lock the runtime degraded
**Symptom.** Specialist runtimes (especially less-frequently-used ones like `product-recommendation`) refuse to run with SSE `stream_error` `TOOLS_UNAVAILABLE` and missing `mongodb_query`/`mongodb_vector_search`. CloudWatch logs show *two* `[mcp] connect failed with auth error — will retry on next call` entries ~140 ms apart, immediately followed by `[chat] refusing to run turn against degraded template`. The same runtime worked seconds earlier for another agent.

**Cause.** `api/src/lib/prewarm.ts::runStartupPrewarm()` used to call `getMcpTools()` at container boot to warm the MCP connection. Boot has no caller-scoped JWT, so the gateway rejected the unauthenticated connect with `Missing Bearer token`. Worse, `getMcpTools()` cached the in-flight promise as a process-wide singleton — if a real chat request arrived during the ~100 ms boot window, it awaited the *prewarm's* JWT-less promise instead of starting its own JWT-scoped load, inheriting the empty tools list and degrading its template.

**Permanent guardrails (do not remove):**
- MCP prewarm is disabled in [`api/src/lib/prewarm.ts`](../../api/src/lib/prewarm.ts); `opts.mcp` is accepted for API compatibility but logs a deprecation warning when truthy. The first chat turn connects MCP lazily inside its own `withGatewayJwt(...)` scope (~150–400 ms).
- `getMcpTools()` in [`api/src/adapters/mongodb-mcp-client.ts`](../../api/src/adapters/mongodb-mcp-client.ts) now reissues a fresh load when an in-flight singleton returned `[]` and the current caller has a JWT in scope (`currentGatewayJwt()` is non-empty). Belt-and-suspenders for any future callsite that bypasses the disabled prewarm.
- Pinned by `api/tests/unit/mcp-client-jwt-aware-retry.test.ts`.

**Recovery for an already-degraded runtime:** the next turn rebuilds the template because `getAgentTemplate(...)` does not cache degraded templates — so a single retry usually unsticks it. If multiple consecutive turns degrade, check the gateway target status and the runtime's MCP connectivity (`aws bedrock-agentcore-control get-gateway-target`).

### AgentCore Gateway response strips `meta.traces` — `mongoQueries` must count `tool.mcp`
**Symptom.** `chat.turn.end.summary` shows `mongoQueries: 0` even though the runtime obviously executed Mongo work (the reply contains seeded order data, `tool.mcp` events are present, `mcpCalls > 0`). The CloudWatch dashboards' Mongo widgets stay empty for AgentCore-routed turns. Deploy smoke aborts on `mongoQueries == 0 - counter rollup or Mongo path broken`.

**Cause.** The MongoDB MCP server packs every per-call trace event (`mongo.query`, `mongo.result`, `mongo.vector_search`, …) into `content[0].text.meta.traces`. `extractAndReplayMcpTraces()` in [`api/src/adapters/mongodb-mcp-client.ts`](../../api/src/adapters/mongodb-mcp-client.ts) replays them onto the parent collector — but **only when the upstream response envelope reaches us intact**. The AgentCore Gateway proxies the response and strips the `meta` object, so the parent collector only sees the outer `tool.mcp` event and never the inner `mongo.*` events.

**Permanent guardrails (do not remove):**
- `TraceCollector.attachEventsNested()` and `summary()` in [`api/src/lib/trace-collector.ts`](../../api/src/lib/trace-collector.ts) treat any `tool.mcp` event whose `toolName`/`name` matches `/mongo/i` as a synthetic `mongoQueries += 1`. A `mongo.result` without a sibling `mongo.query` also bumps `mongoQueries` (every result implies a query ran).
- `findOutermostAgentcoreInvokeId()` in [`api/src/routes/chat.ts`](../../api/src/routes/chat.ts) matches **closed** `agentcore.invoke` spans (no `durationMs === undefined` guard) — the wrapper is already ended by the time the route's `finally` block splices nested events.
- Pinned by `api/tests/unit/trace-collector.test.ts` "rolls up tool / mongo / mcp counters …" and `api/tests/unit/chat-find-outermost-agentcore-invoke.test.ts`.

**Recovery:** no live recovery needed. If `mongoQueries` stays at 0 in deploy smoke after a fresh deploy, verify the rollup tests above pass and that the `agentcore.invoke` event's `payload.toolName` field really does include the `mongodb` substring (rename-driven regressions catch here).

### Preflight module must stay bash-3.2 compatible
[`deploy/scripts/_preflight-checks.sh`](../../deploy/scripts/_preflight-checks.sh) targets the stock macOS `/bin/bash` (3.2). It must **not** introduce `declare -A`, `local -n` / `unset -n`, `mapfile`, `readarray`, or `${var,,}` lowercase expansion — instead use the `_pf_set` / `_pf_get` / `_pf_kv_reset` map helpers, the `eval "_PF_CHECKS=(\"\${${arr_name}[@]}\")"` indirect-array idiom, and `while IFS= read -r line; do …; done < <(…)` loops. Verify with `bash deploy/scripts/_preflight-checks.sh --self-test` on a stock macOS shell before merging — the self-test asserts every profile entry resolves to a defined function and every literal `--hint` value uses the closed `edit:|run:|console:|doc:|iam:|tfvar:` vocabulary, but it can only catch the bash-version regression by actually running. Catalog of every check in [`deployment-preflight-checks.md`](../deployment-preflight-checks.md).

## 11. Break-glass

Emergency knobs when production is degraded and you need a quick mitigation.

| Knob | Effect | How |
|---|---|---|
| Disable metrics emitter | Stops EMF stdout writes; dashboards go empty but API throughput recovers if EMF was thrashing | Edit `.env`, set `METRICS_EMITTER_ENABLED=0`, run `deploy-api.sh` |
| Disable long-term memory writes | Stops Bedrock extractor calls (cost + Bedrock TPM relief) | Edit the agent's `.agent.md` frontmatter, set `memory.longTerm: false`, run `deploy-agents.sh` |
| Force-clear API agent cache | Re-reads `config/agents/*.agent.md` without restart | `curl -X POST -H "X-Agent-Config-Refresh-Token: $TOKEN" "$API_URL/internal/agents/refresh"` |
| Pin `MEMORY_VECTOR_TOPK=0` | LTM read is a no-op; chat works without memory injection | Add to `.env`, run `deploy-api.sh` |
| Pin `TRACING_ENABLED=false` | Disables the per-turn collector (no traces, no SSE trace events) | Add to `.env`, run `deploy-api.sh` |
| Roll back the API image | Retag ECR `latest` to a previous digest | `python3 e2e-smoke/failure-drills/api_rollback.py` — runs the same procedure with a `finally` restore path |
| Force every CW alarm to `OK` | Resets the alarm state without resolving the underlying signal | `python3 e2e-smoke/failure-drills/force_alarm_states.py --state OK` |

Always document any break-glass change in the on-call rotation log so the next operator knows the live state differs from `main`.

---

*Last verified: 2026-05-23 against `api/src/`, `deploy/scripts/`, `db-seeding/seed-indexes.ts`, and the smoke/failure-drill scripts in `e2e-smoke/`.*
