import { afterEach, describe, expect, test } from "bun:test";
// MongoDB MCP server-side log redaction (P0-4). Lock in the redaction guard so
// no PII-bearing field can land in CloudWatch from either the AgentCore Runtime
// MCP host (mcp-runtimes/mongodb-mcp/) or any future tool host that vendors
// these helpers from `src/vendor/handlers.mjs` (the canonical home after the
// CLIENT_REVIEW Phase 7e Lambda deletion).
// @ts-expect-error — .mjs has no type declarations; we treat the helpers as `unknown` and cast.
import * as vendor from "../../../mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs";

const { redactArgsForLog, redactEventForLog, redactErrorForLog } = vendor as {
  redactArgsForLog: (a: unknown) => unknown;
  redactEventForLog: (e: unknown) => unknown;
  redactErrorForLog: (e: unknown) => unknown;
};

afterEach(() => {
  delete process.env.MCP_LOG_RAW_ARGS;
});

describe("mongodb-mcp redaction (P0-4)", () => {
  test("redacts filter / document / queryVector by default", () => {
    const args = {
      collection: "customers",
      filter: { email: "alex@example.com" },
      document: { _id: "ord-1", customer: "alex" },
      queryVector: new Array(1024).fill(0.1),
      limit: 5,
    };
    const out = redactArgsForLog(args) as Record<string, unknown>;
    expect(out.collection).toBe("customers");
    expect(out.limit).toBe(5);
    expect(out.filter).toMatch(/^\[object/);
    expect(out.document).toMatch(/^\[object/);
    expect(out.queryVector).toMatch(/^\[array len=1024\]$/);
  });

  test("MCP_LOG_RAW_ARGS=true preserves the raw args (operator opt-in)", async () => {
    // The redaction switch is captured at module load. Bust the cache so the
    // new env var is picked up by a fresh import.
    process.env.MCP_LOG_RAW_ARGS = "true";
    const fresh = (await import(
      `../../../mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs?bust=${Date.now()}`
    )) as {
      redactArgsForLog: (a: unknown) => unknown;
    };
    const result = fresh.redactArgsForLog({
      filter: { email: "alex@example.com" },
    }) as { filter: { email: string } };
    expect(result.filter.email).toBe("alex@example.com");
  });

  test("redacts AgentCore-style event envelope (toolArguments)", () => {
    const event = {
      toolName: "mongodb_query",
      toolArguments: {
        collection: "orders",
        filter: { customerId: "abc-123" },
      },
    };
    const out = redactEventForLog(event) as {
      toolArguments: { collection: string; filter: string };
    };
    expect(out.toolArguments.collection).toBe("orders");
    expect(out.toolArguments.filter).toMatch(/^\[object/);
  });

  test("redacts MCP body envelope (params.arguments)", () => {
    const event = {
      body: JSON.stringify({
        method: "tools/call",
        params: {
          name: "mongodb_query",
          arguments: { collection: "tickets", filter: { status: "open" } },
        },
      }),
    };
    const out = redactEventForLog(event) as {
      body: { params: { arguments: { collection: string; filter: string } } };
    };
    expect(out.body.params.arguments.collection).toBe("tickets");
    expect(out.body.params.arguments.filter).toMatch(/^\[object/);
  });

  test("redactErrorForLog truncates long messages and only emits name/code/message", () => {
    const err = new Error("boom: " + "x".repeat(800));
    const out = redactErrorForLog(err) as { name: string; code?: string; message: string };
    expect(out.name).toBe("Error");
    expect(out.message.length).toBeLessThanOrEqual(501);
    expect(Object.keys(out).sort()).toEqual(["code", "message", "name"]);
  });
});
