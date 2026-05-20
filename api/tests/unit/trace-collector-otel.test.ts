/**
 * `TraceCollector.captureOtelIds()` is what powers the Developer details
 * panel's ServiceLens / X-Ray deep links. We exercise three states:
 *
 *  1. No active OTel span — must return `undefined` cleanly (this is the
 *     `DEV_MOCK_BACKENDS=1` case where no exporter is wired up).
 *  2. Active span — returns `{ traceId, rootSpanId }`.
 *  3. The captured ids surface verbatim on `toJSON().otel`, which is what
 *     the projection's `dev`/`full` modes serve to the UI.
 */

import { describe, expect, test } from "bun:test";
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

const provider = new BasicTracerProvider({
  spanProcessors: [new SimpleSpanProcessor(new InMemorySpanExporter())],
});
otelTrace.setGlobalTracerProvider(provider);

function makeCollector() {
  return new TraceCollector({ sessionId: "s", messageId: "m", agentId: "orchestrator" });
}

describe("TraceCollector — OTel id capture", () => {
  test("returns undefined when no OTel span is active", () => {
    const c = makeCollector();
    const got = c.captureOtelIds();
    expect(got).toBeUndefined();
  });

  test("captures traceId + rootSpanId when an OTel span is active and surfaces them on toJSON().otel", () => {
    const tracer = otelTrace.getTracer("test");
    tracer.startActiveSpan("chat.turn", (span) => {
      try {
        const c = makeCollector();
        const ids = c.captureOtelIds();
        expect(ids).toBeDefined();
        expect(ids?.traceId).toMatch(/^[0-9a-f]{32}$/);
        expect(ids?.rootSpanId).toMatch(/^[0-9a-f]{16}$/);
        const json = c.toJSON();
        expect(json.otel?.traceId).toBe(ids!.traceId);
        expect(json.otel?.rootSpanId).toBe(ids!.rootSpanId);
      } finally {
        span.end();
      }
    });
  });

  test("toJSON().otel is undefined when no span context exists", () => {
    const c = makeCollector();
    const json = c.toJSON();
    expect(json.otel).toBeUndefined();
  });
});
