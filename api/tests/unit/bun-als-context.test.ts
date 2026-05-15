import { context, trace } from "@opentelemetry/api";
import { beforeAll, describe, expect, test } from "bun:test";
import { initOtel, tracer } from "../../src/lib/otel.ts";

/**
 * Defensive coverage: the OTel `AsyncLocalStorageContextManager` must survive
 * Bun's async boundaries (setTimeout, micro-task `.then`, `Promise.all`, and
 * a fake "fetch" returning a resolved Promise). Regressions here cause every
 * log line emitted from an SSE stream / handler to drop its `trace_id`.
 */
describe("Bun + OTel AsyncLocalStorage context", () => {
  beforeAll(() => {
    initOtel({ serviceName: "mongodb-multiagent-api-als-test" });
  });

  test("active span survives setTimeout / microtask / Promise.all", async () => {
    const t = tracer();
    await t.startActiveSpan("als-root", async (root) => {
      const expected = root.spanContext().traceId;

      const seenInTimeout = await new Promise<string | undefined>((resolve) => {
        setTimeout(() => {
          resolve(trace.getActiveSpan()?.spanContext().traceId);
        }, 5);
      });

      const seenInMicrotask = await Promise.resolve().then(
        () => trace.getActiveSpan()?.spanContext().traceId,
      );

      const [a, b, c] = await Promise.all([
        Promise.resolve(trace.getActiveSpan()?.spanContext().traceId),
        new Promise<string | undefined>((resolve) =>
          queueMicrotask(() => resolve(trace.getActiveSpan()?.spanContext().traceId)),
        ),
        (async () => trace.getActiveSpan()?.spanContext().traceId)(),
      ]);

      expect(seenInTimeout).toBe(expected);
      expect(seenInMicrotask).toBe(expected);
      expect(a).toBe(expected);
      expect(b).toBe(expected);
      expect(c).toBe(expected);

      root.end();
    });
  });

  test("context.with(ROOT_CONTEXT) clears the active span", async () => {
    const t = tracer();
    await t.startActiveSpan("outer", async (span) => {
      expect(trace.getActiveSpan()?.spanContext().traceId).toBe(span.spanContext().traceId);
      await context.with(context.active().deleteValue(Symbol.for("does-not-exist")), async () => {
        expect(trace.getActiveSpan()?.spanContext().traceId).toBe(span.spanContext().traceId);
      });
      span.end();
    });
  });
});
