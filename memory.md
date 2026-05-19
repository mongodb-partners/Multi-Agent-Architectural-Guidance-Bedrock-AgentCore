# Project memory — pitfalls to avoid repeating

**Audience:** human and AI contributors. This is **not** runtime agent memory (that would be AgentCore / MongoDB long-term memory in the product sense).

**Purpose:** Record **only persistent pitfalls** — failure modes that are **non-obvious** and have **recurred more than twice** (or are severe once-off regressions such as **hung tests / infinite loops** in CI). Do **not** add an entry for every bug or design choice; use [`docs/`](docs/), commit messages, and PR descriptions for ordinary fixes.

**How to add an entry**

- Confirm the bar: same class of mistake **repeated** (e.g. third time someone breaks Swarm + dev mock), or a **single** critical regression worth a permanent guardrail.
- Prefer a **bold title** + **symptom** + **rule** + **file(s)**.
- Keep it scannable; link to code or tests when useful.

---

## Bedrock KB ingestion — `troubleshooting_docs.docId` must be a **partial** unique index

**Symptom:** Bedrock KB ingestion (Option A PrivateLink **or** the public-SRV path — same outcome) fails every document with the cryptic top-level error `"Write failure with error code -3"`. Every PrivateLink probe says the path is healthy: VPCE → endpoint service → NLB → Atlas VPCE all green, mongosh writes succeed from EC2, Bedrock-managed VPC application logs show **CRAWLING_COMPLETED** and **EMBEDDING_COMPLETED** for every doc, then `INDEXING_FAILED` with the same `error code -3`. Looks like networking; is actually a Mongo `E11000 duplicate key error on { docId: null }`.

**Cause:** The seed step `db-seeding/seed-indexes.ts` puts a plain unique index on `troubleshooting_docs.docId` because the troubleshooting agent looks playbooks up by `docId` (`ts-1`, `ts-2`, …) and we want to block duplicate seed inserts. Bedrock writes its embedding chunks **into the same collection** with their own `_id` and **no** `docId` field — so the very first chunk insert lands as `docId: null`, and the second one fails uniqueness. Bedrock's connector reports it as the generic "Write failure with error code -3" instead of the underlying `E11000` (which is only visible by enabling `APPLICATION_LOGS` log delivery and reading the per-chunk `status_reasons`, *or* by replicating the insert from EC2 with a Mongo driver).

**Rule:** Any unique index on a field that Bedrock-ingested chunks may not carry **must** be expressed as a `partialFilterExpression`-scoped index, not plain unique. For `troubleshooting_docs.docId` the canonical form is:

```ts
{ collection: "troubleshooting_docs", spec: { docId: 1 }, options: {
    unique: true,
    partialFilterExpression: { docId: { $exists: true, $type: "string" } },
  }}
```

If you ever land on this error again: enable Bedrock KB **APPLICATION_LOGS** (`aws logs put-delivery-source --resource-arn <kb-arn> --log-type APPLICATION_LOGS …`) and grep `status_reasons` for the real driver error before chasing PrivateLink.

**Code:** [`db-seeding/seed-indexes.ts`](db-seeding/seed-indexes.ts) (the index spec **and** the `IndexOptionsConflict` heal path that drops + recreates a stale plain-unique `docId_1`).

---

## AgentCore Runtime trace path — observability summary, not just events

**Symptom:** `/chat` returns real Atlas data, the Trace Viewer shows mongo.* / tool.* events, but the per-turn **summary card** displays `0 tool calls`, `0 mongo queries`, `0 docs returned`, `1 hop`. Looks like a trace bug; is actually a counter-rollup bug.

**Cause:** `TraceCollector.attachEventsNested(...)` splices nested events into the parent's events list but **does not** update the parent's tally counters (`toolCallCount` / `mongoQueryCount` / `mcpCallCount` / `mongoDocsReturned` / `agentcoreHops`). Those counters are bumped only inside the parent's own `start(...)/end(...)` calls. For an AgentCore Runtime turn, every tool/mongo/mcp event runs inside the runtime container's child collector and arrives at the parent purely as spliced events — so the summary stays at 0.

A second wrinkle: the runtime ships back two emission shapes mixed together:

