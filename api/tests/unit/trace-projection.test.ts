/**
 * Tests for `projectTraceForInclude` — the server-side projection that backs
 * the Trace Viewer's two-tier `?include=core|dev|full` fetch contract.
 *
 * What we care about:
 *
 *  1. `full` and `dev` are identity. Pre-PR2 callers (smoke tests, external
 *     scripts) must keep getting today's shape.
 *  2. `core` strips heavy payload fields into `{ _omittedForCoreMode: true,
 *     bytesAvailable: N, wasRedacted?: bool }` sentinels — the size hints
 *     are what the Streamlit UI uses to render muted captions.
 *  3. `core` drops dev-only event types and top-level fields (`release`,
 *     `correlation`, `otel`, `spanTree`). The Developer details panel is
 *     the only consumer of these — leaking them into `core` would defeat
 *     the perf gain.
 *  4. A `<redacted>` field stays `<redacted>` shape via `wasRedacted: true`
 *     so the UI doesn't render "11 bytes available" for a field the API
 *     already redacted at emit time.
 *  5. `mongo.vector_search.documentPreviews` is capped at the top-3 in core
 *     mode (the client memory panel only renders top-3 source previews).
 *  6. Core mode never mutates the input trace.
 */

import { describe, expect, test } from "bun:test";
import {
  parseIncludeMode,
  projectTraceForInclude,
  TRACE_INCLUDE_MODES,
  type TraceIncludeMode,
} from "../../src/lib/trace-projection.ts";
import type { Trace, TraceEvent } from "../../src/lib/trace-types.ts";

function makeEvent<T extends TraceEvent["type"]>(
  id: string,
  type: T,
  payload: Record<string, unknown>,
  overrides: Partial<TraceEvent> = {},
): TraceEvent {
  return {
    id,
    ts: 0,
    type,
    payload: payload as never,
    ...overrides,
  } as TraceEvent;
}

function makeTrace(events: TraceEvent[], extra: Partial<Trace> = {}): Trace {
  return {
    traceId: "t-1",
    sessionId: "s-1",
    messageId: "m-1",
    agentId: "orchestrator",
    createdAt: new Date(0).toISOString(),
    events,
    summary: {
      totalTokens: 0,
      inputTokens: 0,
      outputTokens: 0,
      estimatedCostUsd: null,
      costEstimateComplete: false,
      costBreakdown: {},
      durationMs: 0,
      toolCalls: 0,
      mongoQueries: 0,
      mongoDocsReturned: 0,
      mcpCalls: 0,
      agentcoreHops: 0,
      agentcoreRuntimeMs: 0,
      modelIds: [],
      toolsUsed: [],
      eventsDropped: 0,
      degraded: false,
    },
    ...extra,
  } as Trace;
}

describe("parseIncludeMode", () => {
  test("accepts the three known modes case-insensitively", () => {
    expect(parseIncludeMode("core")).toBe("core");
    expect(parseIncludeMode("DEV")).toBe("dev");
    expect(parseIncludeMode(" Full ")).toBe("full");
  });

  test("falls back to `full` for unknown / missing values (server default)", () => {
    expect(parseIncludeMode(undefined)).toBe("full");
    expect(parseIncludeMode(null)).toBe("full");
    expect(parseIncludeMode("")).toBe("full");
    expect(parseIncludeMode("nonsense")).toBe("full");
  });

  test("TRACE_INCLUDE_MODES enumerates exactly the three supported modes", () => {
    expect([...TRACE_INCLUDE_MODES].sort()).toEqual(["core", "dev", "full"]);
  });
});

describe("projectTraceForInclude — full + dev are identity", () => {
  const trace = makeTrace(
    [
      makeEvent("e1", "prompt.assembled", {
        body: "hello world",
        bodyBytes: 11,
        totalBytes: 11,
        personaBytes: 0,
        discoveryBytes: 0,
        memoryContextBytes: 0,
      }),
      makeEvent("e2", "dev.environment", { chatMode: "live", devMockBackends: false }),
    ],
    {
      release: { gitSha: "deadbeef", env: "dev" },
      correlation: { requestId: "rid-1" },
      otel: { traceId: "1234567890abcdef1234567890abcdef", rootSpanId: "abcdef1234567890" },
      spanTree: [{ id: "root", type: "chat.turn.start", ts: 0, durationMs: 0, children: [] }],
    },
  );

  for (const mode of ["full", "dev"] as const) {
    test(`include=${mode} returns the trace verbatim (same reference)`, () => {
      const out = projectTraceForInclude(trace, mode);
      expect(out).toBe(trace);
    });
  }
});

