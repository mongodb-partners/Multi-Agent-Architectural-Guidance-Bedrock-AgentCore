/**
 * `TracingRetryStrategy` is what surfaces `model.retry` trace events when
 * the AWS SDK v3 Bedrock client retries a throttled or transient failure.
 * The Developer details panel's "Retries" sub-section renders the resulting
 * events; without this strategy the retries happen silently and a developer
 * has no way to see "this turn was actually slow because we threw 4
 * ThrottlingException retries".
 *
 * The test simulates the call shape AWS SDK v3 uses internally — calling
 * `refreshRetryTokenForRetry` with a token + an errorInfo object — and asserts
 * the trace event lands with the right payload shape.
 */

import { describe, expect, test } from "bun:test";
import type { RetryErrorInfo, StandardRetryToken } from "@smithy/types";
import { TracingRetryStrategy } from "../../src/adapters/resolve-model.ts";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import { withTrace } from "../../src/lib/trace-context.ts";

function makeToken(retryCount = 1): StandardRetryToken {
  return {
    getRetryTokenCount: () => 0,
    getRetryDelay: () => 250,
    getRetryCount: () => retryCount,
    retryCount,
  } as unknown as StandardRetryToken;
}

function makeErrorInfo(errorName = "ThrottlingException", message = "rate exceeded"): RetryErrorInfo {
  return {
    errorType: "THROTTLING",
    error: { name: errorName, message } as Error,
    retryAfterHint: undefined,
  } as unknown as RetryErrorInfo;
}

describe("TracingRetryStrategy — model.retry emission", () => {
  test("emits one model.retry event per refreshRetryTokenForRetry call", async () => {
    const strat = new TracingRetryStrategy(5, "anthropic.claude-sonnet-4-5");
    const fresh = makeToken(1);
    // Stub the parent's refreshRetryTokenForRetry on the prototype chain so
    // `super.refreshRetryTokenForRetry(...)` inside the override resolves to
    // our fake instead of the ConfiguredRetryStrategy throttle-bucket impl.
    const parentProto = Object.getPrototypeOf(Object.getPrototypeOf(strat));
    const original = parentProto.refreshRetryTokenForRetry;
    parentProto.refreshRetryTokenForRetry = async () => fresh;
    const collector = new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "orchestrator",
    });
    try {
      await withTrace(collector, async () => {
        await strat.refreshRetryTokenForRetry(makeToken(0), makeErrorInfo());
      });
    } finally {
      parentProto.refreshRetryTokenForRetry = original;
    }

    const ev = collector.getEvents().find((e) => e.type === "model.retry");
    expect(ev).toBeDefined();
    const p = ev?.payload as Record<string, unknown>;
    expect(p.provider).toBe("bedrock");
    expect(p.modelId).toBe("anthropic.claude-sonnet-4-5");
    expect(p.attempt).toBe(1);
    // The strategy prefers errorInfo.errorType (`"THROTTLING"`) over the
    // underlying error name (`"ThrottlingException"`); the Trace Viewer's
    // retry table renders this string verbatim.
    expect(p.previousErrorClass).toBe("THROTTLING");
    expect(typeof p.backoffMs).toBe("number");
  });

  test("does not throw when no collector is active (turn started without trace)", async () => {
    const strat = new TracingRetryStrategy(5, "anthropic.claude-sonnet-4-5");
    const fresh = makeToken(1);
    const parentProto = Object.getPrototypeOf(Object.getPrototypeOf(strat));
    const original = parentProto.refreshRetryTokenForRetry;
    parentProto.refreshRetryTokenForRetry = async () => fresh;
    try {
      const out = await strat.refreshRetryTokenForRetry(makeToken(0), makeErrorInfo());
      expect(out).toBe(fresh);
    } finally {
      parentProto.refreshRetryTokenForRetry = original;
    }
  });
});
