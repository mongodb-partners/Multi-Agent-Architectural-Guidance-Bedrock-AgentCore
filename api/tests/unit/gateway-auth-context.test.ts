import { describe, expect, test } from "bun:test";
import {
  currentGatewayJwt,
  withGatewayJwt,
} from "../../src/lib/gateway-auth-context.ts";

describe("gateway-auth-context", () => {
  test("currentGatewayJwt returns the scoped JWT inside withGatewayJwt", () => {
    const jwt = "eyJ.fake.token";
    const seen = withGatewayJwt(jwt, () => currentGatewayJwt());
    expect(seen).toBe(jwt);
  });

  test("currentGatewayJwt returns undefined outside any withGatewayJwt", () => {
    expect(currentGatewayJwt()).toBeUndefined();
  });

  test("withGatewayJwt(undefined, fn) does not establish a scope", () => {
    const seen = withGatewayJwt(undefined, () => currentGatewayJwt());
    expect(seen).toBeUndefined();
  });

  test("nested withGatewayJwt scopes the inner JWT, restores outer on exit", () => {
    const outer = "outer.jwt";
    const inner = "inner.jwt";
    const trace: Array<string | undefined> = [];
    withGatewayJwt(outer, () => {
      trace.push(currentGatewayJwt());
      withGatewayJwt(inner, () => {
        trace.push(currentGatewayJwt());
      });
      trace.push(currentGatewayJwt());
    });
    expect(trace).toEqual([outer, inner, outer]);
    expect(currentGatewayJwt()).toBeUndefined();
  });

  test("scope crosses awaits and setImmediate boundaries", async () => {
    const jwt = "async.jwt";
    let beforeAwait: string | undefined;
    let afterAwait: string | undefined;
    let afterImmediate: string | undefined;

    await withGatewayJwt(jwt, async () => {
      beforeAwait = currentGatewayJwt();
      await new Promise((r) => setTimeout(r, 1));
      afterAwait = currentGatewayJwt();
      await new Promise<void>((r) => setImmediate(r));
      afterImmediate = currentGatewayJwt();
    });

    expect(beforeAwait).toBe(jwt);
    expect(afterAwait).toBe(jwt);
    expect(afterImmediate).toBe(jwt);
    expect(currentGatewayJwt()).toBeUndefined();
  });

  test("concurrent withGatewayJwt scopes do not leak across each other", async () => {
    const captured: Array<{ id: number; jwt: string | undefined }> = [];
    const tasks = ["a", "b", "c"].map((tag, id) =>
      withGatewayJwt(`jwt.${tag}`, async () => {
        await new Promise((r) => setTimeout(r, Math.random() * 5));
        captured.push({ id, jwt: currentGatewayJwt() });
      }),
    );
    await Promise.all(tasks);
    expect(captured.find((c) => c.id === 0)?.jwt).toBe("jwt.a");
    expect(captured.find((c) => c.id === 1)?.jwt).toBe("jwt.b");
    expect(captured.find((c) => c.id === 2)?.jwt).toBe("jwt.c");
  });
});
