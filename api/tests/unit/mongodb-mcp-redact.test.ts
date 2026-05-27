import { afterEach, describe, expect, test } from "bun:test";
// MongoDB MCP server-side log redaction (P0-4). Lock in the redaction guard so
// no PII-bearing field can land in CloudWatch. This API-side unit test keeps a
// local copy of the tiny redaction contract so it does not need to import the
// sibling MCP runtime's MongoDB driver tree. The runtime-level security audit
// still imports `mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs` directly.
const PII_ARG_KEYS = new Set([
  "filter",
  "query",
  "document",
  "documents",
  "update",
  "queryVector",
  "pipeline",
  "projection",
  "sort",
]);

function summariseValue(v: unknown): unknown {
  if (v == null) return null;
  if (Array.isArray(v)) return `[array len=${v.length}]`;
  const t = typeof v;
  if (t === "string") return `[string len=${(v as string).length}]`;
  if (t === "number" || t === "boolean") return `[${t}]`;
  if (t === "object") return `[object keys=${Object.keys(v as Record<string, unknown>).length}]`;
  return `[${t}]`;
}

function redactArgsForLog(args: unknown): unknown {
  if (!args || typeof args !== "object") return args;
  if (process.env.MCP_LOG_RAW_ARGS === "true") return args;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(args as Record<string, unknown>)) {
    out[k] = PII_ARG_KEYS.has(k) ? summariseValue(v) : v;
  }
  return out;
}

function redactEventForLog(event: unknown): unknown {
  if (!event || typeof event !== "object") return event;
  if (process.env.MCP_LOG_RAW_ARGS === "true") return event;
  const shallow = { ...(event as Record<string, unknown>) };
  for (const k of ["toolArguments", "arguments", "parameters", "input", "args"]) {
    if (shallow[k] && typeof shallow[k] === "object") shallow[k] = redactArgsForLog(shallow[k]);
  }
  if (shallow.body) {
    try {
      const body = typeof shallow.body === "string" ? JSON.parse(shallow.body) : shallow.body;
      if (body && body.params && body.params.arguments) {
        body.params = { ...body.params, arguments: redactArgsForLog(body.params.arguments) };
      }
      shallow.body = body;
    } catch {
      // body wasn't JSON; leave it alone
    }
  }
  return shallow;
}

function redactErrorForLog(err: unknown): unknown {
  if (!err) return err;
  const message = err instanceof Error ? err.message : String(err);
  const truncated = message.length > 500 ? `${message.slice(0, 500)}…` : message;
  return {
    name: err instanceof Error ? err.name : undefined,
    code: typeof err === "object" && err !== null ? (err as { code?: unknown }).code : undefined,
    message: truncated,
  };
}

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

  test("MCP_LOG_RAW_ARGS=true preserves the raw args (operator opt-in)", () => {
    process.env.MCP_LOG_RAW_ARGS = "true";
    const result = redactArgsForLog({
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
