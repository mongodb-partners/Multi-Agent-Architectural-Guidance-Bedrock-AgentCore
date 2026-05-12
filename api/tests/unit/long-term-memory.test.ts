import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// In-process store that mimics MongoDB for test isolation.
const memStore: Record<string, Record<string, unknown>[]> = {};

mock.module("../../src/lib/mongo-client.ts", () => ({
  getMongoDb: async () => ({
    databaseName: "test_db",
    collection: (name: string) => ({
      createIndex: async () => ({}),
      insertOne: async (doc: Record<string, unknown>) => {
        memStore[name] ??= [];
        memStore[name].push(doc);
        return { insertedId: "mock-id" };
      },
      insertMany: async (docs: Record<string, unknown>[]) => {
        memStore[name] ??= [];
        memStore[name].push(...docs);
        return { insertedCount: docs.length };
      },
      countDocuments: async (q: Record<string, unknown>) => {
        const all = memStore[name] ?? [];
        return all.filter((d) => Object.entries(q).every(([k, v]) => d[k] === v)).length;
      },
      find: (q: Record<string, unknown>) => ({
        sort: () => ({
          limit: (n: number) => ({
            toArray: async () => {
              const all = memStore[name] ?? [];
              const filtered = all.filter((d) => Object.entries(q).every(([k, v]) => d[k] === v));
              return filtered.slice(-n);
            },
          }),
        }),
      }),
    }),
  }),
  resetMongoClientForTests: () => {},
}));

const { readLongTermMemory, writeLongTermMemory } = await import("../../src/lib/long-term-memory.ts");

describe("long-term-memory (fact-based)", () => {
  const saved = { ...process.env };

  beforeEach(() => {
    Object.keys(memStore).forEach((k) => delete memStore[k]);
    process.env.MONGODB_URI = "mongodb://localhost:27017";
  });

  afterEach(() => {
    process.env = { ...saved };
  });

  test("readLongTermMemory returns null when no facts exist", async () => {
    expect(await readLongTermMemory("user-1", "order-management")).toBeNull();
  });

  test("readLongTermMemory returns null when userId is empty string", async () => {
    expect(await readLongTermMemory("", "order-management")).toBeNull();
  });

  test("writeLongTermMemory does nothing when userId is empty", async () => {
    await writeLongTermMemory("", "order-management", "i prefer email", "noted");
    expect(await readLongTermMemory("", "order-management")).toBeNull();
  });

  test("writeLongTermMemory does nothing when assistantReply is blank", async () => {
    await writeLongTermMemory("user-1", "order-management", "i prefer email", "");
    expect(await readLongTermMemory("user-1", "order-management")).toBeNull();
  });

  test("writes a matching fact and reads it back as bullet list", async () => {
    await writeLongTermMemory(
      "user-1",
      "order-management",
      "my email is alice@example.com",
      "Thanks, Alice.",
    );
    const ctx = await readLongTermMemory("user-1", "order-management");
    expect(ctx).not.toBeNull();
    expect(ctx).toContain("my email is alice@example.com");
    expect(ctx?.startsWith("- ")).toBe(true);
  });

  test("memory is user-scoped — user-2 cannot see user-1 facts", async () => {
    await writeLongTermMemory("user-1", "order-management", "i prefer email contact", "Noted.");
    expect(await readLongTermMemory("user-2", "order-management")).toBeNull();
  });

  test("memory is agent-scoped — different agentId sees no facts", async () => {
    await writeLongTermMemory("user-1", "order-management", "i prefer email contact", "Noted.");
    expect(await readLongTermMemory("user-1", "product-recommendation")).toBeNull();
  });

  test("non-matching user messages are not persisted", async () => {
    await writeLongTermMemory("user-1", "agent-a", "Hello there friend", "Hi.");
    expect(await readLongTermMemory("user-1", "agent-a")).toBeNull();
  });

  test("multiple writes append facts and reads return all bullets", async () => {
    await writeLongTermMemory("user-1", "agent-a", "my email is a@b.com", "Reply 1");
    await writeLongTermMemory("user-1", "agent-a", "i prefer dark mode", "Reply 2");
    const ctx = await readLongTermMemory("user-1", "agent-a");
    expect(ctx).toContain("my email is a@b.com");
    expect(ctx).toContain("i prefer dark mode");
  });

  test("over-long lines are not persisted (fact length cap)", async () => {
    const longLine = "i prefer " + "x".repeat(500);
    await writeLongTermMemory("user-t", "agent-t", longLine, "Hello back.");
    expect(await readLongTermMemory("user-t", "agent-t")).toBeNull();
  });
});
