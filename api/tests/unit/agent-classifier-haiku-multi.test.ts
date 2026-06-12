/**
 * Verifies the Haiku fallback path for multi-select classification.
 *
 * The heuristic-only path is exercised in `agent-classifier.test.ts` and
 * `agent-classifier-multi.test.ts`. This file targets the **Bedrock
 * Converse tool-use** branch in `haikuClassifyMulti(...)`:
 *
 *   1. The classifier wires the configured agent ids into the tool
 *      schema's `enum` and respects the `maxItems = CLASSIFIER_MULTI_MAX_AGENTS`
 *      cap.
 *   2. When Haiku returns multiple agent ids in `agentIds[]`, the
 *      classifier round-trips them in classifier-ranked order.
 *   3. Unknown agent ids in the tool reply are filtered out (defense
 *      against model hallucinations).
 *   4. Duplicates in the tool reply are de-duplicated while preserving
 *      first-occurrence order.
 *   5. Tool calls that fail / return no `toolUse` block resolve to
 *      `undefined` (heuristic alone has already gated the call site).
 *
 * Uses the `_setBedrockClientForTests(...)` injection point to swap the
 * classifier's Bedrock client without touching `@aws-sdk/client-bedrock-runtime`
 * via `mock.module(...)`. Module-level mocks are process-global in Bun
 * and bleed into subsequently-loaded test files (e.g. `resolve-model-cache`,
 * `agent-template-cache`, `strands-retry-contract`), which all build a
 * real `BedrockModel` and need the real SDK.
 *
 * Every prompt here is intentionally generic ("blorple quazzle floom")
 * so the heuristic returns nothing and the Haiku path is exercised.
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import {
  classifyAgents,
  resetAgentClassifierCacheForTests,
  _setBedrockClientForTests,
} from "../../src/lib/agent-classifier.ts";
import type { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";

function toolUseResponse(input: unknown, name = "route_to_specialists"): unknown {
  return {
    output: {
      message: {
        role: "assistant",
        content: [{ toolUse: { toolUseId: "tu-1", name, input } }],
      },
    },
    usage: { inputTokens: 50, outputTokens: 10 },
  };
}

let mockSend: ReturnType<typeof mock> = mock(async () => ({}));
let lastInput: { input?: unknown } = {};

/**
 * Build a stand-in for `BedrockRuntimeClient` whose only job is to
 * record `send()` calls and return whatever the active `mockSend`
 * function resolves with. The classifier never reaches AWS.
 */
function makeFakeClient(): BedrockRuntimeClient {
  return {
    send(cmd: unknown) {
      lastInput = cmd as { input?: unknown };
      return mockSend(cmd);
    },
  } as unknown as BedrockRuntimeClient;
}

const SAVED_ENV = { ...process.env };

