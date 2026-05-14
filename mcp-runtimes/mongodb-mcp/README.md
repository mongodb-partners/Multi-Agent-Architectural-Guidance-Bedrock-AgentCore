# `mcp-runtimes/mongodb-mcp/` — MongoDB MCP server in an AgentCore Runtime

Streamable-HTTP MCP server that exposes the MongoDB tool surface
(`mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`) on
`0.0.0.0:8000/mcp`, conforming to the
[AgentCore Runtime MCP contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp.html).
This is the **only** MongoDB MCP host after CLIENT_REVIEW Phase 7e — the
legacy `lambda/mongodb-mcp/` Lambda host has been deleted. P1-1 (MongoDB MCP
runs in an AgentCore Runtime) and P1-2 (AgentCore Gateway is the production
tool path) are both satisfied.

## Tool semantics

The `tools` object, the safety guards (`guards.mjs`), the per-call trace
collector (`tracing.mjs`), and the diagnostics helpers (`diagnostics.mjs`)
all live in `src/vendor/` — the canonical home for the MongoDB MCP tool
implementations. The directory is bundled straight into the container image
under `dist/vendor/` (see [`Dockerfile`](./Dockerfile)).

The MCP response envelope is the contract consumed by
`api/src/adapters/mongodb-mcp-client.ts`'s `extractAndReplayMcpTraces` —
each tool call returns:

```jsonc
{
  "content": [{ "type": "text", "text": "{\"result\":...,\"meta\":{\"traces\":[...]}}" }]
}
```

## Build and run locally

```bash
cd mcp-runtimes/mongodb-mcp
npm install
npm run build
MONGODB_URI="mongodb+srv://…" npm start
```

Then MCP-Inspector:

```bash
npx @modelcontextprotocol/inspector
# transport = Streamable HTTP, URL = http://localhost:8000/mcp
```

## Deploy to AgentCore Runtime

The container is built and pushed to ECR by `deploy/scripts/deploy.sh`
(Phase 7d). `deploy/terraform/envs/ec2/main.tf` provisions an AgentCore
Runtime with `serverProtocol = MCP` pointing at this image, and an
AgentCore Gateway target of type `mcpServer` pointing at the runtime's
`https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<url-encoded-arn>/invocations?qualifier=DEFAULT`
endpoint.

## Why ARM64

AgentCore Runtime requires `linux/arm64` for MCP server images. The
`Dockerfile` enforces this with `--platform=linux/arm64` so a build on
amd64 macOS / amd64 EC2 still produces an ARM64 image (via QEMU under
buildx).

## Safety model

Implemented in [`src/vendor/guards.mjs`](./src/vendor/guards.mjs). Briefly:

- Operation allowlist (`find`, `findOne`, `aggregate`, `insertOne`, `updateOne`).
- Writes gated by `MONGODB_ALLOW_WRITE` (default off).
- Pipeline `$out` / `$merge` denylist; server-side-JS denylist.
- Database-override refusal.
- `MONGODB_MAX_LIMIT` cap (default 200).

## PII redaction

`MCP_LOG_RAW_ARGS` is unset by default, so `filter`, `query`, `document`,
`documents`, `update`, `queryVector`, `pipeline`, `projection`, `sort`
arguments never land in CloudWatch unredacted.
