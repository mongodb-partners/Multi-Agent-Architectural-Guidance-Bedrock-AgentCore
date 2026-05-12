import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createApp } from "../../src/app.ts";

describe("GET /demo-prompts", () => {
  const saved = { ...process.env };

  beforeAll(() => {
    process.env.RATE_LIMIT_DISABLED = "1";
    delete process.env.REQUIRE_AUTH;
  });

  afterAll(() => {
    process.env = { ...saved };
  });

  test("returns groups from config/demo-prompts.yaml (no auth required)", async () => {
    const app = createApp();
    const r = await app.request("http://localhost/demo-prompts");
    expect(r.status).toBe(200);
    const body = (await r.json()) as { groups: Array<{ title: string; prompts: unknown[] }> };
    expect(Array.isArray(body.groups)).toBe(true);
    expect(body.groups.length).toBeGreaterThan(0);
    for (const g of body.groups) {
      expect(typeof g.title).toBe("string");
      expect(g.title.length).toBeGreaterThan(0);
      expect(Array.isArray(g.prompts)).toBe(true);
      expect(g.prompts.length).toBeGreaterThan(0);
      for (const p of g.prompts as Array<{ label: string; text: string }>) {
        expect(typeof p.label).toBe("string");
        expect(typeof p.text).toBe("string");
        expect(p.text.length).toBeGreaterThan(0);
      }
    }
  });
});
