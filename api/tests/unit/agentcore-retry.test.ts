/**
 * AgentCore Runtime retry visibility — `agentcore.retry` trace events.
 *
 * The AgentCore Runtime invocation path runs a manual retry loop so each
 * retry shows up as a discrete `agentcore.retry` event in the Trace Viewer's
 * "Retries" sub-section. Two parts must hold:
 *
 *   1. `isRetryableAgentcoreError(errClass, httpStatus)` correctly classifies
 *      the wire shapes AWS SDK v3 + the AgentCore runtime ship — throttling,
 *      5xx, stream interruptions — as retryable, while leaving the
 *      4xx-not-429 / validation classes alone (no infinite retry of
 *      ValidationException).
 *   2. When the loop does emit, the trace event carries the payload shape
 *      the Developer details panel renders.
 *
 * The second leg is exercised by a small simulation that mirrors the loop's
 * emit call — keeping AWS-SDK / bedrock-agentcore-client mocking out of
 * scope (those live in `agentcore-runtime-arn` / `agentcore-runtime-traceparent`
 * integration tests).
 */

import { describe, expect, test } from "bun:test";
import { isRetryableAgentcoreError } from "../../src/adapters/agentcore-runtime.ts";
import { TraceCollector } from "../../src/lib/trace-collector.ts";

describe("isRetryableAgentcoreError", () => {
  test("throttling classes are retryable", () => {
    expect(isRetryableAgentcoreError("ThrottlingException", undefined)).toBe(true);
    expect(isRetryableAgentcoreError("TooManyRequestsException", undefined)).toBe(true);
  });

  test("transient 5xx classes are retryable", () => {
    expect(isRetryableAgentcoreError("ServiceUnavailableException", undefined)).toBe(true);
    expect(isRetryableAgentcoreError("InternalServerException", undefined)).toBe(true);
  });

  test("AgentCore stream interruption + AWS SDK TimeoutError are retryable", () => {
    expect(isRetryableAgentcoreError("ModelStreamErrorException", undefined)).toBe(true);
    expect(isRetryableAgentcoreError("TimeoutError", undefined)).toBe(true);
  });

  test("HTTP 429 is retryable regardless of errClass", () => {
    expect(isRetryableAgentcoreError("UnknownException", 429)).toBe(true);
  });

  test("HTTP 5xx is retryable regardless of errClass", () => {
    expect(isRetryableAgentcoreError("UnknownException", 503)).toBe(true);
    expect(isRetryableAgentcoreError("UnknownException", 599)).toBe(true);
  });

  test("HTTP 4xx (not 429) is NOT retryable — avoids retrying ValidationException loops", () => {
    expect(isRetryableAgentcoreError("ValidationException", 400)).toBe(false);
    expect(isRetryableAgentcoreError("AccessDeniedException", 403)).toBe(false);
    expect(isRetryableAgentcoreError("ResourceNotFoundException", 404)).toBe(false);
  });

  test("HTTP 2xx never retries (defensive — should never reach here, but)", () => {
    expect(isRetryableAgentcoreError("Unknown", 200)).toBe(false);
    expect(isRetryableAgentcoreError("Unknown", undefined)).toBe(false);
  });
});

describe("agentcore.retry event payload contract", () => {
  test("emitted event carries arn / targetAgentId / mode / attempt / errorClass / backoffMs / httpStatus", () => {
    // Mirrors the emit shape inside invokeAgentRuntime's retry loop.
    const collector = new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "orchestrator",
    });
    collector.event("agentcore.retry", {
      arn: "arn:aws:bedrock-agentcore:us-east-1:123:runtime/foo",
      targetAgentId: "order-management",
      mode: "orchestrator_to_specialist",
      attempt: 2,
      previousErrorClass: "ThrottlingException",
      previousErrorMessage: "rate exceeded",
      backoffMs: 400,
      httpStatus: 429,
    });
    const ev = collector.getEvents().find((e) => e.type === "agentcore.retry");
    expect(ev).toBeDefined();
    const p = ev?.payload as Record<string, unknown>;
    expect(p.arn).toMatch(/^arn:aws:/);
    expect(p.targetAgentId).toBe("order-management");
    expect(p.mode).toBe("orchestrator_to_specialist");
    expect(p.attempt).toBe(2);
    expect(p.previousErrorClass).toBe("ThrottlingException");
    expect(p.backoffMs).toBe(400);
    expect(p.httpStatus).toBe(429);
  });
});
