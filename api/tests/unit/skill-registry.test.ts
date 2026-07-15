import { describe, expect, test } from "bun:test";
import { readSkillResourceWithRegistry } from "../../src/lib/base-tools.ts";
import { SkillRegistry } from "../../src/lib/skill-loader.ts";

describe("SkillRegistry + read_skill_resource gates", () => {
  test("read blocked until skill is activated", () => {
    const registry = new SkillRegistry(["job-match"]);
    expect(registry.isSkillActivated("job-match")).toBe(false);

    const blocked = readSkillResourceWithRegistry(
      registry,
      "job-match",
      "references/collections-schema.md",
    );
    expect(blocked).toMatchObject({ ok: false, error: "skill_not_activated" });

    registry.activate("job-match");
    expect(registry.isSkillActivated("job-match")).toBe(true);

    const ok = readSkillResourceWithRegistry(
      registry,
      "job-match",
      "references/collections-schema.md",
    ) as { ok: true; content: string; path: string };
    expect(ok.ok).toBe(true);
    expect(ok.path).toBe("references/collections-schema.md");
    expect(ok.content).toContain("jobId");
  });

  test("skill not in agent list is rejected", () => {
    const registry = new SkillRegistry(["job-match"]);
    registry.activate("job-match");
    const r = readSkillResourceWithRegistry(
      registry,
      "company-intel",
      "references/collections-schema.md",
    );
    expect(r).toMatchObject({ ok: false, error: "skill_not_allowed_for_agent" });
  });
});