- **Span pairs** (Strands SDK emits `tool.call` and `agentcore.invoke` via `start(...)/end(...)` — start has no `durationMs`, end has it). Count completions only (`durationMs != null`) to avoid double-counting.
- **One-off events** (the Lambda's `mongo.*` events and the MCP wrapper's `tool.mcp` arrive via `event(...)`, no `durationMs`). Count every occurrence.

Two more field-name mismatches that hid the bug for a while: `mongo.result.docCount` (not `count`) carries the rows-returned tally, and `agentcoreRuntimeMs` must **not** be rolled up from spliced events because the parent's outer wall-clock already includes the inner hop.

**Rule:** Any new tally counter on `TraceCollector` must be updated in **both** `end(...)` (in-process spans) **and** `attachEventsNested(...)` (nested spliced events). Mirror what's already there for `tool.call` / `mongo.query` / `tool.mcp` / `mongo.result.docCount` / `agentcore.invoke`. Pinned by `tests/unit/trace-collector.test.ts` "rolls up tool / mongo / mcp counters and mongoDocsReturned from spliced events".

**Code:** `api/src/lib/trace-collector.ts` (`attachEventsNested`).

---

## Two runtime entrypoints — drift is the actual bug

**Symptom:** `agent-runtime-code.ts` (the **deployed** entrypoint, used by `deployment_mode = "code"` which is the default) shipped without trace plumbing for the entire post-cleanup deploy. The **other** entrypoint `agent-runtime-server.ts` had all the trace machinery — but it only ran in the dead `deployment_mode = "container"` path. Result: production looked broken (`toolCalls: 0`) even though the duplicate file was correct, because nobody was reading it.

**Rule:** The runtime has exactly **one** entrypoint: `api/src/agent-runtime-code.ts`. Both `Dockerfile.agentcore` and the direct-code S3 bundle invoke this same file. `agent-runtime-server.ts` has been deleted. If a `deployment_mode = "container"` ever needs to come back, add a thin wrapper around `agent-runtime-code.ts`, never a parallel implementation.

**Code:** `api/src/agent-runtime-code.ts`, `api/Dockerfile.agentcore` (CMD points at `agent-runtime-code.ts`).

---

## AgentCore Gateway → Mongo tool path — four silent failure modes, identical symptom

**Symptom (all four):** `/chat` streams a fluent SSE response, no `event: error`, but the assistant narrates that it would like to query the database / "couldn't find the tool" / "I'd recommend checking…". Trace summary shows `toolCalls: 0`. CloudWatch shows the Hono API → AgentCore Runtime call succeeded. The Mongo tool path between the **Strands Agent in the runtime container** and the **Lambda behind the gateway** is broken in one of four places — each silent, each shipped at least once during the gateway-only cleanup:

