/**
 * Unit tests for the authenticated-user-context LRU+TTL cache.
 *
 * Without this cache, every chat made up to three sequential AWS roundtrips
 * (Cognito GetUser + customers.findOne + orders.find) before the runtime
 * was even invoked. Cache invariants:
 *   - Same userId+token within TTL → cache hit (no Cognito/Mongo I/O)
 *   - Different bearer token (rotation) → cache miss
 *   - Expired entry → cache miss
 *   - TTL=0 disables the cache entirely
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// Mock the heavy collaborators BEFORE importing the module under test so the
// per-call cost is observable as a counter.
let mongoCallCount = 0;
mock.module("../../src/lib/mongo-client.ts", () => ({
  getMongoDb: async () => {
    mongoCallCount += 1;
    return null; // null short-circuits the customers/orders queries below
  },
}));

const {
  buildAuthenticatedUserContext,
  resetAuthUserContextCacheForTests,
} = await import("../../src/lib/auth-user-context.ts");

const SAVED_ENV = { ...process.env };

const stubJwt = {
  sub: "user-123",
  iss: "https://issuer.invalid/",
  aud: "client-abc",
  email: "alice@example.com",
};

describe("auth-user-context cache", () => {
  beforeEach(() => {
    process.env.AUTH_CONTEXT_CACHE_TTL_MS = "60000";
    resetAuthUserContextCacheForTests();
    mongoCallCount = 0;
  });
  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("first call hits Mongo; second identical call is served from cache", async () => {
    const a = await buildAuthenticatedUserContext("user-123", stubJwt, "tok-A");
    expect(a).toContain("user-123");
    expect(mongoCallCount).toBe(1);

    const b = await buildAuthenticatedUserContext("user-123", stubJwt, "tok-A");
    expect(b).toBe(a);
    expect(mongoCallCount).toBe(1); // no new I/O
  });

  test("rotated bearer token misses the cache (token-fingerprint isolation)", async () => {
    await buildAuthenticatedUserContext("user-123", stubJwt, "tok-A");
    await buildAuthenticatedUserContext("user-123", stubJwt, "tok-B");
    expect(mongoCallCount).toBe(2);
  });

  test("different userId misses the cache", async () => {
    await buildAuthenticatedUserContext("user-A", stubJwt, "tok-X");
    await buildAuthenticatedUserContext("user-B", stubJwt, "tok-X");
    expect(mongoCallCount).toBe(2);
  });

  test("TTL=0 disables the cache (every call hits Mongo)", async () => {
    process.env.AUTH_CONTEXT_CACHE_TTL_MS = "0";
    resetAuthUserContextCacheForTests();
    mongoCallCount = 0;

    await buildAuthenticatedUserContext("user-123", stubJwt, "tok-A");
    await buildAuthenticatedUserContext("user-123", stubJwt, "tok-A");
    expect(mongoCallCount).toBe(2);
  });

  test("missing userId or jwt returns undefined and never queries Mongo", async () => {
    expect(await buildAuthenticatedUserContext(undefined, stubJwt, "tok")).toBeUndefined();
    expect(await buildAuthenticatedUserContext("u", undefined, "tok")).toBeUndefined();
    expect(mongoCallCount).toBe(0);
  });
});
