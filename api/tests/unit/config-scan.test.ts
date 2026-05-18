import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  clearConfigCacheForTests,
  getAgent,
  listAgents,
  listSkills,
  loadAgentPersona,
} from "../../src/lib/config-scan.ts";
import { clearSkillDiscoveryCacheForTests } from "../../src/lib/skill-loader.ts";

describe("config-scan", () => {
  test("listAgents includes orchestrator and specialists", () => {
    const agents = listAgents();
    const ids = agents.map((a) => a.id).sort();
    expect(ids).toContain("orchestrator");
    expect(ids).toContain("order-management");
    expect(ids).toContain("product-recommendation");
    expect(ids).toContain("troubleshooting");
  });

  test("getAgent returns tools for order-management", () => {
    const a = getAgent("order-management");
    expect(a).toBeDefined();
    expect(a!.tools).toContain("mongodb_query");
    expect(a!.tools).toContain("run_skill_script");
  });

  test("getAgent returns tools for troubleshooting including run_skill_script", () => {
    const a = getAgent("troubleshooting");
    expect(a).toBeDefined();
    expect(a!.tools).toContain("mongodb_vector_search");
    expect(a!.tools).toContain("bedrock_kb_retrieve");
    expect(a!.tools).toContain("run_skill_script");
  });

  test("orchestrator handoffs are generated from specialist configs", () => {
    const specialistIds = listAgents()
      .map((a) => a.id)
      .filter((id) => id !== "orchestrator")
      .sort();
    const orchestrator = getAgent("orchestrator");
    expect(orchestrator).toBeDefined();
    expect(orchestrator!.handoffs.map((h) => h.agent).sort()).toEqual(specialistIds);
  });

  test("orchestrator persona includes generated specialist roster", () => {
    const persona = loadAgentPersona("orchestrator") ?? "";
    expect(persona).toContain("Available specialist agents (generated from config/agents)");
    expect(persona).toContain("order-management");
    expect(persona).toContain("product-recommendation");
    expect(persona).toContain("troubleshooting");
  });

  test("listSkills discovers bundled skills from config/skills (config-only)", () => {
    const skills = listSkills();
    const names = skills.map((s) => s.name);
    for (const id of ["order-management", "product-recommendation", "troubleshooting"] as const) {
      expect(names).toContain(id);
    }
    expect(skills.every((s) => s.description.length > 0)).toBe(true);
  });
});

describe("config-scan — dynamic agent roster from CONFIG_ROOT", () => {
  let fixtureRoot: string;
  let prevRoot: string | undefined;

  beforeEach(() => {
    prevRoot = process.env.CONFIG_ROOT;
    fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "dynamic-agents-"));
    const agentsDir = path.join(fixtureRoot, "agents");
    fs.mkdirSync(agentsDir, { recursive: true });
    fs.writeFileSync(
      path.join(agentsDir, "orchestrator.agent.md"),
      `---
name: Orchestrator
description: Routes customer messages.
id: orchestrator
skills: []
tools: []
model: test-model
---

# Orchestrator

Route to the best specialist.
`,
    );
    fs.writeFileSync(
      path.join(agentsDir, "banana-support.agent.md"),
      `---
name: Banana Support
description: Handles banana ripeness and peel questions.
id: banana-support
skills: []
tools: []
model: test-model
---

# Banana Support

Answer banana questions.
`,
    );
    process.env.CONFIG_ROOT = fixtureRoot;
    clearConfigCacheForTests();
  });

  afterEach(() => {
    if (prevRoot !== undefined) process.env.CONFIG_ROOT = prevRoot;
    else delete process.env.CONFIG_ROOT;
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
    clearConfigCacheForTests();
  });

  test("new specialist appears in orchestrator handoffs without editing orchestrator config", () => {
    const orchestrator = getAgent("orchestrator");
    expect(orchestrator?.handoffs).toEqual([
      expect.objectContaining({
        agent: "banana-support",
        label: "Banana Support",
      }),
    ]);
    expect(loadAgentPersona("orchestrator")).toContain("banana-support");
  });
});

describe("config-scan — extra skill dir (CONFIG_ROOT fixture)", () => {
  const fixtureRoot = path.join(import.meta.dir, "../fixtures/config-extra-skill-only");
  let prevRoot: string | undefined;

  beforeEach(() => {
    prevRoot = process.env.CONFIG_ROOT;
    process.env.CONFIG_ROOT = fixtureRoot;
    clearConfigCacheForTests();
    clearSkillDiscoveryCacheForTests();
  });

  afterEach(() => {
    if (prevRoot !== undefined) process.env.CONFIG_ROOT = prevRoot;
    else delete process.env.CONFIG_ROOT;
    clearConfigCacheForTests();
    clearSkillDiscoveryCacheForTests();
  });

  test("discovers only fixture skill tree without TypeScript changes", () => {
    expect(listAgents()).toEqual([]);
    const skills = listSkills();
    expect(skills.map((s) => s.name)).toEqual(["e2e-fixture-skill"]);
    expect(skills[0]?.description.length).toBeGreaterThan(0);
  });
});
