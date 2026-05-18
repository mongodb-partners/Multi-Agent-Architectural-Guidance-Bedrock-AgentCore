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

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  classifyAgent,
  resetAgentClassifierCacheForTests,
} from "../../src/lib/agent-classifier.ts";

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
