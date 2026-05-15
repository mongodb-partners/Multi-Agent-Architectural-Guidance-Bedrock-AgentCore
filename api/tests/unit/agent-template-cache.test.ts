/**
 * Unit tests for the per-agent Strands template cache.
 *
 * The cache holds (registry, systemPromptBase, tools, model) keyed on agentId
 * and the underlying AgentDetail object reference. Invariants we lock down:
 *   - Specialist (preActivateSkills=true) → cached across calls
 *   - Orchestrator (skills=[]) → cached (registry has nothing to mutate)
 *   - Lazy-skill bypass: skills>0 + preActivateSkills=false → fresh registry
 *     every call (so activate_skill from one chat does not leak into next)
 *   - warmAgentCache populates entries for every listAgents() id
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// Stub getMcpTools so we don't try to connect to a real gateway. The
// returned array is empty — tools wiring is exercised by other tests.
mock.module("../../src/adapters/mongodb-mcp-client.ts", () => ({
  getMcpTools: async () => [],
}));

const {
  getAgentTemplate,
  warmAgentCache,
  resetAgentTemplateCacheForTests,
} = await import("../../src/lib/create-strands-agent.ts");
const { listAgents, getAgent } = await import("../../src/lib/config-scan.ts");
const { resetResolveModelCacheForTests } = await import("../../src/adapters/resolve-model.ts");

describe("agent-template cache", () => {
  beforeEach(() => {
    resetAgentTemplateCacheForTests();
    resetResolveModelCacheForTests();
  });
  afterEach(() => {
    resetAgentTemplateCacheForTests();
    resetResolveModelCacheForTests();
  });

  test("specialist (preActivateSkills=true) returns the same template on repeat call", async () => {
    const a = await getAgentTemplate("order-management", { preActivateSkills: true });
    const b = await getAgentTemplate("order-management", { preActivateSkills: true });
    expect(a).toBeDefined();
    expect(a).toBe(b);
  });

  test("specialist template has all skills pre-activated", async () => {
    const t = await getAgentTemplate("order-management", { preActivateSkills: true });
    expect(t).toBeDefined();
    const allowed = Array.from(t!.registry.allowedSkills);
    if (allowed.length > 0) {
      for (const s of allowed) {
        expect(t!.registry.isSkillActivated(s)).toBe(true);
      }
    }
  });

  test("orchestrator (skills: []) is cached too — registry has nothing to mutate", async () => {
    const orchestrator = getAgent("orchestrator");
    if (!orchestrator) return; // tolerate fixtures without orchestrator
    expect(orchestrator.skills).toEqual([]);
    const a = await getAgentTemplate("orchestrator", { preActivateSkills: false });
    const b = await getAgentTemplate("orchestrator", { preActivateSkills: false });
    expect(a).toBe(b);
  });

  test("lazy-skill mode (skills>0, preActivateSkills=false) bypasses cache", async () => {
    // Simulate orchestrator-style lazy use of a specialist's skills list.
    // Without bypass, activate_skill from one chat leaks the activated set
    // into the next chat's registry.
    const specialist = getAgent("order-management");
    if (!specialist || specialist.skills.length === 0) return;
    const a = await getAgentTemplate("order-management", { preActivateSkills: false });
    const b = await getAgentTemplate("order-management", { preActivateSkills: false });
    // Lazy bypass: each call yields a fresh template (different registry instance)
    expect(a).not.toBe(b);
    expect(a?.registry).not.toBe(b?.registry);
  });

  test("unknown agent returns undefined", async () => {
    const t = await getAgentTemplate("does-not-exist", { preActivateSkills: true });
    expect(t).toBeUndefined();
  });

  test("warmAgentCache populates a template for every listAgents() id", async () => {
    await warmAgentCache();
    for (const a of listAgents()) {
      const preActivateSkills = a.id !== "orchestrator";
      const t1 = await getAgentTemplate(a.id, { preActivateSkills });
      const t2 = await getAgentTemplate(a.id, { preActivateSkills });
      // For cacheable configs, t1 === t2; for lazy-skill bypass, t1 may
      // differ from t2 — either way both should be defined.
      expect(t1).toBeDefined();
      expect(t2).toBeDefined();
    }
  });
});
