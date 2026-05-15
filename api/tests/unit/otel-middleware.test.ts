import { beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { initOtel } from "../../src/lib/otel.ts";
import { requestIdMiddleware } from "../../src/middleware/request-id.ts";
import { otelServerSpanMiddleware } from "../../src/middleware/otel.ts";

beforeAll(() => {
  initOtel({ serviceName: "mongodb-multiagent-api-test" });
});

function testApp() {
  const app = new Hono();
  app.use("*", requestIdMiddleware);
  app.use("*", otelServerSpanMiddleware);
  app.post("/chat", (c) => c.json({ ok: true }));
  app.get("/health", (c) => c.json({ status: "ok" }));
  return app;
}

describe("otelServerSpanMiddleware", () => {
  test("sets X-Trace-Id and echoes valid inbound X-Request-Id on POST /chat", async () => {
    const app = testApp();
    const res = await app.request("http://test/chat", {
      method: "POST",
      headers: {
        "X-Request-Id": "client-req-1",
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("X-Request-Id")).toBe("client-req-1");
    const xt = res.headers.get("X-Trace-Id");
    expect(xt).toBeTruthy();
    expect(xt).toMatch(/^[0-9a-f]{32}$/i);
  });

  test("skips span (no X-Trace-Id) for GET /health", async () => {
    const app = testApp();
    const res = await app.request("http://test/health", { method: "GET" });
    expect(res.status).toBe(200);
    expect(res.headers.get("X-Trace-Id")).toBeNull();
  });
});
