# MongoDB MCP Lambda

Custom Lambda target for AgentCore Gateway — exposes MongoDB Atlas as MCP tools.

## Tools

| Name                    | Args                                                                          |
|-------------------------|-------------------------------------------------------------------------------|
| `mongodb_query`         | `collection`, `operation`, `filter?`/`query?`, `projection?`, `sort?`, `limit?`, `pipeline?`, `update?`, `document?` |
| `mongodb_vector_search` | `collection`, `index`, `queryVector`, `path?`, `numCandidates?`, `limit?`, `filter?` |
| `mongodb_aggregate`     | `collection`, `pipeline`, `limit?`                                            |

`mongodb_query.operation` is restricted to `find | findOne | aggregate | insertOne | updateOne`.

## Shared guards

All validation rules live in [`guards.mjs`](./guards.mjs) (with TypeScript declarations in [`guards.d.mts`](./guards.d.mts)) and are imported by **both**:

- [`index.mjs`](./index.mjs) — this Lambda handler
- [`api/src/adapters/mongo-data.ts`](../../api/src/adapters/mongo-data.ts) — the in-process path used by the Hono API in dev and on EC2

This means an LLM that issues e.g. `operation: "deleteOne"` will be refused with the same error in both deployments. `api/Dockerfile` copies `guards.mjs` + `guards.d.mts` into the API image so the relative import resolves at runtime as well as at build time.

## Observability — trace events flow back to the Trace Viewer

The handler builds a per-invocation trace collector ([`tracing.mjs`](./tracing.mjs)) and emits the same event types the in-process path uses (`mongo.intent`, `mongo.query`, `mongo.schema`, `mongo.plan`, `mongo.result`, `mongo.diagnostic`). The collector enforces a 64 KB / 64-event cap so a runaway invocation can't bloat the response.

Events are shipped back to the caller two ways:

| Path | Caller | How events arrive |
|------|--------|-------------------|
| **A. API/Runtime → Lambda direct** (`TOOL_HOSTING_MODE=lambda`, **default**, `LambdaClient.invoke`) | `api/src/adapters/mongo-data.ts` invokeLambdaTool branch | Top-level `out.meta.traces` on the Lambda response; replayed straight into `currentTrace()`. |
| **B. AgentCore Runtime → Gateway → Lambda** (opt-in via `GATEWAY_DEMO_RUNTIMES` in [`env.sh`](../../env.sh); `TOOL_HOSTING_MODE=gateway`) | The `mongodb-mcp-client.ts` wrapper inside the AgentCore agent-runtime bundle | Encoded inside `content[0].text` as `JSON.stringify({ result, meta: { traces } })` (only fields under `content[]` survive AgentCore Gateway's MCP wrapping). The wrapper parses, replays into the runtime's local trace, and rewrites `content[0].text` to plain `JSON.stringify(result)` so the LLM never sees the trace data. The agent-runtime then bundles its local trace events into `data.traceEvents`, and the Hono API's `agentcore-runtime.ts` splices them via `trace.attachEventsNested(...)`. |

The two modes are mutually exclusive per runtime: in lambda mode the agent has only in-process Mongo tools attached; in gateway mode it has only the MCP tools served from the Gateway target. See [`AGENTS.md`](../../AGENTS.md) and [`docs/architecture.md`](../../docs/architecture.md) §7.1 for the rationale.

Net effect: the Trace Viewer renders identical `mongo.*` cards whether the operation ran in-process, through the API-direct Lambda path, or through the production AgentCore path. Diagnostic walker / explain plan capture are gated by the same env vars as the in-process path (`MONGO_TRACE_DIAGNOSTIC`, `MONGO_TRACE_EXPLAIN`, `MONGO_TRACE_SCHEMA_SAMPLE`).

## Safety model

Defense in depth, in addition to the Atlas DB user's role:

| Layer | What it does |
|-------|--------------|
| **Operation allowlist** | Only `find / findOne / aggregate / insertOne / updateOne` are dispatched. `deleteOne`, `deleteMany`, `drop`, `dropDatabase`, `bulkWrite`, `findOneAndDelete`, `findOneAndReplace`, `findOneAndUpdate`, `replaceOne`, `renameCollection`, `createIndex*` are refused with an explicit error rather than falling through. |
| **Write gate** | `insertOne` / `updateOne` require `MONGODB_ALLOW_WRITE=1`. Default is **read-only**. Mirrors `api/src/adapters/mongo-data.ts`. |
| **Non-empty filter on writes** | `updateOne` refuses an empty / missing filter so a malformed call can't quietly mutate an arbitrary document. |
| **Pipeline stage denylist** | Aggregation pipelines may not contain `$out`, `$merge`, `$function`, or `$accumulator` (write / code-exec stages). |
| **Query operator denylist** | Filters / updates / pipelines may not contain `$where` or `$function` (server-side JS). |
| **Database lockdown** | The `database` argument is refused. The handler always targets `MONGODB_DB` (or `bedrock_agents`). |
| **Collection sanity** | Collection names must match `/^[A-Za-z0-9_.-]+$/` and be ≤120 chars. |
| **Limit cap** | Read limits are clamped to `MONGODB_MAX_LIMIT` (default 200). |

The Atlas DB user this Lambda connects as **should still** be granted the minimum role needed (e.g. `readWrite` on the specific app database, **not** `atlasAdmin` and **not** `dbAdmin`). The guardrails above are belt-and-braces, not a substitute for that.

## Environment variables

| Variable               | Default            | Purpose |
|------------------------|--------------------|---------|
| `MONGODB_URI`          | _(required)_       | Atlas connection string. |
| `MONGODB_DB`           | `bedrock_agents`   | Target database. Callers cannot override. |
| `MONGODB_ALLOW_WRITE`  | _off_              | Set to `1` / `true` / `yes` to allow `insertOne` and `updateOne`. Off by default. |
| `MONGODB_MAX_LIMIT`    | `200`              | Maximum documents returned from `find` / `aggregate`, regardless of the caller's `limit`. |

The Terraform module exposes `allow_write` (bool, default `false`) and `max_limit` (number, default `200`) which set these env vars on the function. The EC2 env wires `var.mongodb_allow_write` straight through.

## Install dependencies before deploy

Terraform packages this directory as-is. Run `npm install` before `terraform apply`:

```bash
cd lambda/mongodb-mcp && npm install --omit=dev
```

`deploy.sh` does this automatically in Phase 5.5.

## Local test

```bash
MONGODB_URI="mongodb+srv://..." node -e "
  import('./index.mjs').then(m => m.handler({
    tool: 'mongodb_query',
    args: { collection: 'products', limit: 2 }
  })).then(r => console.log(JSON.stringify(r, null, 2)));
"
```

To exercise the write path locally:

```bash
MONGODB_URI="mongodb+srv://..." MONGODB_ALLOW_WRITE=1 node -e "
  import('./index.mjs').then(m => m.handler({
    tool: 'mongodb_query',
    args: {
      collection: 'support_tickets',
      operation: 'insertOne',
      document: { subject: 'test', body: 'hello' }
    }
  })).then(r => console.log(JSON.stringify(r, null, 2)));
"
```

Without `MONGODB_ALLOW_WRITE`, that call returns a 500 with `Error: writes are disabled — set MONGODB_ALLOW_WRITE=1 to allow insertOne`.
