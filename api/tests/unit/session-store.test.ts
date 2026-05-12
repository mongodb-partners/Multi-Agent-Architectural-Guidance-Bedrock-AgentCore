import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  appendAssistantMessage,
  appendUserMessage,
  clearAllSessionsForTests,
  deleteSession,
  getOrCreateSession,
  getSession,
  listSessions,
} from "../../src/lib/session-store.ts";

beforeEach(() => {
  clearAllSessionsForTests();
  delete process.env.PERSIST_CHAT_SESSIONS;
  delete process.env.MONGODB_URI;
});

afterEach(() => {
  clearAllSessionsForTests();
  delete process.env.PERSIST_CHAT_SESSIONS;
  delete process.env.MONGODB_URI;
});

describe("session-store — basic CRUD", () => {
  test("getOrCreateSession creates a new session", async () => {
    const s = await getOrCreateSession("sess-1");
    expect(s.sessionId).toBe("sess-1");
    expect(s.messages).toHaveLength(0);
    expect(s.userId).toBeUndefined();
  });

  test("getOrCreateSession is idempotent", async () => {
    const a = await getOrCreateSession("sess-idem");
    const b = await getOrCreateSession("sess-idem");
    expect(a).toBe(b);
  });

  test("appendUserMessage creates session and appends", async () => {
    const m = await appendUserMessage("sess-2", "hello");
    expect(m.role).toBe("user");
    expect(m.content).toBe("hello");
    const s = (await getSession("sess-2"))!;
    expect(s.messages).toHaveLength(1);
  });

  test("appendAssistantMessage appends with agentId", async () => {
    await appendUserMessage("sess-3", "q");
    await appendAssistantMessage("sess-3", "a", "order-management");
    const s = (await getSession("sess-3"))!;
    expect(s.messages).toHaveLength(2);
    expect(s.messages[1]!.agentId).toBe("order-management");
  });

  test("deleteSession removes the session", async () => {
    await getOrCreateSession("sess-del");
    const ok = await deleteSession("sess-del");
    expect(ok).toBe(true);
    expect(await getSession("sess-del")).toBeUndefined();
  });

  test("deleteSession returns false for unknown session", async () => {
    expect(await deleteSession("no-such-session")).toBe(false);
  });
});

describe("session-store — userId scoping", () => {
  test("getOrCreateSession attaches userId", async () => {
    const s = await getOrCreateSession("sess-uid", "user-alice");
    expect(s.userId).toBe("user-alice");
  });

  test("userId is set on first creation even if called without it initially", async () => {
    await getOrCreateSession("sess-late");
    const s = await getOrCreateSession("sess-late", "user-bob");
    expect(s.userId).toBe("user-bob");
  });

  test("userId on existing session is not overwritten by subsequent call without userId", async () => {
    await getOrCreateSession("sess-owned", "user-alice");
    await getOrCreateSession("sess-owned"); // no userId
    const s = (await getSession("sess-owned"))!;
    expect(s.userId).toBe("user-alice");
  });

  test("appendUserMessage propagates userId to new session", async () => {
    await appendUserMessage("sess-user-msg", "hi", "user-carol");
    const s = (await getSession("sess-user-msg"))!;
    expect(s.userId).toBe("user-carol");
  });

  test("listSessions without userId filter returns all sessions", async () => {
    await getOrCreateSession("s-a", "user-1");
    await getOrCreateSession("s-b", "user-2");
    await getOrCreateSession("s-c"); // no user
    const all = await listSessions();
    expect(all.length).toBe(3);
  });

  test("listSessions with userId excludes sessions belonging to OTHER users", async () => {
    await getOrCreateSession("s-u1-a", "user-1");
    await getOrCreateSession("s-u1-b", "user-1");
    await getOrCreateSession("s-u2-a", "user-2");
    await getOrCreateSession("s-anon"); // no userId — NOT filtered out (legacy/anonymous)
    const u1 = await listSessions("user-1");
    const ids = u1.map((s) => s.sessionId);
    expect(ids).toContain("s-u1-a");
    expect(ids).toContain("s-u1-b");
    expect(ids).not.toContain("s-u2-a");
    expect(ids).toContain("s-anon");
  });

  test("listSessions with userId does NOT filter sessions with no userId", async () => {
    await getOrCreateSession("s-anon-visible"); // no userId
    await getOrCreateSession("s-u-owned", "user-x");
    const result = await listSessions("user-x");
    const ids = result.map((s) => s.sessionId);
    expect(ids).toContain("s-u-owned");
    expect(ids).toContain("s-anon-visible");
  });

  test("listSessions returns all sessions for a user", async () => {
    await appendUserMessage("sess-alpha", "msg", "user-sort");
    await appendUserMessage("sess-beta", "msg2", "user-sort");
    const sessions = await listSessions("user-sort");
    const ids = sessions.map((s) => s.sessionId);
    expect(ids).toContain("sess-alpha");
    expect(ids).toContain("sess-beta");
  });

  test("listSessions sort: session with later updatedAt appears first", async () => {
    const s1 = await getOrCreateSession("sort-first", "user-ord");
    s1.messages.push({
      id: "m-old",
      role: "user",
      content: "old",
      timestamp: "2024-01-01T00:00:00.000Z",
    });
    const s2 = await getOrCreateSession("sort-second", "user-ord");
    s2.messages.push({
      id: "m-new",
      role: "user",
      content: "new",
      timestamp: "2025-06-01T00:00:00.000Z",
    });

    const result = await listSessions("user-ord");
    const ids = result.map((s) => s.sessionId);
    expect(ids.indexOf("sort-second")).toBeLessThan(ids.indexOf("sort-first"));
  });
});

describe("session-store — deleteSession ownership", () => {
  test("delete without userId removes any session", async () => {
    await getOrCreateSession("to-del", "user-owner");
    expect(await deleteSession("to-del")).toBe(true);
  });

  test("delete with correct userId removes the session", async () => {
    await getOrCreateSession("owned", "user-owner");
    expect(await deleteSession("owned", "user-owner")).toBe(true);
    expect(await getSession("owned")).toBeUndefined();
  });

  test("delete with wrong userId returns false (ownership enforcement)", async () => {
    await getOrCreateSession("owned-2", "user-owner");
    expect(await deleteSession("owned-2", "user-intruder")).toBe(false);
    expect(await getSession("owned-2")).toBeDefined();
  });

  test("delete with userId on session that has no userId succeeds (unscoped session)", async () => {
    await getOrCreateSession("unscoped");
    expect(await deleteSession("unscoped", "user-anyone")).toBe(true);
  });
});
