import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const mockState = { failConnect: false, failPing: false };

mock.module("../../src/lib/mongo-client.ts", () => ({
  getMongoDb: async () => {
    if (!process.env.MONGODB_URI?.trim()) return null;
    if (mockState.failConnect) throw new Error("connect failed");
    return {
      admin: () => ({
        command: async () => {
          if (mockState.failPing) throw new Error("ping failed");
          return { ok: 1 };
        },
      }),
      collection: () => ({
        createIndex: async () => ({}),
        findOne: async () => null,
        replaceOne: async () => ({ modifiedCount: 0, upsertedCount: 0 }),
        deleteOne: async () => ({ deletedCount: 0 }),
        find: () => ({
          project: () => ({
            toArray: async () => [],
          }),
        }),
      }),
    };
  },
  resetMongoClientForTests: () => {},
}));

const {
  buildHealthPayload,
  resolveMongoDependencyStatus,
  resolveLongTermMemoryStatus,
} = await import("../../src/lib/health-status.ts");

describe("health-status", () => {
  const saved = { ...process.env };

  beforeEach(() => {
    mockState.failConnect = false;
    mockState.failPing = false;
  });

  afterEach(() => {
    process.env = { ...saved };
  });

  test("mongodb not_configured when no URI", async () => {
    delete process.env.MONGODB_URI;
    expect(await resolveMongoDependencyStatus()).toBe("not_configured");
  });

  test("mongodb connected when URI set and ping succeeds", async () => {
    process.env.MONGODB_URI = "mongodb://localhost:27017";
    expect(await resolveMongoDependencyStatus()).toBe("connected");
  });

  test("mongodb unreachable when ping fails", async () => {
    process.env.MONGODB_URI = "mongodb://localhost:27017";
    mockState.failPing = true;
    expect(await resolveMongoDependencyStatus()).toBe("unreachable");
  });

  test("buildHealthPayload status degraded when mongo unreachable", async () => {
    process.env.MONGODB_URI = "mongodb://localhost:27017";
    process.env.PERSIST_CHAT_SESSIONS = "1";
    mockState.failPing = true;
    const body = await buildHealthPayload();
    expect(body.status).toBe("degraded");
    expect(body.dependencies.mongodb).toBe("unreachable");
    expect(body.dependencies.longTermMemory).toBe("unreachable");
    expect(body.dependencies.chatSessions).toBe("unavailable");
  });

  test("buildHealthPayload includes longTermMemory field when no URI", async () => {
    delete process.env.MONGODB_URI;
    delete process.env.PERSIST_CHAT_SESSIONS;
    const body = await buildHealthPayload();
    expect(body.status).toBe("ok");
    expect(typeof body.dependencies.longTermMemory).toBe("string");
    expect(["not_configured", "no_agents"]).toContain(body.dependencies.longTermMemory);
    expect(body.dependencies.chatSessions).toBe("memory");
    expect(body.dependencies.toolHosting).toBe("direct");
  });

  test("resolveLongTermMemoryStatus not_configured when mongo not_configured", () => {
    expect(resolveLongTermMemoryStatus("not_configured")).toBe("not_configured");
  });

  test("resolveLongTermMemoryStatus unreachable when mongo unreachable", () => {
    expect(resolveLongTermMemoryStatus("unreachable")).toBe("unreachable");
  });

  test("resolveLongTermMemoryStatus connected returns connected or no_agents", () => {
    const result = resolveLongTermMemoryStatus("connected");
    expect(["connected", "no_agents"]).toContain(result);
  });
});
