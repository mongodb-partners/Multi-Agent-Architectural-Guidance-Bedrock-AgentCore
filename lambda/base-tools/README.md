# Base-tool Lambda adapters — retired (AgentCore Runtime path)

This directory previously held placeholder layouts for per-tool Lambda
adapters that would mirror the in-process Strands base tools
(`mongodb_query`, `mongodb_vector_search`, `bedrock_kb_retrieve`,
`generate_embedding`, `read_skill_resource`) so AgentCore Gateway could
invoke them as standalone Lambdas. That design was superseded by the
AgentCore Runtime tool host: per-tool Lambdas would duplicate logic that
is already consolidated in the runtime, so the placeholders were removed
in `P2-5` (Phase 9 of the client review).

The current canonical paths are:

| Tool | Where it lives now |
|------|--------------------|
| `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate` | [`mcp-runtimes/mongodb-mcp/`](../../mcp-runtimes/mongodb-mcp/) — MongoDB MCP server packaged as the **`bedrock-ma-use1-mongodb-mcp-runtime-dev`** AgentCore Runtime, registered as the AgentCore Gateway target by [`deploy/terraform/modules/agentcore-gateway/main.tf`](../../deploy/terraform/modules/agentcore-gateway/main.tf). |
| `bedrock_kb_retrieve`, `generate_embedding`, `read_skill_resource` | In-process tools in [`api/src/lib/base-tools.ts`](../../api/src/lib/base-tools.ts), composed inside each agent runtime via [`api/src/lib/create-strands-agent.ts`](../../api/src/lib/create-strands-agent.ts). They run inside the AgentCore Runtime container alongside the Strands `Agent`. |

All three remaining MongoDB tools are exposed to the orchestrator + specialist
runtimes through the AgentCore Gateway → MongoDB MCP runtime path. There is no
direct-mode Lambda variant of these tools, and no plan to revive one — adding a
new tool means extending the MCP runtime (or `base-tools.ts` for in-process
helpers), not adding a new Lambda here.

The legacy `lambda/mongodb-mcp/` Lambda host has been deleted in
CLIENT_REVIEW Phase 7e. The canonical implementation now lives in
[`mcp-runtimes/mongodb-mcp/src/vendor/`](../../mcp-runtimes/mongodb-mcp/src/vendor/);
to roll the Lambda back, restore both `lambda/mongodb-mcp/` and
`deploy/terraform/modules/lambda-mcp/` from git history.

See:

- [`docs/architecture.md`](../../docs/architecture.md) for the Gateway → MCP runtime tool flow.
- [`docs/deployment-guide.md`](../../docs/deployment-guide.md) for the deploy story.
- [`CLIENT_REVIEW_TASKS.md`](../../CLIENT_REVIEW_TASKS.md) `P2-5` and [`CLIENT_REVIEW_EXPLAINER.md`](../../CLIENT_REVIEW_EXPLAINER.md) `P2-5` for the rationale.
