/**
 * `TraceCollector` flattens event payloads into OTel span attributes that the
 * ADOT sidecar exports to CloudWatch `/aws/spans`. Because that path runs on
 * the RAW payload (the in-memory `redactPayload` only touches the stored
 * `events` array), raw MongoDB args and returned documents would leak into
 * span attributes without the two-layer redaction in `flattenAttrs`:
 *
 *   Layer A — `SENSITIVE_PAYLOAD_KEYS` (filter/document/queryVector/result/
 *             sampleDocs/documentPreviews/…) collapse to a shape summary.
 *   Layer B — every remaining leaf string is run through `maskPiiInString`.
 *
 * These tests capture exported spans via an InMemorySpanExporter and assert no
 * attribute key descends into a sensitive carrier and no attribute VALUE
 * contains the raw test email.
 */

import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import {
  BasicTracerProvider,
  InMemorySpanExporter,
  SimpleSpanProcessor,
} from "@opentelemetry/sdk-trace-base";
import { context, trace as otelTrace } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { TraceCollector } from "../../src/lib/trace-collector.ts";

const ctxMgr = new AsyncLocalStorageContextManager();
ctxMgr.enable();
context.setGlobalContextManager(ctxMgr);

const exporter = new InMemorySpanExporter();
const provider = new BasicTracerProvider({
  spanProcessors: [new SimpleSpanProcessor(exporter)],
});

// OTel's global tracer provider can only be set once per process, so when the
// whole unit suite runs another file may have claimed it first. Disable any
// existing global registration right before our tests so OUR exporter-backed
// provider is the one `TraceCollector` writes to. Runs in beforeAll (not at
// module load) so it wins regardless of test-file ordering.
beforeAll(() => {
  otelTrace.disable();
  otelTrace.setGlobalTracerProvider(provider);
});

const TEST_EMAIL = "uat-redaction-test-123@example.com";

function makeCollector() {
  return new TraceCollector({ sessionId: "s", messageId: "m", agentId: "order-management" });
}

/** Representative tool.mcp payload: request args + returned documents, both PII-bearing. */
function toolMcpPayload() {
  return {
    server: "gateway",
    toolName: "mongodb_query",
    latencyMs: 12,
    args: {
      collection: "orders",
      operation: "find",
      limit: 5,
      filter: { orderId: "o-1", customerEmail: TEST_EMAIL },
      queryVector: [0.1, 0.2, 0.3],
    },
    result: {
      documents: [{ _id: "ord-1", customerEmail: TEST_EMAIL }],
    },
    sampleDocs: [{ _id: "ord-1", buyer: TEST_EMAIL }],
    documentPreviews: [{ rank: 1, fields: { customerEmail: TEST_EMAIL } }],
  };
}

function attrsAfterEvent(payload: Record<string, unknown>): Record<string, unknown> {
  exporter.reset();
  const c = makeCollector();
  c.event("tool.mcp", payload);
  const spans = exporter.getFinishedSpans();
  expect(spans.length).toBeGreaterThan(0);
  // The most recent standalone span carries our flattened payload.
  return spans[spans.length - 1].attributes as Record<string, unknown>;
}

afterEach(() => {
  delete process.env.MCP_LOG_RAW_ARGS;
  exporter.reset();
});

describe("TraceCollector — span-attribute PII redaction", () => {
  test("collapses sensitive carriers and never expands filter/result/etc.", () => {
    const attrs = attrsAfterEvent(toolMcpPayload());
    const keys = Object.keys(attrs);

    // Layer A: sensitive carriers summarised, not expanded into nested keys.
    expect(attrs["multiagent.payload.args.filter"]).toBe("[object keys=2]");
    expect(attrs["multiagent.payload.args.queryVector"]).toBe("[array len=3]");
    expect(attrs["multiagent.payload.result"]).toBe("[object keys=1]");
    expect(attrs["multiagent.payload.sampleDocs"]).toBe("[array len=1]");
    expect(attrs["multiagent.payload.documentPreviews"]).toBe("[array len=1]");

    expect(keys.some((k) => k.startsWith("multiagent.payload.args.filter."))).toBe(false);
    expect(keys.some((k) => k.startsWith("multiagent.payload.result."))).toBe(false);
    expect(keys.some((k) => k.startsWith("multiagent.payload.sampleDocs."))).toBe(false);

    // Useful sibling scalars still flatten normally.
    expect(attrs["multiagent.payload.args.collection"]).toBe("orders");
    expect(attrs["multiagent.payload.args.operation"]).toBe("find");
    expect(attrs["multiagent.payload.args.limit"]).toBe(5);
    expect(attrs["multiagent.payload.toolName"]).toBe("mongodb_query");
    expect(attrs["multiagent.payload.latencyMs"]).toBe(12);
  });

  test("no attribute value contains the raw test email", () => {
    const attrs = attrsAfterEvent(toolMcpPayload());
    const serialized = JSON.stringify(Object.values(attrs));
    expect(serialized).not.toContain(TEST_EMAIL);
  });

  test("Layer B masks an email that surfaces under a non-sensitive key", () => {
    // `note` is not a sensitive carrier, so it flattens as a leaf string — the
    // value backstop must still mask the email.
    const attrs = attrsAfterEvent({
      toolName: "mongodb_query",
      note: `escalate to ${TEST_EMAIL} asap`,
    });
    expect(attrs["multiagent.payload.note"]).toBe("escalate to [email] asap");
  });

  test("MCP_LOG_RAW_ARGS=true disables span redaction (operator opt-in)", () => {
    process.env.MCP_LOG_RAW_ARGS = "true";
    const attrs = attrsAfterEvent(toolMcpPayload());
    const keys = Object.keys(attrs);
    // Raw passthrough: filter expands and the email is present verbatim.
    expect(keys.some((k) => k.startsWith("multiagent.payload.args.filter."))).toBe(true);
    expect(attrs["multiagent.payload.args.filter.customerEmail"]).toBe(TEST_EMAIL);
  });
});
