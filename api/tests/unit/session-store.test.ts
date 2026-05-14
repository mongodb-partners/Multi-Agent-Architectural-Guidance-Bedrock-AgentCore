import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  appendAssistantMessage,
  appendUserMessage,
  clearAllSessionsForTests,
  deleteSession,
  FORBIDDEN_SESSION,
  getOrCreateSession,
  getSession,
  listSessions,
  type SessionRecord,
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

function asRecord(v: SessionRecord | typeof FORBIDDEN_SESSION | undefined): SessionRecord {
  if (!v || v === FORBIDDEN_SESSION) {
    throw new Error("expected SessionRecord, got " + (v === FORBIDDEN_SESSION ? "FORBIDDEN" : "undefined"));
  }
  return v;
}

describe("session-store — basic CRUD", () => {
  test("getOrCreateSession requires userId", async () => {
    // @ts-expect-error — missing userId is a programmer error
    await expect(getOrCreateSession("sess-noid")).rejects.toThrow(/userId is required/);
  });

  test("getOrCreateSession creates a new session bound to userId", async () => {
    const s = asRecord(await getOrCreateSession("sess-1", "user-a"));
    expect(s.sessionId).toBe("sess-1");
    expect(s.messages).toHaveLength(0);
    expect(s.userId).toBe("user-a");
  });

  test("getOrCreateSession is idempotent for the owner", async () => {
    const a = asRecord(await getOrCreateSession("sess-idem", "user-a"));
    const b = asRecord(await getOrCreateSession("sess-idem", "user-a"));
    expect(a).toBe(b);
  });

  test("appendUserMessage creates session and appends", async () => {
    const m = await appendUserMessage("sess-2", "hello", "user-a");
    expect(m).not.toBe(FORBIDDEN_SESSION);
    if (m === FORBIDDEN_SESSION) return;
    expect(m.role).toBe("user");
    expect(m.content).toBe("hello");
    const s = asRecord(await getSession("sess-2", "user-a"));
    expect(s.messages).toHaveLength(1);
  });

  test("appendAssistantMessage appends with agentId", async () => {
    await appendUserMessage("sess-3", "q", "user-a");
    await appendAssistantMessage("sess-3", "a", "order-management", "user-a");
    const s = asRecord(await getSession("sess-3", "user-a"));
    expect(s.messages).toHaveLength(2);
    expect(s.messages[1]!.agentId).toBe("order-management");
  });

  test("deleteSession removes the session for its owner", async () => {
    await getOrCreateSession("sess-del", "user-a");
    const ok = await deleteSession("sess-del", "user-a");
    expect(ok).toBe(true);
    expect(await getSession("sess-del", "user-a")).toBeUndefined();
  });

  test("deleteSession returns false for unknown session", async () => {
    expect(await deleteSession("no-such-session", "user-a")).toBe(false);
  });
});

describe("session-store — userId scoping (P0-2)", () => {
  test("getOrCreateSession on a different user's session returns FORBIDDEN_SESSION", async () => {
    await getOrCreateSession("sess-owned", "user-alice");
    const result = await getOrCreateSession("sess-owned", "user-bob");
    expect(result).toBe(FORBIDDEN_SESSION);
  });

  test("getSession on a different user's session returns FORBIDDEN_SESSION", async () => {
    await getOrCreateSession("sess-x", "user-alice");
    const result = await getSession("sess-x", "user-bob");
    expect(result).toBe(FORBIDDEN_SESSION);
  });

  test("appendUserMessage refuses to write into another user's session", async () => {
    await getOrCreateSession("sess-y", "user-alice");
    const result = await appendUserMessage("sess-y", "intrude", "user-bob");
    expect(result).toBe(FORBIDDEN_SESSION);
    const owner = asRecord(await getSession("sess-y", "user-alice"));
    expect(owner.messages).toHaveLength(0);
  });

  test("appendAssistantMessage refuses to write into another user's session", async () => {
    await getOrCreateSession("sess-z", "user-alice");
    const result = await appendAssistantMessage("sess-z", "leak", "agent", "user-bob");
    expect(result).toBe(FORBIDDEN_SESSION);
    const owner = asRecord(await getSession("sess-z", "user-alice"));
    expect(owner.messages).toHaveLength(0);
  });

  test("listSessions requires userId and only returns the caller's sessions", async () => {
    await getOrCreateSession("s-u1-a", "user-1");
    await getOrCreateSession("s-u1-b", "user-1");
    await getOrCreateSession("s-u2-a", "user-2");

    const u1 = await listSessions("user-1");
    const ids = u1.map((s) => s.sessionId);
    expect(ids).toContain("s-u1-a");
    expect(ids).toContain("s-u1-b");
    expect(ids).not.toContain("s-u2-a");

    // @ts-expect-error — undefined userId must throw to prevent enumeration
    await expect(listSessions(undefined)).rejects.toThrow(/userId is required/);
    await expect(listSessions("")).rejects.toThrow(/userId is required/);
  });

  test("listSessions sort: session with later updatedAt appears first", async () => {
    const s1 = asRecord(await getOrCreateSession("sort-first", "user-ord"));
    s1.messages.push({
      id: "m-old",
      role: "user",
      content: "old",
      timestamp: "2024-01-01T00:00:00.000Z",
    });
    const s2 = asRecord(await getOrCreateSession("sort-second", "user-ord"));
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
  test("delete with the owner userId succeeds", async () => {
    await getOrCreateSession("owned", "user-owner");
    expect(await deleteSession("owned", "user-owner")).toBe(true);
    expect(await getSession("owned", "user-owner")).toBeUndefined();
  });

  test("delete with a different userId returns false and leaves the session intact", async () => {
    await getOrCreateSession("owned-2", "user-owner");
    expect(await deleteSession("owned-2", "user-intruder")).toBe(false);
    const remains = asRecord(await getSession("owned-2", "user-owner"));
    expect(remains.sessionId).toBe("owned-2");
  });
});
