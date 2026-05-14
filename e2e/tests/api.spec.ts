import { test, expect } from "@playwright/test";

// Smoke tests against a live API (set API_URL). All stub-mode assumptions
// have been removed — these tests rely on a real AgentCore Runtime, so
// they only assert read-only public endpoints.

test.describe("API smoke", () => {
  test("GET /health returns ok", async ({ request }) => {
    const res = await request.get("/health");
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body).toMatchObject({ status: expect.any(String) });
  });

  test("GET /agents includes orchestrator + bundled specialists", async ({ request }) => {
    const res = await request.get("/agents");
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    const agents = body.agents as { id: string }[];
    expect(Array.isArray(agents)).toBe(true);
    const ids = agents.map((a) => a.id);
    expect(ids).toContain("orchestrator");
    expect(ids).toContain("order-management");
  });

  test("GET /skills lists domain skills", async ({ request }) => {
    const res = await request.get("/skills");
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    const skills = body.skills as { name: string }[];
    expect(Array.isArray(skills)).toBe(true);
    const names = skills.map((s) => s.name);
    expect(names).toContain("order-management");
  });
});
