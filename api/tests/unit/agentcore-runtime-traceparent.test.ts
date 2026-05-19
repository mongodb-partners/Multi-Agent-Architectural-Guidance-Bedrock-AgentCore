/**
 * Regression guard for the OTel/AgentCore handshake.
 *
 * Phase 2 of the CloudWatch GenAI rollout depends on every InvokeAgentRuntime
 * payload carrying a W3C `traceparent` header inside the `_trace` carrier,
 * so the AgentCore Runtime container can restore the parent span context and
 * its own `gen_ai.*` spans land in the SAME trace as the API hop.
 *
 * Without this header, /aws/spans shows two disjoint trace trees per chat
 * turn (one for the API + Streamlit, one for the runtime) and the GenAI
 * Observability Agents tab cannot follow a turn end-to-end.
 *
 * The test stubs the BedrockAgentCore client, kicks off `invokeAgentRuntime`,
 * and asserts the captured `InvokeAgentRuntimeCommand` payload contains
 * `_trace.traceparent` in the documented W3C format.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { context, trace as otelTrace } from "@opentelemetry/api";
import { initOtel } from "../../src/lib/otel.ts";

const SAVED_ENV = { ...process.env };

// SDK send is intercepted by patching the prototype after a dynamic import,
// because the adapter constructs its client lazily inside invokeAgentRuntime.
async function captureNextInvokePayload(): Promise<Record<string, unknown>> {
  const { BedrockAgentCoreClient } = await import("@aws-sdk/client-bedrock-agentcore");
  const captured: { payload?: string } = {};
  const original = BedrockAgentCoreClient.prototype.send;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  BedrockAgentCoreClient.prototype.send = async function (cmd: any) {
    captured.payload = cmd?.input?.payload as string | undefined;
    // Return a benign empty-body response so the async generator finishes
    // immediately (the parseRuntimeSseStream consumer handles undefined body
    // by throwing — the test only cares that the payload was captured before
    // that point).
    throw new Error("__captured__");
  } as typeof original;

  try {
    const { invokeAgentRuntime } = await import("../../src/adapters/agentcore-runtime.ts");
    const it = invokeAgentRuntime({
      message: "hi",
      agentId: "orchestrator",
      sessionId: "s".repeat(33),
    });
    try {
      await it.next();
    } catch (e) {
      if (!(e instanceof Error) || e.message !== "__captured__") throw e;
    }
  } finally {
    BedrockAgentCoreClient.prototype.send = original;
  }

  if (!captured.payload) throw new Error("InvokeAgentRuntimeCommand was not sent");
  return JSON.parse(captured.payload) as Record<string, unknown>;
}

describe("agentcore-runtime traceparent propagation", () => {
  beforeEach(() => {
    process.env.AGENTCORE_ORCHESTRATOR_ARN = "arn:aws:bedrock-agentcore:us-east-1:000000000000:agent-runtime/test";
    process.env.AWS_REGION = "us-east-1";
    initOtel({ serviceName: "test-traceparent" });
  });

  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("InvokeAgentRuntime payload always carries _trace.traceparent in W3C format", async () => {
    const tracer = otelTrace.getTracer("test");
    const span = tracer.startSpan("test-root");
    let parsed: Record<string, unknown> = {};
    await context.with(otelTrace.setSpan(context.active(), span), async () => {
      parsed = await captureNextInvokePayload();
    });
    span.end();

    const carrier = parsed._trace as Record<string, string> | undefined;
    expect(carrier).toBeDefined();
    expect(carrier?.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$/);
  });
});
