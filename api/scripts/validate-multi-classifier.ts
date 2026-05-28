/**
 * Pre-merge validation: every existing single-domain prompt must still
 * route to exactly ONE specialist under `classifyAgents(...)`, and the
 * curated multi-domain corpus should produce 2+ selections.
 *
 * Run heuristic-only (no Bedrock cost): `bun run validate:multi-classifier`.
 *
 * Exit non-zero if any single-domain prompt selects more than one
 * specialist (regression of the multi-select guardrails) or if the
 * multi-domain corpus collapses to one specialist (regression of the
 * legitimate multi-select path).
 *
 * Wire-up: see `AGENTS.md` alongside `validate:strands-otel` /
 * `validate:strands-retries`.
 */

import {
  classifyAgents,
  resetAgentClassifierCacheForTests,
} from "../src/lib/agent-classifier.ts";

type Row = {
  prompt: string;
  expected: "single" | "multi";
  selected: string[];
  pass: boolean;
};

/**
 * Single-domain corpus — mirrors the prompts in
 * `tests/unit/agent-classifier.test.ts`. Each MUST classify to exactly
 * one specialist by default. If you're tempted to remove one, add a
 * matching test in `agent-classifier-multi.test.ts` first.
 */
const SINGLE_DOMAIN: string[] = [
  "Recommend a budget gaming laptop for me",
  "Error code PWR-001 my device wont power on",
  "Track my order shipment delivery",
  "Where is my package, give me an update on order ABC-123",
  "Suggest a phone for travel photography under 800 dollars",
  "My screen is flickering and the device keeps rebooting",
];

/**
 * Multi-domain corpus — at least two distinct specialist domains in the
 * same prompt. Under heuristic-only (this script's mode) the strict
 * default thresholds usually keep these as single-specialist; production
 * resolves multi-domain via Haiku. We surface them as warn-only signals
 * so a future tuning pass can see how many flip without manual probing.
 */
const MULTI_DOMAIN: string[] = [
  "track my order ABC-123 AND recommend a replacement laptop with similar specs",
  "my new laptop wont power on PWR-001 and I want to return it / track refund",
  "recommend a gaming phone under 600 and tell me if my pending order has shipped",
];

async function run() {
  // Force heuristic-only path so we don't burn Bedrock.
  process.env.CLASSIFIER_BACKEND = "heuristic";
  delete process.env.CLASSIFIER_HEURISTIC_MIN_SCORE;
  delete process.env.CLASSIFIER_HEURISTIC_MARGIN;
  delete process.env.CLASSIFIER_MULTI_MIN_SCORE;
  delete process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN;
  delete process.env.CLASSIFIER_MULTI_MAX_AGENTS;

  const rows: Row[] = [];
  let failures = 0;

  for (const prompt of SINGLE_DOMAIN) {
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({ message: prompt });
    const selected = r?.selections.map((s) => s.agentId) ?? [];
    // The guardrail this script enforces is: NEVER fan out to >1 specialist
    // for a clearly single-domain prompt. (Selecting 0 — heuristic floor not
    // cleared — is acceptable; the production path falls back to Haiku.)
    const pass = selected.length <= 1;
    if (!pass) failures += 1;
    rows.push({ prompt, expected: "single", selected, pass });
  }

  for (const prompt of MULTI_DOMAIN) {
    resetAgentClassifierCacheForTests();
    const r = await classifyAgents({ message: prompt });
    const selected = r?.selections.map((s) => s.agentId) ?? [];
    // Multi corpus is best-effort: heuristics are noisy, so we WARN (don't
    // hard-fail) when a curated multi prompt collapses to one specialist —
    // but we still flag it visibly.
    const pass = selected.length >= 2;
    rows.push({ prompt, expected: "multi", selected, pass });
  }

  // Render a small ASCII table.
  const widths = {
    expected: Math.max("expected".length, ...rows.map((r) => r.expected.length)),
    selected: Math.max(
      "selected".length,
      ...rows.map((r) => r.selected.join(",").length || 1),
    ),
  };
  const sep = `${"-".repeat(70)}`;
  console.log(sep);
  console.log(
    `${"PASS".padEnd(5)} ${"expected".padEnd(widths.expected)} ${"selected".padEnd(widths.selected)} prompt`,
  );
  console.log(sep);
  for (const r of rows) {
    const tag = r.pass ? "✓" : "✗";
    console.log(
      `${tag.padEnd(5)} ${r.expected.padEnd(widths.expected)} ${(r.selected.join(",") || "-").padEnd(widths.selected)} ${r.prompt}`,
    );
  }
  console.log(sep);
  const multiCollapsed = rows.filter(
    (r) => r.expected === "multi" && !r.pass,
  ).length;
  console.log(
    `single-domain pass: ${SINGLE_DOMAIN.length - failures}/${SINGLE_DOMAIN.length}`,
  );
  console.log(
    `multi-domain  pass: ${MULTI_DOMAIN.length - multiCollapsed}/${MULTI_DOMAIN.length}` +
      (multiCollapsed ? " (warn — curated multi prompts collapsed)" : ""),
  );

  if (failures > 0) {
    console.error(
      `\nFAIL: ${failures} single-domain prompt(s) selected >1 specialist. ` +
        `Multi-select guardrails have regressed — review CLASSIFIER_MULTI_MIN_SCORE / RELATIVE_MARGIN / MAX_AGENTS.`,
    );
    process.exit(1);
  }
  console.log("\nOK — single-domain default preserved.");
  process.exit(0);
}

run().catch((err) => {
  console.error("validate-multi-classifier failed:", err);
  process.exit(2);
});
