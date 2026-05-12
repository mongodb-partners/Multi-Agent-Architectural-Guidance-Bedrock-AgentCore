import { test, expect } from "@playwright/test";

test.describe("API (stub server)", () => {
  test("GET /health returns ok", async ({ request }) => {
    const res = await request.get("/health");
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body).toMatchObject({ status: expect.any(String) });
  });

  test("GET /agents includes orchestrator", async ({ request }) => {
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

  test("POST /chat streams stub tokens and done", async ({ request }) => {
    const sid = `e2e_${Date.now()}`;
    const res = await request.post("/chat", {
      headers: {
        Accept: "text/event-stream",
        "Content-Type": "application/json",
      },
      data: {
        message: "hello e2e",
        sessionId: sid,
        agentId: "orchestrator",
      },
    });
    expect(res.ok()).toBeTruthy();
    const text = await res.text();
    expect(text).toContain("event:");
    expect(text).toContain("[stub]");
    expect(text).toContain("event: done");
  });

  test("GET /sessions lists session after chat", async ({ request }) => {
    const sid = `e2e_sess_${Date.now()}`;
    const chat = await request.post("/chat", {
      headers: {
        Accept: "text/event-stream",
        "Content-Type": "application/json",
      },
      data: {
        message: "ping",
        sessionId: sid,
        agentId: "order-management",
      },
    });
    expect(chat.ok()).toBeTruthy();
    await chat.text();

    const list = await request.get("/sessions");
    expect(list.ok()).toBeTruthy();
    const listBody = await list.json();
    const rows = listBody.sessions as { sessionId: string }[];
    expect(Array.isArray(rows)).toBe(true);
    const found = rows.some((r) => r.sessionId === sid);
    expect(found).toBe(true);
  });
});
