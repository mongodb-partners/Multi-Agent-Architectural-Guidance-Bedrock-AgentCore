/**
 * `recordSkillResourceRead` + `skill.activated.resourceReads` rollup.
 *
 * The Developer details panel's "Skill resource reads" sub-section needs a
 * per-skill list of every `read_skill_resource(...)` tool invocation that
 * landed during the turn. The collector buffers those rolls and folds them
 * into the matching `skill.activated.resourceReads` on `toJSON()` so older
 * UI code paths that read `skill.activated.resourceReads` keep working
 * unchanged.
 */

import { describe, expect, test } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";

function makeCollector() {
  return new TraceCollector({ sessionId: "s", messageId: "m", agentId: "orchestrator" });
}

describe("TraceCollector — skill resource read rollup", () => {
  test("buffers reads by skill name and surfaces them on the matching skill.activated event", () => {
    const c = makeCollector();
    c.event("skill.activated", {
      name: "order-management",
      reason: "skill_required",
      bodyPreview: "ok",
      bodyBytes: 2,
    });
    c.recordSkillResourceRead({
      skillName: "order-management",
      resourcePath: "references/order-status-codes.md",
      bytes: 4_096,
      toolUseId: "tu-1",
      latencyMs: 5,
    });
    c.recordSkillResourceRead({
      skillName: "order-management",
      resourcePath: "scripts/lookup-order.mjs",
      bytes: 2_048,
      toolUseId: "tu-2",
      latencyMs: 8,
    });

    const json = c.toJSON();
    const skillEv = json.events.find((e) => e.type === "skill.activated");
    expect(skillEv).toBeDefined();
    const reads = (skillEv?.payload as any).resourceReads as Array<{
      resourcePath: string;
      bytes: number;
      toolUseId?: string;
      latencyMs?: number;
    }>;
    expect(reads).toHaveLength(2);
    expect(reads[0].resourcePath).toBe("references/order-status-codes.md");
    expect(reads[0].bytes).toBe(4_096);
    expect(reads[0].toolUseId).toBe("tu-1");
    expect(reads[1].resourcePath).toBe("scripts/lookup-order.mjs");
  });

  test("read for an inactive skill is buffered but does not synthesize a skill.activated event", () => {
    const c = makeCollector();
    c.recordSkillResourceRead({
      skillName: "never-activated",
      resourcePath: "references/x.md",
      bytes: 1,
    });
    const json = c.toJSON();
    expect(json.events.find((e) => e.type === "skill.activated")).toBeUndefined();
    // But the read is still tracked (used by render_developer_details fallback table).
    const reads = c.getSkillResourceReadsForTests();
    expect(reads.get("never-activated")?.length).toBe(1);
  });

  test("skill.activated without any read leaves resourceReads undefined (no empty array clutter)", () => {
    const c = makeCollector();
    c.event("skill.activated", {
      name: "product-discovery",
      reason: "skill_required",
      bodyPreview: "ok",
      bodyBytes: 2,
    });
    const json = c.toJSON();
    const ev = json.events.find((e) => e.type === "skill.activated");
    expect((ev?.payload as any).resourceReads).toBeUndefined();
  });

  test("rollup does not mutate the live events array (snapshot stability)", () => {
    const c = makeCollector();
    c.event("skill.activated", {
      name: "billing",
      reason: "skill_required",
      bodyPreview: "ok",
      bodyBytes: 2,
    });
    c.recordSkillResourceRead({ skillName: "billing", resourcePath: "r.md", bytes: 1 });
    const live = c.getEvents().find((e) => e.type === "skill.activated");
    // Live events array is the pre-rollup view; toJSON returns the folded copy.
    expect((live?.payload as any).resourceReads).toBeUndefined();
    const json = c.toJSON();
    const jsonEv = json.events.find((e) => e.type === "skill.activated");
    expect((jsonEv?.payload as any).resourceReads).toHaveLength(1);
  });
});
