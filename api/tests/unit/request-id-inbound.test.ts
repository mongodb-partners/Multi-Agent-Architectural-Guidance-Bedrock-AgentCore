import { describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { requestIdMiddleware } from "../../src/middleware/request-id.ts";

function appWithRequestId() {
  const app = new Hono();
  app.use("*", requestIdMiddleware);
  app.get("/echo", (c) => c.json({ requestId: c.get("requestId") }));
  return app;
}

describe("requestIdMiddleware — inbound preference", () => {
  test("accepts valid inbound X-Request-Id (alphanumeric + _ -)", async () => {
    const app = appWithRequestId();
    const res = await app.request("http://test/echo", {
      headers: { "X-Request-Id": "req_client_abc-123" },
    });
    expect(res.headers.get("X-Request-Id")).toBe("req_client_abc-123");
    const j = (await res.json()) as { requestId: string };
    expect(j.requestId).toBe("req_client_abc-123");
  });

  test("accepts lowercase header name too", async () => {
    const app = appWithRequestId();
    const res = await app.request("http://test/echo", {
      headers: { "x-request-id": "ABC_123-xyz" },
    });
    expect(res.headers.get("X-Request-Id")).toBe("ABC_123-xyz");
  });

  test("rejects invalid inbound and mints fresh req_*", async () => {
    const app = appWithRequestId();
    const res = await app.request("http://test/echo", {
      headers: { "X-Request-Id": "bad value with spaces" },
    });
    const got = res.headers.get("X-Request-Id") ?? "";
    expect(got).toMatch(/^req_[0-9a-f-]{12}$/);
  });

  test("rejects oversized inbound id (> 64 chars)", async () => {
    const app = appWithRequestId();
    const oversized = "a".repeat(65);
    const res = await app.request("http://test/echo", {
      headers: { "X-Request-Id": oversized },
    });
    const got = res.headers.get("X-Request-Id") ?? "";
    expect(got).not.toBe(oversized);
    expect(got).toMatch(/^req_[0-9a-f-]{12}$/);
  });

  test("mints a fresh id when no inbound header is present", async () => {
    const app = appWithRequestId();
    const res = await app.request("http://test/echo");
    const got = res.headers.get("X-Request-Id") ?? "";
    expect(got).toMatch(/^req_[0-9a-f-]{12}$/);
  });
});
