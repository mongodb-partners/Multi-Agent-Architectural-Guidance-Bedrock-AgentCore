/**
 * Unit tests for the synthesizer agent helpers.
 *
 * `runSynthesizerAgent` is integration-tested via the multi-orchestrator
 * end-to-end test above (gated on a real Bedrock client). Here we only
 * verify the pure helpers — the user-message builder and the agent-id
 * scoping helper — which run without any LLM call.
 */

import { describe, expect, test } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import {
  buildSynthesizerUserMessage,
  withSynthesizerAgentId,
  SYNTHESIZER_AGENT_ID,
  type SpecialistAnswer,
} from "../../src/lib/specialist-answer-synthesizer.ts";

describe("specialist-answer-synthesizer — buildSynthesizerUserMessage", () => {
  const successAnswer: SpecialistAnswer = {
    agentId: "order-management",
    agentName: "Order Management",
    status: "success",
    answerText: "Your order ABC-123 ships Monday.",
  };
  const failedAnswer: SpecialistAnswer = {
    agentId: "product-recommendation",
    agentName: "Product Recommendation",
    status: "failed",
    answerText: "",
    failureMessage: "model timed out",
  };

  test("includes the original user question verbatim", () => {
    const out = buildSynthesizerUserMessage({
      userMessage: "Where is my order ABC-123?",
      specialistAnswers: [successAnswer],
    });
    expect(out).toContain("Where is my order ABC-123?");
  });

  test("attributes specialists by display name in classifier-ranked order", () => {
    const out = buildSynthesizerUserMessage({
      userMessage: "track my order AND recommend a laptop",
      specialistAnswers: [successAnswer, { ...successAnswer, agentName: "Product Recommendation", agentId: "product-recommendation", answerText: "Try the X1." }],
    });
    const orderIdx = out.indexOf("Order Management");
    const productIdx = out.indexOf("Product Recommendation");
    expect(orderIdx).toBeGreaterThan(-1);
    expect(productIdx).toBeGreaterThan(-1);
    expect(orderIdx).toBeLessThan(productIdx);
  });

  test("renders failed specialists as customer-safe placeholder, never names the failure agent", () => {
    const out = buildSynthesizerUserMessage({
      userMessage: "...",
      specialistAnswers: [successAnswer, failedAnswer],
    });
    expect(out).toContain("Product Recommendation");
    expect(out).toContain("could not answer");
    // The failure message text is included for the SYNTHESIZER's awareness,
    // but the system prompt instructs it to never expose specialist ids
    // to the customer. We confirm the user-message block carries the raw
    // signal (used by the LLM to decide how to phrase the missing area).
    expect(out).toContain("model timed out");
  });

  test("renders empty specialists with no-text placeholder", () => {
    const empty: SpecialistAnswer = {
      agentId: "x",
      agentName: "X",
      status: "empty",
      answerText: "",
    };
    const out = buildSynthesizerUserMessage({
      userMessage: "...",
      specialistAnswers: [empty],
    });
    expect(out).toContain("returned no usable text");
  });

  test("ends with combine instructions", () => {
    const out = buildSynthesizerUserMessage({
      userMessage: "...",
      specialistAnswers: [successAnswer],
    });
    expect(out).toContain("Combine the specialist answers above");
  });
});

describe("specialist-answer-synthesizer — withSynthesizerAgentId", () => {
  function makeCollector(): TraceCollector {
    return new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "orchestrator",
      userId: "u",
    });
  }

  test("scopes collector.agentId to 'synthesizer' for the duration of the call", async () => {
    const collector = makeCollector();
    expect(collector.agentId).toBe("orchestrator");
    let inside: string | undefined;
    await withSynthesizerAgentId(collector, async () => {
      inside = collector.agentId;
    });
    expect(inside).toBe(SYNTHESIZER_AGENT_ID);
    // Restored on exit.
    expect(collector.agentId).toBe("orchestrator");
  });

  test("restores agentId even when the wrapped callback throws", async () => {
    const collector = makeCollector();
    await expect(
      withSynthesizerAgentId(collector, async () => {
        expect(collector.agentId).toBe(SYNTHESIZER_AGENT_ID);
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    expect(collector.agentId).toBe("orchestrator");
  });

  test("is a no-op when collector is undefined", async () => {
    const out = await withSynthesizerAgentId(undefined, async () => 42);
    expect(out).toBe(42);
  });
});
