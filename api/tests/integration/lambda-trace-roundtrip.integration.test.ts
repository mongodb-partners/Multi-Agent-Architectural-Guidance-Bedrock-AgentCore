/**
 * Integration probe: Lambda → MCP wrapper trace round-trip contract.
 *
 * The Lambda MCP target (lambda/mongodb-mcp/index.mjs) packs per-invocation
 * trace events into each text content block of its MCP response:
 *
 *   content[0].text = JSON.stringify({
 *     result: <tool result>,
 *     meta:   { traces: [{type, payload, ts, id?}, ...], tracesDropped?: n },
 *   })
 *
 * On the API side, `extractAndReplayLambdaTraces` (in
 * api/src/adapters/mongodb-mcp-client.ts) must:
 *
 *   1. Replay each `meta.traces[*]` event into the per-turn TraceCollector via
 *      `trace.event(type, payload)`, so the Trace Viewer renders identical
 *      mongo.* cards whether the operation ran in-process, through the API-
 *      direct Lambda path, or through the AgentCore Runtime path.
 *   2. Rewrite each text block to `JSON.stringify(parsed.result)` so the
 *      LLM-visible portion contains only the result — no `meta` noise.
 *   3. Return the running total of `meta.tracesDropped` for telemetry.
 *   4. Silently no-op on anything that isn't an envelope (other MCP tools,
 *      non-JSON text, malformed envelopes), so it stays safe to call against
 *      every MCP response.
 *
 * Breaking any of those would silently regress trace parity for the demo
 * (AgentCore Runtime) path — exactly the path client demos use. This test
 * pins the contract.
 */

import { describe, expect, test } from "bun:test";
import { extractAndReplayLambdaTraces } from "../../src/adapters/mongodb-mcp-client.ts";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import { withTrace } from "../../src/lib/trace-context.ts";
import type { TraceEvent } from "../../src/lib/trace-types.ts";

function makeCollector(): { collector: TraceCollector; captured: TraceEvent[] } {
  const collector = new TraceCollector({
    sessionId: "t-sess",
    messageId: "t-msg",
    agentId: "test-agent",
  });
  const captured: TraceEvent[] = [];
  collector.onEvent((ev) => captured.push(ev));
  return { collector, captured };
}

/** Build an envelope identical in shape to what lambda/mongodb-mcp/index.mjs returns. */
function makeEnvelope(
  result: unknown,
  traces: Array<{ type: string; payload: Record<string, unknown>; ts?: number; id?: string }>,
  tracesDropped?: number,
) {
  const meta: { traces: typeof traces; tracesDropped?: number } = { traces };
  if (typeof tracesDropped === "number") meta.tracesDropped = tracesDropped;
  return {
    content: [{ type: "text", text: JSON.stringify({ result, meta }) }],
    // Real Lambda responses also include `data` + `meta` as siblings, but the
    // MCP gateway only forwards `content[]`, so only that surface matters here.
  };
}