describe("agent-classifier — Haiku multi-select", () => {
  beforeEach(() => {
    delete process.env.CLASSIFIER_BACKEND;
    delete process.env.CLASSIFIER_HEURISTIC_MIN_SCORE;
    delete process.env.CLASSIFIER_HEURISTIC_MARGIN;
    delete process.env.CLASSIFIER_MULTI_MIN_SCORE;
    delete process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN;
    delete process.env.CLASSIFIER_MULTI_MAX_AGENTS;
    resetAgentClassifierCacheForTests();
    _setBedrockClientForTests(makeFakeClient());
    mockSend = mock(async () => ({}));
    lastInput = {};
  });
  afterEach(() => {
    _setBedrockClientForTests(null);
    process.env = { ...SAVED_ENV };
  });

  test("Haiku tool call returns 2 specialists → classifyAgents preserves order and source='haiku'", async () => {
    mockSend = mock(async () =>
      toolUseResponse({
        agentIds: ["order-management", "product-recommendation"],
        reasoning: "user wants order status AND a laptop pick",
      }),
    );
    const r = await classifyAgents({
      message: "blorple quazzle floom",
    });
    expect(r).toBeDefined();
    expect(r!.selections.length).toBe(2);
    expect(r!.selections[0].agentId).toBe("order-management");
    expect(r!.selections[1].agentId).toBe("product-recommendation");
    expect(r!.selections[0].source).toBe("haiku");
    expect(r!.selections[1].source).toBe("haiku");
    expect(r!.selections[0].reasoning).toContain("order status");
  });

  test("multi-intent escalation: heuristic-collapsing prompt reaches Haiku and multi-selects", async () => {
    // This prompt scores a clear single leader (product-recommendation) with a
    // real-but-sub-threshold runner-up (order-management). Before the
    // escalation gate the heuristic returned a single specialist and Haiku was
    // never consulted. Now it abstains, the Haiku tier runs, and both domains
    // are returned. Proves the bug fix end-to-end.
    mockSend = mock(async () =>
      toolUseResponse({
        agentIds: ["order-management", "product-recommendation"],
        reasoning: "track the order AND recommend a replacement laptop",
      }),
    );
    const r = await classifyAgents({
      message: "Track order ORD-1005 and recommend a replacement laptop with similar specs.",
    });
    expect(mockSend.mock.calls.length).toBe(1); // heuristic deferred → Haiku ran
    expect(r).toBeDefined();
    expect(r!.selections.map((s) => s.agentId)).toEqual([
      "order-management",
      "product-recommendation",
    ]);
    expect(r!.selections.every((s) => s.source === "haiku")).toBe(true);
  });

  test("tool schema receives agent enum and maxItems=CLASSIFIER_MULTI_MAX_AGENTS", async () => {
    process.env.CLASSIFIER_MULTI_MAX_AGENTS = "3";
    resetAgentClassifierCacheForTests();
    _setBedrockClientForTests(makeFakeClient());
    mockSend = mock(async () =>
      toolUseResponse({ agentIds: ["order-management"] }),
    );

    await classifyAgents({ message: "blorple quazzle floom" });

    const cmd = lastInput as { input: { toolConfig?: any } };
    const tool = cmd.input.toolConfig?.tools?.[0]?.toolSpec;
    expect(tool?.name).toBe("route_to_specialists");
    const schema = tool?.inputSchema?.json?.properties?.agentIds;
    expect(schema?.maxItems).toBe(3);
    // Abstain is on by default, so an empty agentIds array is permitted.
    expect(schema?.minItems).toBe(0);
    expect(Array.isArray(schema?.items?.enum)).toBe(true);
    expect(schema.items.enum.length).toBeGreaterThan(0);
    // The abstain channel is offered to the model.
    expect(tool?.inputSchema?.json?.properties?.abstain?.type).toBe("boolean");
  });

  test("Tier B abstain: Haiku sets abstain:true → classifyAgents returns undefined", async () => {
    mockSend = mock(async () => toolUseResponse({ agentIds: [], abstain: true }));
    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r).toBeUndefined();
  });

  test("ORCHESTRATOR_CLARIFY_ON_VAGUE=0 restores legacy schema (minItems 1, no abstain) and forced pick", async () => {
    process.env.ORCHESTRATOR_CLARIFY_ON_VAGUE = "0";
    resetAgentClassifierCacheForTests();
    _setBedrockClientForTests(makeFakeClient());
    mockSend = mock(async () => toolUseResponse({ agentIds: ["order-management"] }));

    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r?.selections[0].agentId).toBe("order-management");

    const cmd = lastInput as { input: { toolConfig?: any } };
    const schema = cmd.input.toolConfig?.tools?.[0]?.toolSpec?.inputSchema?.json;
    expect(schema?.properties?.agentIds?.minItems).toBe(1);
    expect(schema?.properties?.abstain).toBeUndefined();
  });

  test("max-agents cap: tool returns 3 but cap=2 → result is sliced to 2", async () => {
    process.env.CLASSIFIER_MULTI_MAX_AGENTS = "2";
    resetAgentClassifierCacheForTests();
    _setBedrockClientForTests(makeFakeClient());
    mockSend = mock(async () =>
      toolUseResponse({
        agentIds: [
          "order-management",
          "product-recommendation",
          "troubleshooting",
        ],
      }),
    );
    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r!.selections.length).toBe(2);
    expect(r!.selections.map((s) => s.agentId)).toEqual([
      "order-management",
      "product-recommendation",
    ]);
  });

  test("hallucinated agent id is filtered out, valid ids preserved", async () => {
    mockSend = mock(async () =>
      toolUseResponse({
        agentIds: ["bogus-agent-9000", "order-management", "another-fake"],
      }),
    );
    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r!.selections.length).toBe(1);
    expect(r!.selections[0].agentId).toBe("order-management");
  });

  test("duplicate agent ids in tool reply are de-duplicated, first-occurrence order preserved", async () => {
    mockSend = mock(async () =>
      toolUseResponse({
        agentIds: [
          "order-management",
          "order-management",
          "product-recommendation",
          "order-management",
        ],
      }),
    );
    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r!.selections.length).toBe(2);
    expect(r!.selections.map((s) => s.agentId)).toEqual([
      "order-management",
      "product-recommendation",
    ]);
  });

  test("Bedrock send() throws → classifyAgents resolves to undefined (no exception)", async () => {
    mockSend = mock(async () => {
      throw new Error("simulated Bedrock outage");
    });
    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r).toBeUndefined();
  });

  test("Haiku returns no toolUse block → classifyAgents resolves to undefined", async () => {
    mockSend = mock(async () => ({
      output: {
        message: {
          role: "assistant",
          content: [{ text: "I do not know how to route this." }],
        },
      },
    }));
    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r).toBeUndefined();
  });

  test("CLASSIFIER_BACKEND=heuristic → Haiku is NOT called even on a generic prompt", async () => {
    process.env.CLASSIFIER_BACKEND = "heuristic";
    resetAgentClassifierCacheForTests();
    _setBedrockClientForTests(makeFakeClient());
    mockSend = mock(async () =>
      toolUseResponse({ agentIds: ["order-management"] }),
    );
    const r = await classifyAgents({ message: "blorple quazzle floom" });
    expect(r).toBeUndefined();
    expect(mockSend.mock.calls.length).toBe(0);
  });
});
