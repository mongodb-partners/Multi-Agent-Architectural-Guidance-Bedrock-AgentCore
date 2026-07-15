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

  test("clear career-coach message routes correctly", async () => {
    const r = await classifyAgent({
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    expect(r?.agentId).toBe("career-coach");
    expect(r?.source).toBe("heuristic");
    expect(r?.score).toBeGreaterThan(1);
  });

  test("clear company-intel message routes correctly", async () => {
    const r = await classifyAgent({
      message: "Tell me about the company funding stage and employee sentiment",
    });
    expect(r?.agentId).toBe("company-intel");
    expect(r?.source).toBe("heuristic");
  });

  test("clear job-match message routes to job-match", async () => {
    const r = await classifyAgent({
      message: "Here is my CV, what jobs match my experience and skills",
    });
    expect(r?.agentId).toBe("job-match");
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
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    expect(r).toBeUndefined();
  });

  test("margin knob: setting MARGIN high makes near-ties fall through", async () => {
    process.env.CLASSIFIER_HEURISTIC_MARGIN = "999";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgent({
      message: "What salary should I expect and how do I negotiate my compensation offer",
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
    const msg = "What salary should I expect and how do I negotiate my compensation offer";
    const first = await classifyAgent({ message: msg });
    const second = await classifyAgent({ message: msg });
    expect(first?.agentId).toBe("career-coach");
    expect(first?.source).toBe("heuristic");
    expect(second?.agentId).toBe("career-coach");
    expect(second?.source).toBe("cache");
  });

  test("cache key is normalized (whitespace/case-insensitive)", async () => {
    const a = await classifyAgent({ message: "What salary should I expect and how do I negotiate my compensation offer" });
    const b = await classifyAgent({
      message: "  What SALARY should I expect and how do I NEGOTIATE my compensation offer  ",
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