describe("projectTraceForInclude — core mode strips heavy fields", () => {
  test("prompt.assembled.body becomes a sentinel with bytesAvailable", () => {
    const trace = makeTrace([
      makeEvent("e1", "prompt.assembled", {
        body: "x".repeat(1234),
        bodyBytes: 1234,
        totalBytes: 1234,
        personaBytes: 0,
        discoveryBytes: 0,
        memoryContextBytes: 0,
      }),
    ]);
    const out = projectTraceForInclude(trace, "core");
    const body = (out.events[0].payload as any).body;
    expect(body._omittedForCoreMode).toBe(true);
    // bytesAvailable approximates JSON.stringify length; matches `"<1236 chars>"` here.
    expect(typeof body.bytesAvailable).toBe("number");
    expect(body.bytesAvailable).toBeGreaterThan(1000);
    // Non-stripped fields are preserved verbatim.
    expect((out.events[0].payload as any).bodyBytes).toBe(1234);
    expect((out.events[0].payload as any).personaBytes).toBe(0);
  });

  test("model.request strips userMessage + messagesSeed + priorTurnsPreview", () => {
    const trace = makeTrace([
      makeEvent("e1", "model.request", {
        modelId: "anthropic.claude-sonnet-4-5",
        region: "us-east-1",
        systemPromptHash: "abc",
        systemPromptBytes: 100,
        priorTurnsCount: 2,
        userMessage: "secret prompt",
        messagesSeed: [{ role: "user", contentBytes: 5, contentPreview: "hi" }],
        priorTurnsPreview: [{ role: "user", bytes: 5, preview: "hi" }],
      }),
    ]);
    const out = projectTraceForInclude(trace, "core");
    const p = out.events[0].payload as any;
    expect(p.userMessage._omittedForCoreMode).toBe(true);
    expect(p.messagesSeed._omittedForCoreMode).toBe(true);
    expect(p.priorTurnsPreview._omittedForCoreMode).toBe(true);
    // Keep-list survives unchanged.
    expect(p.modelId).toBe("anthropic.claude-sonnet-4-5");
    expect(p.systemPromptHash).toBe("abc");
    expect(p.priorTurnsCount).toBe(2);
  });

  test("memory.long_term_write strips factCandidates + extractor diagnostics, keeps factsExtracted + outcome", () => {
    const trace = makeTrace([
      makeEvent("e1", "memory.long_term_write", {
        userId: "u",
        agentId: "a",
        primaryOutcome: "persisted",
        docsInserted: 2,
        duplicatesSkipped: 1,
        latencyMs: 33,
        userMessageBytes: 50,
        assistantReplyBytes: 100,
        factsExtracted: ["fact A", "fact B"],
        factCandidates: [
          { text: "x", matched: true, length: 1, category: "profile", matchedPatterns: [] },
        ],
        extractorRawText: "the raw LLM output",
        extractorRequestPrompt: "the prompt",
        extractorErrorClass: null,
        extractorErrorMessage: null,
        extractorModelId: "anthropic.claude-3-7-sonnet-20250219-v1:0",
      }),
    ]);
    const out = projectTraceForInclude(trace, "core");
    const p = out.events[0].payload as any;
    // Stripped to sentinels:
    expect(p.factCandidates._omittedForCoreMode).toBe(true);
    expect(p.extractorRawText._omittedForCoreMode).toBe(true);
    expect(p.extractorRequestPrompt._omittedForCoreMode).toBe(true);
    // Kept (client `render_memory` + inline summary's "Learned …" card consume these):
    expect(p.factsExtracted).toEqual(["fact A", "fact B"]);
    expect(p.primaryOutcome).toBe("persisted");
    expect(p.docsInserted).toBe(2);
    expect(p.duplicatesSkipped).toBe(1);
    expect(p.extractorModelId).toBe("anthropic.claude-3-7-sonnet-20250219-v1:0");
  });

  test("redacted source field collapses to wasRedacted=true sentinel, not a bytes-count one", () => {
    const trace = makeTrace([
      makeEvent("e1", "memory.scoped_read", {
        userId: "u",
        agentId: "a",
        mode: "hybrid",
        latencyMs: 10,
        entryCount: 1,
        bytesInjected: 11,
        retrievalErrorClass: "<redacted>",
        retrievalErrorMessage: "<redacted>",
      }),
    ]);
    const out = projectTraceForInclude(trace, "core");
    const p = out.events[0].payload as any;
    expect(p.retrievalErrorClass).toEqual({
      _omittedForCoreMode: true,
      bytesAvailable: 0,
      wasRedacted: true,
    });
    expect(p.retrievalErrorMessage).toEqual({
      _omittedForCoreMode: true,
      bytesAvailable: 0,
      wasRedacted: true,
    });
  });

  test("mongo.vector_search.documentPreviews is capped at top-3 in core mode", () => {
    const previews = Array.from({ length: 7 }, (_, i) => ({
      rank: i + 1,
      title: `doc ${i + 1}`,
      snippet: `snippet ${i + 1}`,
      fields: { sku: `SKU-${i}` },
    }));
    const trace = makeTrace([
      makeEvent("e1", "mongo.vector_search", {
        collection: "products",
        embeddingSource: "voyage",
        indexName: "products_vector",
        scores: [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3],
        documentPreviews: previews,
      }),
    ]);
    const out = projectTraceForInclude(trace, "core");
    const p = out.events[0].payload as any;
    expect(p.documentPreviews).toHaveLength(3);
    // The nested `fields` are stripped from every preview kept.
    for (const preview of p.documentPreviews) {
      expect("fields" in preview).toBe(false);
    }
    // Keep-list fields (indexName, scores) survive.
    expect(p.indexName).toBe("products_vector");
    expect(p.scores).toEqual([0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3]);
  });

  test("dev-only event types are dropped from core mode", () => {
    const trace = makeTrace([
      makeEvent("e1", "chat.turn.start", {
        sessionId: "s",
        messageId: "m",
        agentId: "a",
        startTs: 0,
      }),
      makeEvent("e2", "dev.environment", { chatMode: "live" }),
      makeEvent("e3", "dev.byte_cap_hit", { droppedType: "tool.call", bytes: 1024, reason: "per_event" }),
      makeEvent("e4", "model.retry", { attempt: 1, backoffMs: 100, previousErrorClass: "Throttle" }),
      makeEvent("e5", "agentcore.retry", { attempt: 1, backoffMs: 200, previousErrorClass: "Throttle" }),
      makeEvent("e6", "model.text_delta_batch", { text: "x", bytes: 1, windowMs: 1 }),
      makeEvent("e7", "latency.checkpoint", { name: "ttfb", elapsedMs: 5 }),
    ]);
    const out = projectTraceForInclude(trace, "core");
    const types = out.events.map((e) => e.type);
    expect(types).toEqual(["chat.turn.start"]);
  });

  test("dev-only top-level fields are removed from core mode", () => {
    const trace = makeTrace([], {
      release: { gitSha: "abc", env: "prod" },
      correlation: { requestId: "rid" },
      otel: { traceId: "x".repeat(32), rootSpanId: "y".repeat(16) },
      spanTree: [{ id: "n", type: "chat.turn.start", ts: 0, durationMs: 1, children: [] }],
    });
    const out = projectTraceForInclude(trace, "core");
    expect("release" in out).toBe(false);
    expect("correlation" in out).toBe(false);
    expect("otel" in out).toBe(false);
    expect("spanTree" in out).toBe(false);
  });

  test("core projection does not mutate the input trace", () => {
    const trace = makeTrace(
      [
        makeEvent("e1", "prompt.assembled", {
          body: "x".repeat(500),
          bodyBytes: 500,
          totalBytes: 500,
          personaBytes: 0,
          discoveryBytes: 0,
          memoryContextBytes: 0,
        }),
        makeEvent("e2", "dev.environment", { chatMode: "live" }),
      ],
      { release: { gitSha: "abc" } },
    );
    const before = JSON.parse(JSON.stringify(trace));
    projectTraceForInclude(trace, "core");
    expect(trace).toEqual(before);
  });

  test("core projection of a large fixture is meaningfully smaller than dev", () => {
    // Two heavy fields: a 5 KB system prompt body + a 4 KB user message.
    const events: TraceEvent[] = [
      makeEvent("p1", "prompt.assembled", {
        body: "lorem ipsum ".repeat(500),
        bodyBytes: 5500,
        totalBytes: 5500,
        personaBytes: 0,
        discoveryBytes: 0,
        memoryContextBytes: 0,
      }),
      makeEvent("r1", "model.request", {
        modelId: "anthropic.claude-sonnet-4-5",
        region: "us-east-1",
        systemPromptHash: "abc",
        systemPromptBytes: 5500,
        priorTurnsCount: 0,
        userMessage: "secret detailed user prompt ".repeat(200),
      }),
    ];
    const trace = makeTrace(events);
    const devSize = JSON.stringify(projectTraceForInclude(trace, "dev")).length;
    const coreSize = JSON.stringify(projectTraceForInclude(trace, "core")).length;
    expect(coreSize).toBeLessThan(devSize / 4);
  });
});
