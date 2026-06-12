/**
 * Unit tests for the front-door agent classifier.
 *
 * The classifier sits on the critical path of every chat — heuristic must
 * not over-pick (Haiku is way more expensive) and Haiku must not be reached
 * when CLASSIFIER_BACKEND=heuristic is set. Cache hits must be honored.
 *
 * Note: which exact agent the heuristic picks for a given message depends
 * on the generated specialist roster from `config/agents/*.agent.md`, so test
 * prompts here were empirically chosen to score decisively against the current
 * specialist descriptions/instructions. If those configs change materially,
 * regenerate the prompts via:
 *   bun -e 'import("./src/lib/agent-classifier.ts").then(({classifyAgent}) => …)'
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import {
  classifyAgent,
  resetAgentClassifierCacheForTests,
  _setBedrockClientForTests,
} from "../../src/lib/agent-classifier.ts";
import type { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";

const SAVED_ENV = { ...process.env };

describe("agent-classifier — heuristic", () => {
  beforeEach(() => {
    process.env.CLASSIFIER_BACKEND = "heuristic";
    delete process.env.CLASSIFIER_HEURISTIC_MIN_SCORE;
    delete process.env.CLASSIFIER_HEURISTIC_MARGIN;
    resetAgentClassifierCacheForTests();
  });

  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("clear product-recommendation message routes correctly", async () => {
    const r = await classifyAgent({
      message: "Recommend a budget gaming laptop for me",
    });
    expect(r?.agentId).toBe("product-recommendation");
    expect(r?.source).toBe("heuristic");
    expect(r?.score).toBeGreaterThan(1);
  });

  test("clear troubleshooting message routes correctly", async () => {
    const r = await classifyAgent({
      message: "Error code PWR-001 my device wont power on",
    });
    expect(r?.agentId).toBe("troubleshooting");
    expect(r?.source).toBe("heuristic");
  });

  test("clear order-tracking message routes to order-management", async () => {
    // Using domain-specific verbs ("track", "shipment", "delivery") so the
    // score margin over product-rec / troubleshooting is decisive.
    const r = await classifyAgent({
      message: "Track my order shipment delivery",
    });
    expect(r?.agentId).toBe("order-management");
    expect(r?.source).toBe("heuristic");
  });

  test("generic message falls through when no specialist corpus matches", async () => {
    // With Haiku disabled, a generic message with no domain terms must return
    // undefined instead of forcing a weak heuristic match.
    const r = await classifyAgent({ message: "blorple quazzle floom" });
    expect(r).toBeUndefined();
  });

  test("threshold knob: setting MIN_SCORE high makes everything fall through", async () => {
    process.env.CLASSIFIER_HEURISTIC_MIN_SCORE = "999";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgent({
      message: "Recommend a budget gaming laptop for me",
    });
    expect(r).toBeUndefined();
  });

  test("margin knob: setting MARGIN high makes near-ties fall through", async () => {
    process.env.CLASSIFIER_HEURISTIC_MARGIN = "999";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgent({
      message: "Recommend a budget gaming laptop for me",
    });
    expect(r).toBeUndefined();
  });
});

describe("agent-classifier — Tier A deterministic low-signal gate", () => {
  // A throwing client proves the deterministic gate short-circuits BEFORE any
  // Bedrock/Haiku call is made for vague messages.
  let send: ReturnType<typeof mock>;
  function makeThrowingClient(): BedrockRuntimeClient {
    return {
      send: (...args: unknown[]) => send(...args),
    } as unknown as BedrockRuntimeClient;
  }

  beforeEach(() => {
    // Haiku enabled (backend unset) — the gate must still bypass it.
    delete process.env.CLASSIFIER_BACKEND;
    delete process.env.ORCHESTRATOR_CLARIFY_ON_VAGUE;
    resetAgentClassifierCacheForTests();
    send = mock(() => {
      throw new Error("Bedrock must not be called for low-signal messages");
    });
    _setBedrockClientForTests(makeThrowingClient());
  });
  afterEach(() => {
    _setBedrockClientForTests(null);
    process.env = { ...SAVED_ENV };
  });

  test('"Can you help me?" abstains without calling Bedrock', async () => {
    const r = await classifyAgent({ message: "Can you help me?" });
    expect(r).toBeUndefined();
    expect(send.mock.calls.length).toBe(0);
  });

  test('"what can you do?" abstains without calling Bedrock', async () => {
    const r = await classifyAgent({ message: "what can you do?" });
    expect(r).toBeUndefined();
    expect(send.mock.calls.length).toBe(0);
  });

  test("bare greeting of only stopwords/short tokens abstains", async () => {
    const r = await classifyAgent({ message: "hi, can you?" });
    expect(r).toBeUndefined();
    expect(send.mock.calls.length).toBe(0);
  });

  test("a message with content tokens is NOT gated (Bedrock is consulted)", async () => {
    // "blorple" survives tokenization, so the gate does not fire; the heuristic
    // misses and the Haiku path is reached → our throwing client is invoked.
    await classifyAgent({ message: "blorple quazzle floom" }).catch(() => undefined);
    expect(send.mock.calls.length).toBeGreaterThan(0);
  });

  test('Tier A2: "I need help with something" abstains (only filler token survives)', async () => {
    // stopwords strip i/need/help/with → only "something" (a low-signal filler)
    // remains, so the gate abstains without calling Haiku.
    const r = await classifyAgent({ message: "I need help with something" });
    expect(r).toBeUndefined();
    expect(send.mock.calls.length).toBe(0);
  });

  test('Tier A2: "can you help me with anything" abstains', async () => {
    const r = await classifyAgent({ message: "can you help me with anything" });
    expect(r).toBeUndefined();
    expect(send.mock.calls.length).toBe(0);
  });

  test("Tier A2 does NOT fire when a real domain token is present", async () => {
    // "laptop" is a real domain token, so even alongside "something" the gate
    // must NOT abstain — the message is routable (heuristic → product-rec).
    const r = await classifyAgent({ message: "I need something like a laptop" });
    expect(r?.agentId).toBe("product-recommendation");
  });

  test("ORCHESTRATOR_CLARIFY_ON_VAGUE gates the A2 filler abstain", async () => {
    // ON (default): a filler-only message abstains via the deterministic A2 gate
    // — even though "something" happens to match the product-rec corpus, A2 runs
    // first and short-circuits to clarification.
    const on = await classifyAgent({ message: "I need help with something" });
    expect(on).toBeUndefined();
    expect(send.mock.calls.length).toBe(0);
    // OFF: A2 is skipped, so the message routes through the normal path instead
    // of being force-abstained (no clarification forced).
    process.env.ORCHESTRATOR_CLARIFY_ON_VAGUE = "0";
    resetAgentClassifierCacheForTests();
    _setBedrockClientForTests(makeThrowingClient());
    const off = await classifyAgent({ message: "I need help with something" });
    expect(off).toBeDefined();
  });
});

describe("agent-classifier — cache", () => {
  beforeEach(() => {
    process.env.CLASSIFIER_BACKEND = "heuristic";
    delete process.env.CLASSIFIER_HEURISTIC_MIN_SCORE;
    delete process.env.CLASSIFIER_HEURISTIC_MARGIN;
    resetAgentClassifierCacheForTests();
  });
  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("repeated identical message hits the cache (source = 'cache')", async () => {
    const msg = "Recommend a budget gaming laptop for me";
    const first = await classifyAgent({ message: msg });
    const second = await classifyAgent({ message: msg });
    expect(first?.agentId).toBe("product-recommendation");
    expect(first?.source).toBe("heuristic");
    expect(second?.agentId).toBe("product-recommendation");
    expect(second?.source).toBe("cache");
  });

  test("cache key is normalized (whitespace/case-insensitive)", async () => {
    const a = await classifyAgent({ message: "Recommend a budget gaming laptop for me" });
    const b = await classifyAgent({
      message: "  RECOMMEND a Budget Gaming LAPTOP for me  ",
    });
    expect(a?.source).toBe("heuristic");
    expect(b?.source).toBe("cache");
    expect(a?.agentId).toBe(b?.agentId);
  });

  test("ambiguous fall-through results are NOT cached (so a future Haiku-enabled call still fires)", async () => {
    const msg = "blorple quazzle floom";
    const a = await classifyAgent({ message: msg });
    const b = await classifyAgent({ message: msg });
    expect(a).toBeUndefined();
    expect(b).toBeUndefined();
    // No "source: cache" returned because nothing was cached.
  });
});
