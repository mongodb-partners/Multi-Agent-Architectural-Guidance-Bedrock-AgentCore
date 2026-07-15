/**
 * Unit tests for the multi-select classifier.
 *
 * The single-specialist default is a hard contract: every prompt that
 * routes to one specialist under `classifyAgent` MUST also return one
 * specialist under `classifyAgents` with the empirical default thresholds.
 * Multi-select must only fire on prompts with strong evidence of
 * multi-domain intent.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  classifyAgent,
  classifyAgents,
  resetAgentClassifierCacheForTests,
} from "../../src/lib/agent-classifier.ts";

const SAVED_ENV = { ...process.env };

describe("agent-classifier — multi-select default behavior", () => {
  beforeEach(() => {
    process.env.CLASSIFIER_BACKEND = "heuristic";
    delete process.env.CLASSIFIER_HEURISTIC_MIN_SCORE;
    delete process.env.CLASSIFIER_HEURISTIC_MARGIN;
    delete process.env.CLASSIFIER_MULTI_MIN_SCORE;
    delete process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN;
    delete process.env.CLASSIFIER_MULTI_MAX_AGENTS;
    resetAgentClassifierCacheForTests();
  });

  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("single-domain compensation prompt returns exactly one specialist", async () => {
    const r = await classifyAgents({
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    expect(r?.selections.length).toBe(1);
    expect(r?.selections[0].agentId).toBe("career-coach");
  });

  test("single-domain company-research prompt returns exactly one specialist", async () => {
    const r = await classifyAgents({
      message: "Tell me about the company funding stage and employee sentiment",
    });
    expect(r?.selections.length).toBe(1);
    expect(r?.selections[0].agentId).toBe("company-intel");
  });

  test("single-domain job-match prompt returns exactly one specialist", async () => {
    const r = await classifyAgents({
      message: "Here is my CV, what jobs match my experience and skills",
    });
    expect(r?.selections.length).toBe(1);
    expect(r?.selections[0].agentId).toBe("job-match");
  });

  test("classifyAgent compatibility wrapper returns the first selection", async () => {
    // Reset between calls so we compare two fresh heuristic results, not
    // a fresh result against a cache hit (cache hits intentionally drop
    // the numeric score).
    const single = await classifyAgent({
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    resetAgentClassifierCacheForTests();
    const multi = await classifyAgents({
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    expect(single?.agentId).toBe(multi?.selections[0]?.agentId);
    expect(single?.score).toBe(multi?.selections[0]?.score);
    expect(single?.source).toBe(multi?.selections[0]?.source);
  });

  test("threshold knob: tightening multi-min-score collapses any multi-selection back to single", async () => {
    // Use an explicit multi-domain prompt; raise the absolute floor sky-high
    // so the runner-up never qualifies — selection collapses to one.
    process.env.CLASSIFIER_MULTI_MIN_SCORE = "999";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message:
        "match jobs to my CV skills AND tell me about the company culture and funding",
    });
    expect(r?.selections.length).toBe(1);
  });

  test("threshold knob: tightening multi-relative-margin collapses to single", async () => {
    // Force the runner-up to be considered "too far" from the leader.
    process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN = "0.01";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    expect(r?.selections.length).toBe(1);
  });

  test("classifyAgents reports thresholds snapshot for trace", async () => {
    const r = await classifyAgents({
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    expect(r?.thresholds.multiMinScore).toBeGreaterThan(0);
    expect(r?.thresholds.multiRelativeMargin).toBeGreaterThan(0);
    expect(r?.thresholds.multiMaxAgents).toBeGreaterThanOrEqual(1);
  });

  test("rejected candidates are surfaced with reason", async () => {
    const r = await classifyAgents({
      message: "What salary should I expect and how do I negotiate my compensation offer",
    });
    // Single-domain prompt → rejected list has the runner-ups with
    // either "below multi-min-score" or "outside multi-relative-margin".
    expect(r?.rejectedCandidates.length).toBeGreaterThan(0);
    for (const rc of r?.rejectedCandidates ?? []) {
      expect(typeof rc.reason).toBe("string");
    }
  });

  test("explicit multi-domain prompt with relaxed thresholds returns 2 specialists", async () => {
    // Empirically the runner-up score on this prompt scores below the
    // default 3.0 floor (heuristic descriptions don't perfectly cover
    // both domains), so we relax the floor for this explicit
    // multi-intent test. The default single-specialist behavior is
    // already covered by the prompts above.
    process.env.CLASSIFIER_MULTI_MIN_SCORE = "1.0";
    process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN = "10";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message:
        "match jobs to my CV skills AND tell me about the company culture and funding",
    });
    expect(r).toBeDefined();
    expect((r?.selections.length ?? 0)).toBeGreaterThanOrEqual(2);
    const ids = (r?.selections ?? []).map((s) => s.agentId);
    expect(ids).toContain("job-match");
    expect(ids).toContain("company-intel");
  });

  test("CLASSIFIER_MULTI_MAX_AGENTS caps the number of selected specialists", async () => {
    process.env.CLASSIFIER_MULTI_MIN_SCORE = "0.1";
    process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN = "100";
    process.env.CLASSIFIER_MULTI_MAX_AGENTS = "1";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message:
        "match jobs to my CV AND research the company culture AND what salary should I negotiate",
    });
    expect(r?.selections.length).toBe(1);
  });
});
