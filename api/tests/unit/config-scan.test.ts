import path from "node:path";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { clearConfigCacheForTests, getAgent, listAgents, listSkills } from "../../src/lib/config-scan.ts";
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

  test("listSkills discovers bundled skills from config/skills (config-only)", () => {
    const skills = listSkills();
    const names = skills.map((s) => s.name);
    for (const id of ["order-management", "product-recommendation", "troubleshooting"] as const) {
      expect(names).toContain(id);
    }
    expect(skills.every((s) => s.description.length > 0)).toBe(true);
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
