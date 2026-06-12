/**
 * `redactSpanAttributes` is the export-time backstop that scrubs EVERY span
 * (ours + Strands `gen_ai.*` Tool spans) before the OTLP exporter ships it to
 * CloudWatch `/aws/spans`. Unlike `TraceCollector.flattenAttrs`, this runs on
 * spans emitted by the Strands SDK directly, so it is the surface that catches
 * a gen_ai Tool span carrying raw MongoDB args / returned-doc PII.
 *
 * Two layers, mirroring the log + TraceCollector paths:
 *   A. attribute keys whose final segment names a sensitive carrier are summarised
 *   B. every remaining string value is run through the email/phone mask
 */

import { afterEach, describe, expect, test } from "bun:test";
import { redactSpanAttributes, RedactingSpanProcessor } from "../../src/lib/otel.ts";

const TEST_EMAIL = "uat-redaction-test-123@example.com";
const TEST_NAME = "Jane Q. Customer of 12 Privacy Lane";

afterEach(() => {
  delete process.env.MCP_LOG_RAW_ARGS;
});

describe("redactSpanAttributes", () => {
  test("Layer A: summarises sensitive-segment keys (incl. gen_ai tool carriers)", () => {
    const attrs: Record<string, unknown> = {
      "gen_ai.tool.arguments": JSON.stringify({ collection: "orders", filter: { customerEmail: TEST_EMAIL } }),
      "gen_ai.tool.input": JSON.stringify({ filter: { customerEmail: TEST_EMAIL } }),
      "multiagent.payload.args.filter": JSON.stringify({ customerEmail: TEST_EMAIL }),
      "tool.result": JSON.stringify([{ customerEmail: TEST_EMAIL }]),
      "x.queryVector": [0.1, 0.2, 0.3],
    };
    redactSpanAttributes(attrs as never);

    expect(attrs["gen_ai.tool.arguments"]).toMatch(/^\[string len=\d+\]$/);
    expect(attrs["gen_ai.tool.input"]).toMatch(/^\[string len=\d+\]$/);
    expect(attrs["multiagent.payload.args.filter"]).toMatch(/^\[string len=\d+\]$/);
    expect(attrs["tool.result"]).toMatch(/^\[string len=\d+\]$/);
    expect(attrs["x.queryVector"]).toBe("[array len=3]");

    expect(JSON.stringify(attrs)).not.toContain(TEST_EMAIL);
  });

  test("Layer B: masks email under a non-sensitive key (string value backstop)", () => {
    const attrs: Record<string, unknown> = {
      "gen_ai.agent.description": `please email ${TEST_EMAIL} now`,
      "http.url": "https://api.example.test/v1/orders",
    };
    redactSpanAttributes(attrs as never);

    expect(attrs["gen_ai.agent.description"]).toBe("please email [email] now");
    expect(attrs["http.url"]).toBe("https://api.example.test/v1/orders");
  });

  test("summarises gen_ai message-content carriers wholesale (free-text PII, no pattern)", () => {
    // These are the actual keys Strands emits tool args / results / messages
    // under. The values carry names/addresses with NO detectable pattern, so
    // only wholesale summarisation guarantees they never reach /aws/spans.
    const attrs: Record<string, unknown> = {
      content: JSON.stringify({ filter: { name: TEST_NAME } }), // gen_ai.tool.message
      message: JSON.stringify([{ customer: TEST_NAME }]), // gen_ai.choice (tool result)
      "gen_ai.input.messages": JSON.stringify([{ role: "tool", parts: [{ arguments: { name: TEST_NAME } }] }]),
      "gen_ai.output.messages": JSON.stringify([{ role: "tool", parts: [{ response: TEST_NAME }] }]),
      "gen_ai.system_instructions": JSON.stringify([{ type: "text", content: TEST_NAME }]),
      system_prompt: JSON.stringify({ persona: TEST_NAME }),
    };
    redactSpanAttributes(attrs as never);

    for (const k of Object.keys(attrs)) {
      expect(String(attrs[k])).toMatch(/^\[string len=\d+\]$/);
    }
    expect(JSON.stringify(attrs)).not.toContain("Privacy Lane");
  });

  test("Layer B: masks email inside string-array attribute values", () => {
    const attrs: Record<string, unknown> = { "some.list": [`${TEST_EMAIL}`, "plain"] };
    redactSpanAttributes(attrs as never);
    expect(attrs["some.list"]).toEqual(["[email]", "plain"]);
  });

  test("leaves safe scalars and undefined entries untouched", () => {
    const attrs: Record<string, unknown> = { "gen_ai.usage.count": 5, "ok": true, "missing": undefined };
    redactSpanAttributes(attrs as never);
    expect(attrs["gen_ai.usage.count"]).toBe(5);
    expect(attrs["ok"]).toBe(true);
    expect(attrs["missing"]).toBeUndefined();
  });

  test("MCP_LOG_RAW_ARGS=true disables span scrubbing (operator opt-in)", () => {
    process.env.MCP_LOG_RAW_ARGS = "true";
    const attrs: Record<string, unknown> = {
      "gen_ai.tool.arguments": JSON.stringify({ filter: { customerEmail: TEST_EMAIL } }),
      content: `email ${TEST_EMAIL}`,
    };
    redactSpanAttributes(attrs as never);
    expect(String(attrs["gen_ai.tool.arguments"])).toContain(TEST_EMAIL);
    expect(attrs["content"]).toBe(`email ${TEST_EMAIL}`);
  });
});

describe("RedactingSpanProcessor.onEnd", () => {
  // Strands emits tool args / results as span EVENTS (gen_ai.tool.message,
  // gen_ai.choice, …), not span attributes. This verifies the processor scrubs
  // event attributes too — the surface where MongoDB args/returned-docs land.
  function fakeSpan(): { attributes: Record<string, unknown>; events: Array<{ name: string; attributes: Record<string, unknown> }> } {
    return {
      attributes: { "gen_ai.tool.name": "mongodb_query", "gen_ai.tool.call.id": "tc-1" },
      events: [
        { name: "gen_ai.tool.message", attributes: { role: "tool", content: JSON.stringify({ filter: { customerEmail: TEST_EMAIL, name: TEST_NAME } }), id: "tc-1" } },
        { name: "gen_ai.choice", attributes: { message: JSON.stringify([{ _id: "1", buyer: TEST_NAME, email: TEST_EMAIL }]), id: "tc-1" } },
      ],
    };
  }

  test("scrubs tool args + results carried as span events", () => {
    const proc = new RedactingSpanProcessor();
    const span = fakeSpan();
    proc.onEnd(span as never);

    // Safe metadata preserved.
    expect(span.attributes["gen_ai.tool.name"]).toBe("mongodb_query");
    // Content carriers summarised — no raw email or free-text name survives.
    expect(String(span.events[0].attributes.content)).toMatch(/^\[string len=\d+\]$/);
    expect(String(span.events[1].attributes.message)).toMatch(/^\[string len=\d+\]$/);
    const serialized = JSON.stringify(span);
    expect(serialized).not.toContain(TEST_EMAIL);
    expect(serialized).not.toContain("Privacy Lane");
  });

  test("onEnd never throws even on a malformed span", () => {
    const proc = new RedactingSpanProcessor();
    expect(() => proc.onEnd({ attributes: undefined, events: undefined } as never)).not.toThrow();
  });
});
