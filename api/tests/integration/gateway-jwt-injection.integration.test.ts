/**
 * Integration probe: AgentCore Gateway JWT injection contract.
 *
 * In gateway mode the MCP transport in
 * `api/src/adapters/mongodb-mcp-client.ts` builds the StreamableHTTP
 * transport with a custom `fetch` (`jwtInjectingFetch`) that reads the
 * caller's JWT from the AsyncLocalStorage populated by `withGatewayJwt(...)`
 * and sets it as `Authorization: Bearer <jwt>` on every outbound request.
 *
 * This test stands up a small in-process HTTP server, exercises
 * `jwtInjectingFetch` against it, and asserts:
 *   1. The `Authorization: Bearer <jwt>` header reaches the server when a
 *      JWT is scoped via `withGatewayJwt(...)`.
 *   2. No Authorization header is added when no JWT is in scope (so local
 *      dev / unauthenticated MCP servers still work).
 *   3. Concurrent JWT scopes don't bleed across each other — critical
 *      because the cached McpClient singleton serves many users in one
 *      runtime process.
 *
 * Breaking any of those would silently regress auth to the AgentCore
 * Gateway in production — the most security-sensitive surface of the
 * gateway opt-in path.
 */

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { jwtInjectingFetch } from "../../src/adapters/mongodb-mcp-client.ts";
import { withGatewayJwt } from "../../src/lib/gateway-auth-context.ts";

type Captured = {
  method: string | undefined;
  url: string | undefined;
  authorization: string | undefined;
  contentType: string | undefined;
  body: string;
};

let server: Server;
let baseUrl: string;
const captured: Captured[] = [];

beforeAll(async () => {
  server = createServer((req: IncomingMessage, res: ServerResponse) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
    });
    req.on("end", () => {
      captured.push({
        method: req.method,
        url: req.url,
        authorization: req.headers.authorization,
        contentType: req.headers["content-type"] as string | undefined,
        body,
      });
      res.statusCode = 200;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify({ ok: true }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const addr = server.address();
  if (!addr || typeof addr === "string") throw new Error("server.address() unexpected");
  baseUrl = `http://127.0.0.1:${addr.port}/mcp`;
});

afterAll(async () => {
  await new Promise<void>((r) => server.close(() => r()));
});

describe("gateway JWT injection", () => {
  test("Authorization header reaches the server when scoped via withGatewayJwt", async () => {
    captured.length = 0;
    const jwt = "test.jwt.value";
    const res = await withGatewayJwt(jwt, () =>
      jwtInjectingFetch(baseUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ping: true }),
      }),
    );
    expect(res.status).toBe(200);
    expect(captured).toHaveLength(1);
    expect(captured[0].authorization).toBe(`Bearer ${jwt}`);
    expect(captured[0].method).toBe("POST");
    expect(captured[0].contentType).toBe("application/json");
    expect(captured[0].body).toBe('{"ping":true}');
  });

  test("No Authorization header added when no JWT is in scope", async () => {
    captured.length = 0;
    const res = await jwtInjectingFetch(baseUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(200);
    expect(captured).toHaveLength(1);
    expect(captured[0].authorization).toBeUndefined();
  });

  test("Concurrent scopes do not leak JWTs across each other", async () => {
    captured.length = 0;
    const tasks = ["alice", "bob", "carol"].map((u) =>
      withGatewayJwt(`jwt.${u}`, async () => {
        // Mix a few awaits to interleave with other tasks.
        await new Promise((r) => setTimeout(r, Math.floor(Math.random() * 5)));
        return jwtInjectingFetch(baseUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-user": u },
          body: JSON.stringify({ user: u }),
        });
      }),
    );
    await Promise.all(tasks);

    // Three requests should have arrived, one per user, each with its own JWT.
    expect(captured).toHaveLength(3);
    for (const u of ["alice", "bob", "carol"]) {
      const row = captured.find((r) => r.body.includes(`"user":"${u}"`));
      expect(row).toBeDefined();
      expect(row!.authorization).toBe(`Bearer jwt.${u}`);
    }
  });

  test("Existing Authorization header in init is overwritten by the scoped JWT", async () => {
    captured.length = 0;
    const jwt = "scoped.jwt";
    await withGatewayJwt(jwt, () =>
      jwtInjectingFetch(baseUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          // The SDK's OAuthClientProvider could pre-set this; we own the auth
          // surface in gateway mode and must overwrite.
          Authorization: "Bearer stale.token.from.sdk",
        },
        body: "{}",
      }),
    );
    expect(captured).toHaveLength(1);
    expect(captured[0].authorization).toBe(`Bearer ${jwt}`);
  });
});
