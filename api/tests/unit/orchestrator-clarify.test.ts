/**
 * Unit tests for the orchestrator clarification helper.
 *
 * Contract: `runOrchestratorClarification` ALWAYS yields a non-empty
 * clarification. It uses one Bedrock `ConverseCommand` when reachable, and a
 * deterministic roster-built template otherwise. It must never produce a
 * domain-specific answer.
 *
 * Uses `_setBedrockClientForTests(...)` to swap the Bedrock client (same pattern
 * as `agent-classifier-haiku-multi.test.ts`) so no AWS call is made.
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import {
  runOrchestratorClarification,
  buildClarificationTemplate,
  _setBedrockClientForTests,
} from "../../src/lib/orchestrator-clarify.ts";
import type { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";

function converseTextResponse(text: string): unknown {
  return {
    output: { message: { role: "assistant", content: [{ text }] } },
    usage: { inputTokens: 20, outputTokens: 12 },
  };
}

let mockSend: ReturnType<typeof mock> = mock(async () => ({}));
function makeFakeClient(): BedrockRuntimeClient {
  return {
    send: (cmd: unknown) => mockSend(cmd),
  } as unknown as BedrockRuntimeClient;
}

async function collect(gen: AsyncGenerator<{ type: string; text?: string }>): Promise<string> {
  let out = "";
  for await (const part of gen) {
    if (part.type === "token") out += part.text ?? "";
  }
  return out;
}

const SAVED_ENV = { ...process.env };

describe("orchestrator-clarify", () => {
  beforeEach(() => {
    _setBedrockClientForTests(makeFakeClient());
    mockSend = mock(async () => ({}));
  });
  afterEach(() => {
    _setBedrockClientForTests(null);
    process.env = { ...SAVED_ENV };
  });

  test("model reply is streamed as a token", async () => {
    mockSend = mock(async () =>
      converseTextResponse("Happy to help! Could you tell me what you need?"),
    );
    const text = await collect(
      runOrchestratorClarification({ userMessage: "Can you help me?" }),
    );
    expect(text).toContain("Could you tell me what you need?");
  });

  test("model throws → deterministic template fallback is emitted", async () => {
    mockSend = mock(async () => {
      throw new Error("simulated Bedrock outage");
    });
    const text = await collect(
      runOrchestratorClarification({ userMessage: "Can you help me?" }),
    );
    expect(text.trim().length).toBeGreaterThan(0);
    // The fallback asks the customer to elaborate; it is never a domain answer.
    expect(text.toLowerCase()).toContain("tell me");
  });

  test("empty model reply → deterministic template fallback is emitted", async () => {
    mockSend = mock(async () => converseTextResponse("   "));
    const text = await collect(
      runOrchestratorClarification({ userMessage: "hi" }),
    );
    expect(text.trim().length).toBeGreaterThan(0);
  });

  test("template lists the available specialist domains", () => {
    const tmpl = buildClarificationTemplate([
      { name: "Order Management", description: "orders" },
      { name: "Product Recommendation", description: "products" },
      { name: "Troubleshooting", description: "support" },
    ]);
    expect(tmpl).toContain("Order Management");
    expect(tmpl).toContain("Product Recommendation");
    expect(tmpl).toContain("Troubleshooting");
    // Always yields a single, non-empty clarifying sentence.
    expect(tmpl.length).toBeGreaterThan(0);
  });
});
