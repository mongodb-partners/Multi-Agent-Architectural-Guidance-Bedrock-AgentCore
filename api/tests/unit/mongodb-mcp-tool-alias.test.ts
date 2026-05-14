/**
 * Unit pin: AgentCore Gateway tool-name alias contract.
 *
 * The gateway publishes every tool from the `mongodb-mcp` Lambda target as
 * `mongodb-mcp___<tool>`, but agent personas (and the LLM's training)
 * reference the unprefixed name. `mongodb-mcp-client.ts` wraps each
 * gateway-prefixed `McpTool` in an `AliasedMcpTool` so the model sees the
 * unprefixed name while the underlying MCP call still goes out under the
 * gateway-prefixed name (which is what `McpClient.callTool(tool, args)`
 * forwards to the gateway).
 *
 * If this contract regresses, the model emits `mongodb_query` tool calls,
 * Strands cannot find the tool in its registry (it only has
 * `mongodb-mcp___mongodb_query`), and the call silently no-ops. The agent
 * then narrates that it would like to query the database. This was the
 * "I don't have access to mongodb_query" behavior we hit in production
 * after the cleanup; pinning it here keeps the alias from drifting.
 */

import { describe, expect, test } from "bun:test";
import {
  AliasedMcpTool,
  GATEWAY_TARGET_PREFIX,
  stripGatewayTargetPrefix,
} from "../../src/adapters/mongodb-mcp-client.ts";

describe("AgentCore Gateway tool-name alias", () => {
  test("strips the mongodb-mcp___ prefix", () => {
    expect(stripGatewayTargetPrefix("mongodb-mcp___mongodb_query")).toBe("mongodb_query");
    expect(stripGatewayTargetPrefix("mongodb-mcp___mongodb_aggregate")).toBe(
      "mongodb_aggregate",
    );
    expect(stripGatewayTargetPrefix("mongodb-mcp___mongodb_vector_search")).toBe(
      "mongodb_vector_search",
    );
  });

  test("returns undefined for non-prefixed tool names so they pass through", () => {
    expect(stripGatewayTargetPrefix("mongodb_query")).toBeUndefined();
    expect(stripGatewayTargetPrefix("read_skill_resource")).toBeUndefined();
  });

  test("prefix matches the Terraform target_name", () => {
    // If you change the Terraform target_name in
    // deploy/terraform/modules/agentcore-gateway/main.tf, update both places.
    expect(GATEWAY_TARGET_PREFIX).toBe("mongodb-mcp___");
  });

  test("AliasedMcpTool exposes the alias name to Strands while delegating stream() to the underlying tool", () => {
    let streamCalledOnUnderlying = false;
    const fakeUnderlying = {
      name: "mongodb-mcp___mongodb_query",
      description: "Query MongoDB collections via the gateway",
      toolSpec: {
        name: "mongodb-mcp___mongodb_query",
        description: "Query MongoDB collections via the gateway",
        inputSchema: {
        type: "object" as const,
        properties: { collection: { type: "string" as const } },
      },
      },
      stream: () => {
        streamCalledOnUnderlying = true;
        // Yield nothing, return a sentinel — exercising the delegation only.
        return (async function* () {
          return { sentinel: true } as unknown as never;
        })();
      },
      // Plus the private fields McpTool carries; we don't touch them here.
    };

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const aliased = new AliasedMcpTool("mongodb_query", fakeUnderlying as any);

    expect(aliased.name).toBe("mongodb_query");
    expect(aliased.description).toBe(fakeUnderlying.description);
    expect(aliased.toolSpec.name).toBe("mongodb_query");
    expect(aliased.toolSpec.inputSchema).toBe(fakeUnderlying.toolSpec.inputSchema);

    // Calling stream() on the alias must dispatch through the underlying tool.
    // That is what makes `McpClient.callTool(this.underlying, ...)` use the
    // gateway-prefixed name on the wire — losing this delegation means the
    // gateway gets `mongodb_query` and 404s with "Unknown tool".
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    aliased.stream({} as any);
    expect(streamCalledOnUnderlying).toBe(true);
  });
});
