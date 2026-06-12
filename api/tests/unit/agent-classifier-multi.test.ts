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
    delete process.env.CLASSIFIER_MULTI_ESCALATE_MIN_SCORE;
    resetAgentClassifierCacheForTests();
  });

  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("single-domain product prompt returns exactly one specialist", async () => {
    const r = await classifyAgents({
      message: "Recommend a budget gaming laptop for me",
    });
    expect(r?.selections.length).toBe(1);
    expect(r?.selections[0].agentId).toBe("product-recommendation");
  });

  test("single-domain troubleshooting prompt returns exactly one specialist", async () => {
    const r = await classifyAgents({
      message: "Error code PWR-001 my device wont power on",
    });
    expect(r?.selections.length).toBe(1);
    expect(r?.selections[0].agentId).toBe("troubleshooting");
  });

  test("single-domain order-tracking prompt returns exactly one specialist", async () => {
    const r = await classifyAgents({
      message: "track my order shipment status please",
    });
    expect(r?.selections.length).toBe(1);
    expect(r?.selections[0].agentId).toBe("order-management");
  });

  test("classifyAgent compatibility wrapper returns the first selection", async () => {
    // Reset between calls so we compare two fresh heuristic results, not
    // a fresh result against a cache hit (cache hits intentionally drop
    // the numeric score).
    const single = await classifyAgent({
      message: "Recommend a budget gaming laptop for me",
    });
    resetAgentClassifierCacheForTests();
    const multi = await classifyAgents({
      message: "Recommend a budget gaming laptop for me",
    });
    expect(single?.agentId).toBe(multi?.selections[0]?.agentId);
    expect(single?.score).toBe(multi?.selections[0]?.score);
    expect(single?.source).toBe(multi?.selections[0]?.source);
  });

  test("threshold knob: tightening multi-min-score collapses any multi-selection back to single", async () => {
    // Use an explicit multi-domain prompt; raise the absolute floor sky-high
    // so the runner-up never qualifies — selection collapses to one. Disable
    // multi-intent escalation here so we isolate the multi-min-score knob from
    // the runner-up escalation gate (which would otherwise defer to Haiku).
    process.env.CLASSIFIER_MULTI_MIN_SCORE = "999";
    process.env.CLASSIFIER_MULTI_ESCALATE_MIN_SCORE = "999";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message:
        "track my order shipment AND recommend a replacement laptop",
    });
    expect(r?.selections.length).toBe(1);
  });

  test("threshold knob: tightening multi-relative-margin collapses to single", async () => {
    // Force the runner-up to be considered "too far" from the leader. Disable
    // escalation to isolate the relative-margin knob from the escalation gate.
    process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN = "0.01";
    process.env.CLASSIFIER_MULTI_ESCALATE_MIN_SCORE = "999";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message:
        "track my order shipment AND recommend a replacement laptop",
    });
    expect(r?.selections.length).toBe(1);
  });

  test("multi-intent escalation: a runner-up with a real second-domain signal defers to Haiku instead of collapsing to one specialist", async () => {
    // Genuine two-domain prompt. The runner-up (order-management) scores a
    // real signal (~1.79) but below the strict multi-select floor (3.0), so
    // the heuristic would otherwise collapse to a single specialist. With
    // escalation enabled (default), it abstains so the Haiku tier can
    // multi-select. Under CLASSIFIER_BACKEND=heuristic, abstain surfaces as
    // undefined (no Haiku call in the test).
    const r = await classifyAgents({
      message: "Track order ORD-1005 and recommend a replacement laptop with similar specs.",
    });
    expect(r).toBeUndefined();
  });

  test("multi-intent escalation does NOT fire for single-domain prompts (runner-up scores 0)", async () => {
    // A clean single-domain prompt has a zero-scoring runner-up, so escalation
    // never triggers and the heuristic still returns exactly one specialist.
    const r = await classifyAgents({
      message: "Recommend a budget gaming laptop for me",
    });
    expect(r?.selections.length).toBe(1);
    expect(r?.selections[0].agentId).toBe("product-recommendation");
  });

  test("escalation can be disabled via CLASSIFIER_MULTI_ESCALATE_MIN_SCORE to restore legacy collapse-to-single", async () => {
    process.env.CLASSIFIER_MULTI_ESCALATE_MIN_SCORE = "999";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message: "Track order ORD-1005 and recommend a replacement laptop with similar specs.",
    });
    expect(r?.selections.length).toBe(1);
  });

  test("classifyAgents reports thresholds snapshot for trace", async () => {
    const r = await classifyAgents({
      message: "Recommend a budget gaming laptop for me",
    });
    expect(r?.thresholds.multiMinScore).toBeGreaterThan(0);
    expect(r?.thresholds.multiRelativeMargin).toBeGreaterThan(0);
    expect(r?.thresholds.multiMaxAgents).toBeGreaterThanOrEqual(1);
  });

  test("rejected candidates are surfaced with reason", async () => {
    const r = await classifyAgents({
      message: "Recommend a budget gaming laptop for me",
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
        "track my order shipment AND recommend a replacement laptop please",
    });
    expect(r).toBeDefined();
    expect((r?.selections.length ?? 0)).toBeGreaterThanOrEqual(2);
    const ids = (r?.selections ?? []).map((s) => s.agentId);
    expect(ids).toContain("order-management");
    expect(ids).toContain("product-recommendation");
  });

  test("CLASSIFIER_MULTI_MAX_AGENTS caps the number of selected specialists", async () => {
    process.env.CLASSIFIER_MULTI_MIN_SCORE = "0.1";
    process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN = "100";
    process.env.CLASSIFIER_MULTI_MAX_AGENTS = "1";
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({
      message:
        "track my order AND recommend a laptop AND troubleshoot error PWR-001",
    });
    expect(r?.selections.length).toBe(1);
  });
});
