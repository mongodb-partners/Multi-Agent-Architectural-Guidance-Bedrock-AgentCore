import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { toolsForAgent } from "../../src/lib/base-tools.ts";
import { resetHttpToolsLoadCacheForTests } from "../../src/lib/http-tools-load.ts";
import { resetHttpToolsMapCacheForTests } from "../../src/lib/http-tools-runtime.ts";
import { SkillRegistry } from "../../src/lib/skill-loader.ts";
import {
  loadSkillHttpToolsDefinitions,
  parseSkillScopedHttpToolName,
  resetSkillHttpToolsCacheForTests,
} from "../../src/lib/skill-http-tools-load.ts";

const fixtureConfigRoot = path.join(import.meta.dir, "../fixtures/config");

describe("skill-scoped http tools", () => {
  const savedEnv = { ...process.env };

  afterEach(() => {
    process.env = { ...savedEnv };
    resetSkillHttpToolsCacheForTests();
    resetHttpToolsLoadCacheForTests();
    resetHttpToolsMapCacheForTests();
  });

  test("parseSkillScopedHttpToolName prefers longest skill id", () => {
    const allowed = new Set(["order-management", "order"]);
    expect(parseSkillScopedHttpToolName("order-management/notify", allowed)).toEqual({
      skillName: "order-management",
      localToolName: "notify",
    });
    expect(parseSkillScopedHttpToolName("order/notify", allowed)).toEqual({
      skillName: "order",
      localToolName: "notify",
    });
    expect(parseSkillScopedHttpToolName("order-management/extra/bad", allowed)).toBeNull();
    expect(parseSkillScopedHttpToolName("mongodb_query", allowed)).toBeNull();
  });

  test("loadSkillHttpToolsDefinitions reads config/skills/<id>/http-tools.json", () => {
    process.env.CONFIG_ROOT = fixtureConfigRoot;
    const defs = loadSkillHttpToolsDefinitions("demo-skill", true);
    expect(defs.length).toBe(1);
    expect(defs[0]!.name).toBe("fixture_ping");
  });

  test("toolsForAgent wires demo-skill/fixture_ping when listed and skill activated", () => {
    process.env.CONFIG_ROOT = fixtureConfigRoot;
    process.env.HTTP_TOOLS_MOCK = "1";
    const rootFile = path.join(fixtureConfigRoot, "http-tools.json");
    const prevPath = process.env.HTTP_TOOLS_CONFIG_PATH;
    process.env.HTTP_TOOLS_CONFIG_PATH = rootFile;
    const securityOnly = JSON.stringify({
      security: { allowedHosts: ["allowed.example.test"] },
      tools: [],
    });
    writeFileSync(rootFile, securityOnly, "utf8");
    resetHttpToolsLoadCacheForTests();
    resetHttpToolsMapCacheForTests();
    try {
      const registry = new SkillRegistry(["demo-skill"]);
      registry.activate("demo-skill");
      const tools = toolsForAgent(["demo-skill/fixture_ping"], registry);
      const names = tools.map((t) => (t as { name?: string }).name ?? (t as { spec?: { name?: string } }).spec?.name);
      expect(names).toContain("demo-skill/fixture_ping");
    } finally {
      if (existsSync(rootFile)) unlinkSync(rootFile);
      if (prevPath === undefined) delete process.env.HTTP_TOOLS_CONFIG_PATH;
      else process.env.HTTP_TOOLS_CONFIG_PATH = prevPath;
    }
  });
});
