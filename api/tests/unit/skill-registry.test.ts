import { describe, expect, test } from "bun:test";
import { readSkillResourceWithRegistry } from "../../src/lib/base-tools.ts";
import { SkillRegistry } from "../../src/lib/skill-loader.ts";

describe("SkillRegistry + read_skill_resource gates", () => {
  test("read blocked until skill is activated", () => {
    const registry = new SkillRegistry(["order-management"]);
    expect(registry.isSkillActivated("order-management")).toBe(false);

    const blocked = readSkillResourceWithRegistry(
      registry,
      "order-management",
      "references/order-schema.md",
    );
    expect(blocked).toMatchObject({ ok: false, error: "skill_not_activated" });

    registry.activate("order-management");
    expect(registry.isSkillActivated("order-management")).toBe(true);

    const ok = readSkillResourceWithRegistry(
      registry,
      "order-management",
      "references/order-schema.md",
    ) as { ok: true; content: string; path: string };
    expect(ok.ok).toBe(true);
    expect(ok.path).toBe("references/order-schema.md");
    expect(ok.content).toContain("orderId");
  });

  test("skill not in agent list is rejected", () => {
    const registry = new SkillRegistry(["order-management"]);
    registry.activate("order-management");
    const r = readSkillResourceWithRegistry(
      registry,
      "troubleshooting",
      "references/common-issues.md",
    );
    expect(r).toMatchObject({ ok: false, error: "skill_not_allowed_for_agent" });
  });
});
