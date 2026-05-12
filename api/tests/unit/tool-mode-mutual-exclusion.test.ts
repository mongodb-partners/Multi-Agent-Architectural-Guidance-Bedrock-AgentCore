import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { toolsForAgent } from "../../src/lib/base-tools.ts";
import { SkillRegistry } from "../../src/lib/skill-loader.ts";
import { runMongoDataQuery } from "../../src/adapters/mongo-data.ts";

const MONGO_TOOL_NAMES = ["mongodb_query", "mongodb_vector_search"];

describe("tool-mode mutual exclusion", () => {
  let savedMode: string | undefined;
  beforeEach(() => {
    savedMode = process.env.TOOL_HOSTING_MODE;
  });
  afterEach(() => {
    if (savedMode === undefined) delete process.env.TOOL_HOSTING_MODE;
    else process.env.TOOL_HOSTING_MODE = savedMode;
  });

  test("toolsForAgent includes in-process Mongo tools by default (excludeMongoTools omitted)", () => {
    const registry = new SkillRegistry([]);
    const tools = toolsForAgent([...MONGO_TOOL_NAMES, "bedrock_kb_retrieve"], registry);
    const names = tools.map((t) => t.toolSpec.name);
    for (const m of MONGO_TOOL_NAMES) {
      expect(names).toContain(m);
    }
    expect(names).toContain("bedrock_kb_retrieve");
  });

  test("toolsForAgent drops in-process Mongo tools when excludeMongoTools=true (gateway mode)", () => {
    const registry = new SkillRegistry([]);
    const tools = toolsForAgent(
      [...MONGO_TOOL_NAMES, "bedrock_kb_retrieve"],
      registry,
      { excludeMongoTools: true },
    );
    const names = tools.map((t) => t.toolSpec.name);
    for (const m of MONGO_TOOL_NAMES) {
      expect(names).not.toContain(m);
    }
    // Non-Mongo tools must remain.
    expect(names).toContain("bedrock_kb_retrieve");
  });

  test("toolsForAgent excludes mongodb_aggregate when excludeMongoTools=true (covers MCP-only name)", () => {
    const registry = new SkillRegistry([]);
    const tools = toolsForAgent(["mongodb_aggregate"], registry, { excludeMongoTools: true });
    const names = tools.map((t) => t.toolSpec.name);
    expect(names).not.toContain("mongodb_aggregate");
  });

  test("runMongoDataQuery throws a programming error when TOOL_HOSTING_MODE=gateway", async () => {
    process.env.TOOL_HOSTING_MODE = "gateway";
    await expect(
      runMongoDataQuery({ collection: "orders", operation: "find" }),
    ).rejects.toThrow(/gateway/i);
  });

  test("runMongoDataQuery does NOT throw in lambda/direct mode (guard is mode-scoped)", async () => {
    // In lambda mode without LAMBDA_MCP_FUNCTION_NAME set, the function
    // returns a not_configured status rather than throwing — exactly the
    // behavior the gateway guard must NOT short-circuit.
    process.env.TOOL_HOSTING_MODE = "lambda";
    const savedFn = process.env.LAMBDA_MCP_FUNCTION_NAME;
    const savedArn = process.env.LAMBDA_MCP_FUNCTION_ARN;
    delete process.env.LAMBDA_MCP_FUNCTION_NAME;
    delete process.env.LAMBDA_MCP_FUNCTION_ARN;
    try {
      const out = await runMongoDataQuery({ collection: "orders", operation: "find" });
      // Result is structured (not_configured / error / etc.) — the important
      // assertion is that we did NOT throw the gateway guard error.
      expect(typeof out).toBe("object");
    } finally {
      if (savedFn !== undefined) process.env.LAMBDA_MCP_FUNCTION_NAME = savedFn;
      if (savedArn !== undefined) process.env.LAMBDA_MCP_FUNCTION_ARN = savedArn;
    }
  });
});