describe("Lambda MCP trace round-trip contract", () => {
  test("replays mongo.* events into the active TraceCollector and strips meta from content", () => {
    const { collector, captured } = makeCollector();

    const envelope = makeEnvelope(
      [{ orderId: "ORD-1", status: "shipped" }],
      [
        { type: "mongo.intent", payload: { collection: "orders" } },
        {
          type: "mongo.query",
          payload: { mode: "lambda", collection: "orders", op: "find", limit: 50 },
        },
        {
          type: "mongo.schema",
          payload: { collection: "orders", sampledDocs: 3, estimatedCount: 3 },
        },
        {
          type: "mongo.result",
          payload: { docCount: 1, latencyMs: 12, status: "success" },
        },
      ],
    );

    const dropped = withTrace(collector, () => extractAndReplayLambdaTraces(envelope, collector));

    expect(dropped).toBe(0);

    // All four events landed in the collector in order.
    const types = captured.map((e) => e.type);
    expect(types).toEqual(["mongo.intent", "mongo.query", "mongo.schema", "mongo.result"]);

    // Payloads survive intact (key fields).
    const queryEv = captured[1];
    expect((queryEv.payload as { mode: string }).mode).toBe("lambda");
    expect((queryEv.payload as { collection: string }).collection).toBe("orders");

    const resultEv = captured[3];
    expect((resultEv.payload as { docCount: number }).docCount).toBe(1);
    expect((resultEv.payload as { status: string }).status).toBe("success");

    // Collector stamps its own id / ts / agentId on every event — Lambda-side
    // ids and timestamps are intentionally not carried over (the parent owns
    // those so spans nest cleanly under the active turn).
    for (const ev of captured) {
      expect(typeof ev.id).toBe("string");
      expect(ev.id.length).toBeGreaterThan(0);
      expect(typeof ev.ts).toBe("number");
      expect(ev.agentId).toBe("test-agent");
    }

    // content[].text is rewritten to just the result so the LLM never sees meta.
    const rewritten = envelope.content[0].text;
    expect(rewritten).toBe(JSON.stringify([{ orderId: "ORD-1", status: "shipped" }]));
    expect(rewritten).not.toContain("meta");
    expect(rewritten).not.toContain("mongo.schema");
  });

  test("accumulates tracesDropped across all envelope blocks", () => {
    const { collector, captured } = makeCollector();

    // Two text blocks, each carrying its own envelope with dropped counters.
    const result: { content: Array<{ type: string; text: string }> } = {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            result: { a: 1 },
            meta: { traces: [{ type: "mongo.intent", payload: { collection: "a" } }], tracesDropped: 3 },
          }),
        },
        {
          type: "text",
          text: JSON.stringify({
            result: { b: 2 },
            meta: { traces: [{ type: "mongo.intent", payload: { collection: "b" } }], tracesDropped: 5 },
          }),
        },
      ],
    };

    const dropped = withTrace(collector, () => extractAndReplayLambdaTraces(result, collector));

    expect(dropped).toBe(8);
    expect(captured.map((e) => e.type)).toEqual(["mongo.intent", "mongo.intent"]);
    expect(result.content[0].text).toBe(JSON.stringify({ a: 1 }));
    expect(result.content[1].text).toBe(JSON.stringify({ b: 2 }));
  });

  test("silently skips content blocks that aren't envelopes (mixed MCP responses)", () => {
    const { collector, captured } = makeCollector();

    // Mix: an envelope, a plain non-JSON text block, a non-text content block,
    // a JSON block without meta.traces, and a malformed JSON block. Only the
    // envelope should produce events; nothing should throw.
    const result: {
      content: Array<
        | { type: string; text: string }
        | { type: string; data: { foo: number } }
      >;
    } = {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            result: { ok: true },
            meta: { traces: [{ type: "mongo.result", payload: { docCount: 0, status: "success" } }] },
          }),
        },
        { type: "text", text: "this is a plain string, not JSON" },
        { type: "image", data: { foo: 1 } },
        { type: "text", text: JSON.stringify({ result: { other: 1 } }) },
        { type: "text", text: "{not valid json" },
      ],
    };

    const dropped = withTrace(collector, () => extractAndReplayLambdaTraces(result, collector));

    expect(dropped).toBe(0);
    expect(captured.map((e) => e.type)).toEqual(["mongo.result"]);

    // Only the envelope block was rewritten; the others are untouched.
    expect((result.content[0] as { text: string }).text).toBe(JSON.stringify({ ok: true }));
    expect((result.content[1] as { text: string }).text).toBe("this is a plain string, not JSON");
    expect((result.content[3] as { text: string }).text).toBe(JSON.stringify({ result: { other: 1 } }));
    expect((result.content[4] as { text: string }).text).toBe("{not valid json");
  });

  test("no-ops with zero events on results lacking a content[] array", () => {
    const { collector, captured } = makeCollector();

    expect(withTrace(collector, () => extractAndReplayLambdaTraces(null, collector))).toBe(0);
    expect(withTrace(collector, () => extractAndReplayLambdaTraces(undefined, collector))).toBe(0);
    expect(withTrace(collector, () => extractAndReplayLambdaTraces({}, collector))).toBe(0);
    expect(withTrace(collector, () => extractAndReplayLambdaTraces({ content: "not-an-array" }, collector))).toBe(0);
    expect(withTrace(collector, () => extractAndReplayLambdaTraces({ content: [] }, collector))).toBe(0);

    expect(captured).toHaveLength(0);
  });

  test("skips malformed trace event entries inside meta.traces without throwing", () => {
    const { collector, captured } = makeCollector();

    const result = {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            result: { ok: 1 },
            meta: {
              traces: [
                // Missing/invalid entries should be skipped, valid ones kept.
                null,
                "string-instead-of-object",
                { payload: { collection: "x" } },
                { type: 42, payload: {} },
                { type: "mongo.intent", payload: { collection: "orders" } },
              ],
            },
          }),
        },
      ],
    };

    const dropped = withTrace(collector, () => extractAndReplayLambdaTraces(result, collector));

    expect(dropped).toBe(0);
    expect(captured).toHaveLength(1);
    expect(captured[0].type).toBe("mongo.intent");
    expect((captured[0].payload as { collection: string }).collection).toBe("orders");
  });

  test("when no TraceCollector is active, still strips meta from content without throwing", () => {
    // Defensive: callers might invoke wrappedCallTool outside an active turn
    // (e.g. eager warm-up). The helper must accept `undefined` trace and still
    // do its rewriting job so the LLM never sees `meta`.
    const envelope = makeEnvelope(
      { warmed: true },
      [{ type: "mongo.intent", payload: { collection: "orders" } }],
    );

    const dropped = extractAndReplayLambdaTraces(envelope, undefined);

    expect(dropped).toBe(0);
    expect(envelope.content[0].text).toBe(JSON.stringify({ warmed: true }));
  });
});
