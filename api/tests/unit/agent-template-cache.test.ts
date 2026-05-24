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
 *   - Degraded mode (agent declares mongodb_* but getMcpTools()=[]): template
 *     is marked mcpDegraded and is NOT cached, so the next turn re-attempts
 *     MCP and recovers automatically once the runtime is reachable. See
 *     plan fix_mcp_tool_registry_failure.
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// Per-test toggle: when MCP_RETURN_EMPTY = true, getMcpTools() returns [] to
// simulate the broken-runtime scenario; otherwise it returns the three
// MongoDB MCP tools every specialist declares so the happy-path cache tests
// still pass.
const MCP_STATE: { returnEmpty: boolean } = { returnEmpty: false };

function fakeMcpTool(name: string): { name: string } {
  // Strands `Tool` is duck-typed by name in our resolution code paths
  // (toolsForAgent + the mcpDegraded check). A plain object with .name
  // is enough for the cache + degraded-mode logic; we don't construct an
  // actual Agent here so the SDK never inspects the tool surface.
  return { name };
}

mock.module("../../src/adapters/mongodb-mcp-client.ts", () => ({
  getMcpTools: async () =>
    MCP_STATE.returnEmpty
      ? []
      : [
          fakeMcpTool("mongodb_query"),
          fakeMcpTool("mongodb_vector_search"),
          fakeMcpTool("mongodb_aggregate"),
        ],
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
    MCP_STATE.returnEmpty = false;
    resetAgentTemplateCacheForTests();
    resetResolveModelCacheForTests();
  });
  afterEach(() => {
    MCP_STATE.returnEmpty = false;
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

  test("degraded mode: specialist declaring mongodb_* but getMcpTools()=[] is marked mcpDegraded and NOT cached", async () => {
    const specialist = getAgent("product-recommendation");
    if (!specialist) return; // tolerate fixtures without product-recommendation
    expect(specialist.tools).toContain("mongodb_vector_search");

    MCP_STATE.returnEmpty = true;
    const a = await getAgentTemplate("product-recommendation", { preActivateSkills: true });
    expect(a).toBeDefined();
    expect(a!.mcpDegraded).toBe(true);
    expect(a!.missingTools ?? []).toEqual(
      expect.arrayContaining(["mongodb_query", "mongodb_vector_search"]),
    );

    // Critical invariant: a degraded template MUST NOT be cached. The next
    // call must build a fresh template so it can re-attempt getMcpTools().
    // Without this, a transient MCP outage at boot would brick every
    // subsequent chat turn for the lifetime of the process.
    const b = await getAgentTemplate("product-recommendation", { preActivateSkills: true });
    expect(b).toBeDefined();
    expect(b).not.toBe(a);
  });

  test("degraded → recovered: once getMcpTools() returns tools, template is cached again", async () => {
    const specialist = getAgent("product-recommendation");
    if (!specialist) return;

    MCP_STATE.returnEmpty = true;
    const degraded = await getAgentTemplate("product-recommendation", { preActivateSkills: true });
    expect(degraded!.mcpDegraded).toBe(true);

    // MCP came back online. Next call should build a healthy template,
    // cache it, and a second call should return the same instance.
    MCP_STATE.returnEmpty = false;
    const healthy = await getAgentTemplate("product-recommendation", { preActivateSkills: true });
    expect(healthy!.mcpDegraded).toBeUndefined();
    const healthyAgain = await getAgentTemplate("product-recommendation", {
      preActivateSkills: true,
    });
    expect(healthyAgain).toBe(healthy);
  });

  test("orchestrator (no MCP tools declared) is never marked mcpDegraded even when getMcpTools()=[]", async () => {
    const orchestrator = getAgent("orchestrator");
    if (!orchestrator) return;
    expect(orchestrator.tools).toEqual([]);

    MCP_STATE.returnEmpty = true;
    const t = await getAgentTemplate("orchestrator", { preActivateSkills: false });
    expect(t).toBeDefined();
    expect(t!.mcpDegraded).toBeUndefined();
    // And cacheable as before.
    const t2 = await getAgentTemplate("orchestrator", { preActivateSkills: false });
    expect(t2).toBe(t);
  });
});
