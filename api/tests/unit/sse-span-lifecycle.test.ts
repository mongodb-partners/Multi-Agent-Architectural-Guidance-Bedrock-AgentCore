import { SpanKind } from "@opentelemetry/api";
import { beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import { initOtel, tracer } from "../../src/lib/otel.ts";
import { otelServerSpanMiddleware } from "../../src/middleware/otel.ts";
import { requestIdMiddleware } from "../../src/middleware/request-id.ts";

beforeAll(() => {
  initOtel({ serviceName: "mongodb-multiagent-api-sse-test" });
});

/**
 * SSE turns are the most common chat shape. The X-Trace-Id response header
 * must be set *before* the first byte streams so the UI can read it from the
 * fetch response immediately, and the server span attribute / trace_id stays
 * stable for every chunk written under the stream callback.
 */
describe("otelServerSpanMiddleware — SSE response lifecycle", () => {
  test("X-Trace-Id is set before first chunk; trace_id stable through stream", async () => {
    const app = new Hono();
    app.use("*", requestIdMiddleware);
    app.use("*", otelServerSpanMiddleware);

    const observed: { headerTraceId: string | null; chunkTraceIds: string[] } = {
      headerTraceId: null,
      chunkTraceIds: [],
    };

    app.post("/sse", (c) => {
      const t = tracer();
      return streamSSE(c, async (stream) => {
        for (let i = 0; i < 3; i++) {
          const child = t.startSpan(`chunk-${i}`, { kind: SpanKind.INTERNAL });
          observed.chunkTraceIds.push(child.spanContext().traceId);
          await stream.writeSSE({ event: "token", data: JSON.stringify({ i }) });
          child.end();
        }
        await stream.writeSSE({ event: "done", data: "{}" });
      });
    });

    const res = await app.request("http://test/sse", { method: "POST" });
    expect(res.status).toBe(200);
    observed.headerTraceId = res.headers.get("X-Trace-Id");
    expect(observed.headerTraceId).toBeTruthy();
    expect(observed.headerTraceId).toMatch(/^[0-9a-f]{32}$/i);

    const body = await res.text();
    expect(body).toContain("event: token");
    expect(body).toContain("event: done");

    expect(observed.chunkTraceIds.length).toBe(3);
    const headerTraceId = observed.headerTraceId;
    expect(headerTraceId).toBeTruthy();
    for (const tid of observed.chunkTraceIds) {
      expect(tid).toBe(headerTraceId as string);
    }
  });
});