1. **`userJwt` not scoped inside the runtime container.** The Hono API forwards the caller's Cognito IdToken in the invocation payload, but `agent-runtime-code.ts` must extract it and wrap the agent run in `withGatewayJwt(userJwt, async () => { ... })`. Without that, the StreamableHTTP transport's `jwtInjectingFetch` reads `currentGatewayJwt() === undefined`, the gateway returns `401 Missing Bearer token` on `connect`/`listTools`, `getMcpTools()` returns `[]`, and the agent has no Mongo tool to call. **Pinned by:** `tests/unit/agent-construction-invariants.test.ts` (greps for `withGatewayJwt(userJwt,`).
2. **Tool-name prefix not aliased.** AgentCore Gateway publishes every tool from the `mongodb-mcp` Lambda target as `mongodb-mcp___<tool>`, but agent personas reference `mongodb_query`. `mongodb-mcp-client.ts` wraps each prefixed `McpTool` in an `AliasedMcpTool` so the LLM sees the unprefixed name while the underlying call still goes out under the prefixed name (`McpClient.callTool` looks at the underlying tool's `name`). Drop the alias and the model emits `mongodb_query`, Strands cannot find it in its registry, the call silently no-ops. **Pinned by:** `tests/unit/mongodb-mcp-tool-alias.test.ts`. **Coupled to** `target_name = "mongodb-mcp"` in `deploy/terraform/modules/agentcore-gateway/main.tf` — change one, change both.
3. **`run-chat-stream.ts` constructs `Agent` without MCP tools.** `toolsForAgent(...)` returns only in-process tools by design (Mongo tools come from the gateway). A `new Agent({ tools: toolsForAgent(...) })` ships a Mongo-less agent. Both `run-chat-stream.ts` and `create-strands-agent.ts` must `await getMcpTools()` and spread the result into `tools`. **Pinned by:** the same `agent-construction-invariants.test.ts` — every `new Agent(` site in `api/src` must be on an allow-list and must reference `getMcpTools(`. A new `Agent` constructor anywhere else fails the test until the author justifies it.
4. **Lambda `parseEvent` envelope mismatch.** AgentCore Gateway invokes the Lambda with the raw tool args as `event` and the prefixed tool name on `context.clientContext.custom.bedrockAgentCoreToolName` (lowercase `custom` on Node — confirmed empirically; AWS docs only show the Python `client_context.custom["…"]` shape). Probing only the uppercase `Custom` field — or only matching `event.toolName` / `event.tool_name` / `event.body` — falls through to `throw new Error("Unrecognized event shape")` and the gateway returns 502. **Pinned by:** `tests/unit/lambda-parse-event.test.ts` (the lowercase-`custom` case is the regression test).

**Smoke test that catches all four:** `deploy.sh` Phase 8 runs a real `/chat` against ORD-2002 and asserts the trace summary includes Mongo/MCP counters plus a response containing `TRK-2002-US` / `Pro Gadget` / `89.99` (fields that only exist if the Mongo tool actually returned the seeded order document). Avoid reusing the fixed smoke user's frequently discussed ORD-1003 return fixture here — long-term memory can make the model answer from remembered context and skip the Mongo tool. SSE-event-presence-only smoke would pass on all four failure modes.

**Code:** `api/src/agent-runtime-code.ts` (1), `api/src/adapters/mongodb-mcp-client.ts` (2), `api/src/lib/run-chat-stream.ts` + `api/src/lib/create-strands-agent.ts` (3), `lambda/mongodb-mcp/index.mjs` (4).

---

## `read_skill_resource` — activation and allowlist

**Rule:** The tool is bound per agent: **`skillName` must be in that agent’s `.agent.md` `skills:` list**, and the skill must be **activated** (full `SKILL.md` loaded via `activate_skill`, or specialist **`preActivateSkills`**). Otherwise the API returns `skill_not_allowed_for_agent` or `skill_not_activated` — do not bypass with a looser reader.

**Code:** `readSkillResourceWithRegistry` in `api/src/lib/base-tools.ts`, `SkillRegistry.isSkillActivated` in `api/src/lib/skill-loader.ts`.

---

## Skill `scripts/*.mjs` — dynamic import = executable config

**Symptom / risk:** Editing `config/skills/.../scripts/*.mjs` changes runtime behavior the next time the API process loads that module (cached import). This is intentional for policy-as-code but **must be treated as trusted code** — same trust boundary as the rest of `config/`.

**Rule:** Keep skill modules **pure** (no network, no filesystem) unless explicitly designed otherwise. Convention: `.mjs` files in `config/skills/<name>/scripts/` export named functions; the generic `run_skill_script` tool in `api/src/lib/base-tools.ts` dynamically imports them at call time (registry-bound, same allowlist/activation gates as `read_skill_resource`). **No dedicated API loader file per script** — the tool does `import()` inline.

---

## Lambda MCP zip needs `node_modules` baked in

**Symptom:** Right after a fresh deploy.sh / first apply on a new environment, every `mongodb_*` tool call from an agent returns 0 results. Lambda CloudWatch logs show: `Cannot find package 'mongodb' imported from /var/task/index.mjs`. Vector search silently degrades to "catalog appears empty".

**Cause:** `deploy/terraform/modules/lambda-mcp/main.tf` zips `lambda/mongodb-mcp/` with `archive_file`. It does **not** run `npm install`, so a fresh checkout (or any environment where `lambda/mongodb-mcp/node_modules/` was never created) ships a Lambda with a `mongodb` import but no dep tree.

**Rule:** `deploy.sh` Phase 4c runs `npm install --omit=dev --cache /tmp/npm-cache-lambda-mcp` in `lambda/mongodb-mcp/` before `terraform apply` so the archive_file picks up `node_modules/`. **Do not** delete that phase, and **do not** `.gitignore` `lambda/mongodb-mcp/node_modules/` in a way that breaks `terraform plan` between `deploy.sh` runs (the dir is recreated each run; ignoring it is fine, dropping the install step is not).

**Regression check:** After `deploy.sh`, invoke `aws lambda invoke --function-name <project>-mongodb-mcp-<env>` with a mongodb_query payload — should return `statusCode: 200`, not `errorType: Error`.

---

## Lambda MCP MongoDB URI must be PrivateLink-direct (not SRV)

**Symptom:** Every `mongodb_*` tool call from an agent silently returns 0 docs. Agent answers with apologies / "the catalog appears empty". Atlas + the EC2 API are healthy. Lambda CloudWatch shows: `MongoAPIError: No addresses found at host` from `resolveSRVRecord (mongodb/lib/connection_string.js:62:15)`.

**Cause:** The Lambda MCP runs in a private VPC (no NAT, no public DNS to the internet). When `MONGODB_URI` starts with `mongodb+srv://`, the MongoDB driver does a public-DNS SRV lookup at the Atlas hostname (e.g. `mongodb-multiagent3-dev.dcysxk.mongodb.net`) which fails because the VPC can't resolve it. The fix is the **multi-host non-SRV** PrivateLink URI:

```
mongodb://<user>:<pwd>@pl-0-<region>.<id>.mongodb.net:1051,pl-0-<region>.<id>.mongodb.net:1052,pl-0-<region>.<id>.mongodb.net:1053/?ssl=true&authSource=admin&replicaSet=<rs>&tlsAllowInvalidHostnames=true
```

Two non-obvious requirements:

1. The hostnames + ports are **per-cluster + per-VPCE** — Atlas allocates them when the PrivateLink endpoint is provisioned. Read them from `mongodbatlas_cluster.main.connection_strings[0].private_endpoint[*].connection_string` (filter by the matching `endpoint_id` to your VPCE).
2. `tlsAllowInvalidHostnames=true` is required because Atlas's per-region PrivateLink hostname is **not** in the served TLS cert's SAN list. CA + chain + expiry verification still apply; only hostname matching is skipped — safe because traffic stays inside an AWS-owned PrivateLink.

**Rule:** The Lambda's `MONGODB_URI` must be set by Terraform via `module.mongodb_atlas.privatelink_connection_string` (see `modules/mongodb-atlas/outputs.tf` and the wiring in `envs/ec2/main.tf` → `module.lambda_mcp.mongodb_uri`). Do **not** patch it post-apply with `aws lambda update-function-configuration --environment "{Variables:{MONGODB_URI:..., MONGODB_DB:...}}"` — that overwrites the entire env map and silently drops `MONGODB_ALLOW_WRITE` and `MONGODB_MAX_LIMIT`. Phase 5c in `deploy.sh` no longer touches the Lambda for this reason; it only computes the same URI as a shell variable for the EC2 API + AgentCore runtime env injection downstream.

**Regression check:** `aws lambda get-function-configuration --function-name <project>-mongodb-mcp-<env> --query 'Environment.Variables.MONGODB_URI' --output text` must start with `mongodb://` (not `mongodb+srv://`) and contain `pl-` and `tlsAllowInvalidHostnames=true`. From CloudWatch, no `MongoAPIError: No addresses found at host` lines on a fresh chat-driven call.

**Code:** `deploy/terraform/modules/mongodb-atlas/outputs.tf` (`privatelink_connection_string`), `deploy/terraform/modules/mongodb-atlas/variables.tf` (`privatelink_endpoint_id`), `deploy/terraform/envs/ec2/main.tf` (passes VPCE id + reads PL URI).

---

## Voyage AI on SageMaker — three env surfaces, all required

**Symptom:** Agents respond "the catalog appears to be empty" to product/troubleshoot queries even after `voyage-3.5-lite` SageMaker endpoint is `InService` and `db-seeding/seed-embeddings.ts` has written 1024-d Voyage embeddings into Atlas.

**Cause:** Voyage works only when **four** independently-configured surfaces all line up:

1. **EC2 API** (`.env.live` → `/opt/multiagent/.env.live`) — used when the API embeds queries directly (in-process / fallback path).
2. **AgentCore Runtime env vars** (orchestrator + 3 specialists) — used when the runtime embeds queries before calling the Lambda MCP `mongodb_vector_search` tool. Updated via `aws bedrock-agentcore-control update-agent-runtime --environment-variables ...` in `deploy.sh` Phase 6b.
3. **AgentCore Runtime IAM role** must grant `sagemaker:InvokeEndpoint` on the Voyage endpoint ARN. Wired via the `voyage_sagemaker_endpoint_arn` input on the `agentcore-agent-runtime` Terraform module → `SageMakerInvoke` statement in the inline `AgentCoreRuntimePermissions` policy. Without this, every runtime call to Voyage returns `AccessDenied` and `embedQueryText` (in `api/src/lib/embed-query.ts`) silently falls back to Bedrock Titan — visible only as `embeddingSource: "bedrock"` in the `mongo.vector_search` trace event.
4. **Atlas vector index dimensions must match the request `output_dimension`.** voyage-3.5-lite defaults to **2048-d** but our index is sized for **1024-d** (Titan v2 wire-compat). The adapter must pass `output_dimension: 1024` and the seed script must do the same — both honour `VOYAGE_OUTPUT_DIM` env (default `1024`).

If any one is missing the call falls through to Bedrock Titan, returns Titan-1024-d vectors against a Voyage-1024-d-seeded index, and similarity scores collapse to ~0.50 (vs ~0.72-0.79 with Voyage primary) — the agent still answers but with degraded recall.

**Rule:** When changing the embedding provider/dimension, walk all four surfaces. `deploy.sh` already handles (1) + (2); the IAM permission (3) ships in `deploy/terraform/modules/agentcore-agent-runtime` (`SageMakerInvoke` statement, conditional on `voyage_sagemaker_endpoint_arn`); dimension (4) is enforced in `api/src/adapters/voyage-embedding.ts` and `db-seeding/seed-embeddings.ts`. A re-seed (`REWIRE_EMBEDDINGS=1`) is required whenever the provider or dimension changes — old embeddings live in a different vector space.

**Regression check:** From a Cognito-authed chat, send "I need waterproof outdoor headphones, IP67, under $80" against `agentId=product-recommendation`. In the SSE stream, look for `event: trace` lines with `"type":"mongo.vector_search"`. Expected: `embeddingSource: "voyage"`, `embeddingModelId: "voyage-3.5-lite"`, `length: 1024`, top scores in the `0.7-0.8` range. If you see `embeddingSource: "bedrock"` and scores ~0.5, walk the four surfaces above starting with `aws iam get-role-policy --role-name <project>-<agent>-<env>-role --policy-name AgentCoreRuntimePermissions` to confirm the `SageMakerInvoke` statement is present.

---

## Bedrock model defaults rot — newly-granted accounts can't access `claude-3-5-haiku-20241022`

**Symptom:** Long-term memory writes silently no-op on a fresh deploy. CloudWatch (or `docker logs multiagent-api`) shows:

```
[memory] LLM fact extractor failed; skipping long-term write
error: "Model access is denied due to IAM user or service role is not authorized
to perform the required AWS Marketplace actions (aws-marketplace:ViewSubscriptions,
aws-marketplace:Subscribe) to enable access to this model."
```

A `memory.long_term_skip` trace event with `reason: "llm_extractor_failed"` is emitted per turn. The agent answers correctly but no facts are ever written to `agent_memory_facts`, so cross-session recall ("I told you I have a peanut allergy") returns "I don't have any information about that".

**Cause:** The previous default for `DEFAULT_LLM_EXTRACTOR_MODEL_ID` (`us.anthropic.claude-3-5-haiku-20241022-v1:0`) is now **deprecated** on AWS Bedrock. On accounts granted **after** the deprecation, ticking "Anthropic Claude 3.5 Haiku" in the Bedrock console does **not** grant access — invocations fail Marketplace subscription verification with no path to fix from the console. The error message blames IAM/marketplace permissions but no IAM policy change actually unblocks it.

**Rule:** The extractor default must be a Bedrock model id that (a) supports tool use (the `record_facts` schema is tool-forced), (b) is enabled by default on freshly granted accounts in `us-*` regions. Current pick: `us.anthropic.claude-haiku-4-5-20251001-v1:0` (Claude Haiku 4.5 CRI). When AWS deprecates Haiku 4.5 in turn, this default must move forward in the same change as the docs (`docs/memory-architecture.md`, `give client/fresh-account-deployment-prerequisites.md`, `DEV_STATUS.md`, `AGENTS.md`).

**Regression check:** After a fresh deploy, run two consecutive `/chat` turns against an agent with `memory.longTerm: true` (e.g. `product-recommendation`). Turn 1 says "I have a peanut allergy". Wait 5s. Turn 2 (same Cognito user, new sessionId) asks "what allergies do I have?". The reply must mention "peanut". If it says "I don't have any information", check `docker logs multiagent-api --tail 200 | grep "LLM fact extractor failed"` first — the issue is almost always model access, not the wiring.

**Code:** `api/src/lib/llm-fact-extractor.ts` (`DEFAULT_LLM_EXTRACTOR_MODEL_ID`). Operational override: `MEMORY_EXTRACTION_MODEL_ID` env var on the API process (not the AgentCore Runtime — the extractor runs in the API container).

---

## Strands TS SDK + OTel — global tracer provider version drift kills `gen_ai.*` spans

**Symptom:** `validate-strands-otel.ts` passes, the Bun API boots, but **no `gen_ai.*` spans land in `aws/spans`** — even though our own `multiagent.*` spans (chat.turn, agentcore.invoke) appear correctly. The CloudWatch GenAI Observability **Agents** tab shows the runtime activity but the inner cycle/model spans are missing.

**Cause:** the Strands TS SDK declares `@opentelemetry/api`, `@opentelemetry/sdk-trace-base`, `@opentelemetry/sdk-trace-node`, `@opentelemetry/resources`, `@opentelemetry/exporter-trace-otlp-http`, and `@opentelemetry/exporter-metrics-otlp-http` as **peer dependencies** pinned to the OTel **1.30.x** SDK line (and the matching `^0.57.x` exporters). When `api/package.json` bumps them outside that range — for example to the OTel `2.x` SDK line that ships an incompatible `Resource` API — npm/bun either (a) resolves **two** copies of `sdk-trace-base` (one nested under `node_modules/@strands-agents/sdk/node_modules/`, one at the top level) where each installs its own `ProxyTracerProvider` and our `initOtel()` only binds the top-level copy, or (b) makes Strands fail at import time because the `Resource` / `BatchSpanProcessor` shapes changed. Either way the **Bedrock GenAI Observability "Agents" tab loses every `gen_ai.*` span**.

**Rule:** when bumping any `@opentelemetry/*` dependency in `api/package.json`:

1. Read `node_modules/@strands-agents/sdk/package.json` `peerDependencies` first; **stay inside the declared range** (today: `sdk-trace-*` `^1.30.1`, exporters `^0.57.2`).
2. Run `bun install` and then `ls node_modules/@strands-agents/sdk/node_modules/@opentelemetry` — if the directory exists, you've split the provider; downgrade until it disappears.
3. Run `bun run validate:strands-otel` (must print `ProxyTracerProvider -> NodeTracerProvider OK` **and** `emitted gen_ai.* test span OK`).

The smoke `bun run validate:strands-otel` only catches the case where the global provider is fully Noop; it does NOT catch the dual-provider case (the global is real, Strands' is shadow-Noop). If you suspect this, add temporary `console.error(...)` inside Strands' own model span emitter to confirm whether it ever fires.

**Code:** [`api/package.json`](api/package.json) (OTel deps), [`api/src/lib/otel.ts`](api/src/lib/otel.ts) (`initOtel`), [`api/scripts/validate-strands-otel.ts`](api/scripts/validate-strands-otel.ts) (smoke).

---

## Appendix — future entries

Add new sections above this appendix only when the **persistent pitfalls** bar is met (see Purpose). Put merge blockers or hung-test hazards near the top under **Do not regress**.
