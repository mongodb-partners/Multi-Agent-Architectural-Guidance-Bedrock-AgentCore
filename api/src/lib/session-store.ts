import type { Filter } from "mongodb";
import {
  getChatSessionsCollection,
  usePersistentChatSessions,
  type ChatSessionDoc,
} from "./chat-sessions-collection.ts";
import { logger } from "./logger.ts";

export type ChatMessage = {
  id: string;
  role: "user" | "assistant";
  content: string;
  timestamp: string;
  agentId?: string;
  /** Set by the chat route on `chat.turn.end` so the UI can deep-link into the Trace Viewer. */
  traceId?: string;
};

export type SessionRecord = {
  sessionId: string;
  /** JWT `sub` claim when auth is enabled; undefined for unauthenticated sessions. */
  userId?: string;
  createdAt: string;
  messages: ChatMessage[];
};

export type SessionSummary = {
  sessionId: string;
  userId?: string;
  createdAt: string;
  updatedAt: string;
  messageCount: number;
};

const memory = new Map<string, SessionRecord>();

function msgId(): string {
  return `msg_${crypto.randomUUID().slice(0, 12)}`;
}

function docToRecord(doc: ChatSessionDoc): SessionRecord {
  return {
    sessionId: doc.sessionId,
    userId: doc.userId,
    createdAt: doc.createdAt,
    messages: [...doc.messages],
  };
}

function recordToDoc(rec: SessionRecord): ChatSessionDoc {
  const last = rec.messages[rec.messages.length - 1];
  const updatedAt = last?.timestamp ?? rec.createdAt;
  return {
    sessionId: rec.sessionId,
    userId: rec.userId,
    createdAt: rec.createdAt,
    updatedAt,
    messages: [...rec.messages],
  };
}

async function loadFromMongo(sessionId: string): Promise<SessionRecord | undefined> {
  const coll = await getChatSessionsCollection();
  if (!coll) return undefined;
  try {
    const doc = await coll.findOne({ sessionId });
    if (!doc) return undefined;
    const rec = docToRecord(doc);
    memory.set(sessionId, rec);
    return rec;
  } catch (e) {
    logger.warn("[session-store] loadFromMongo failed", {
      sessionId,
      error: e instanceof Error ? e.message : String(e),
    });
    return undefined;
  }
}

async function saveToMongo(rec: SessionRecord): Promise<void> {
  const coll = await getChatSessionsCollection();
  if (!coll) return;
  try {
    const doc = recordToDoc(rec);
    await coll.replaceOne({ sessionId: rec.sessionId }, doc, { upsert: true });
  } catch (e) {
    logger.warn("[session-store] saveToMongo failed", {
      sessionId: rec.sessionId,
      error: e instanceof Error ? e.message : String(e),
    });
  }
}

async function deleteFromMongo(sessionId: string): Promise<void> {
  const coll = await getChatSessionsCollection();
  if (!coll) return;
  try {
    await coll.deleteOne({ sessionId });
  } catch (e) {
    logger.warn("[session-store] deleteFromMongo failed", {
      sessionId,
      error: e instanceof Error ? e.message : String(e),
    });
  }
}

/** Re-export for health / docs. */
export { usePersistentChatSessions };

export async function getOrCreateSession(sessionId: string, userId?: string): Promise<SessionRecord> {
  let s = memory.get(sessionId);
  if (!s && usePersistentChatSessions()) {
    s = await loadFromMongo(sessionId);
  }
  if (!s) {
    const now = new Date().toISOString();
    s = { sessionId, userId, createdAt: now, messages: [] };
    memory.set(sessionId, s);
    if (usePersistentChatSessions()) await saveToMongo(s);
  } else if (userId && !s.userId) {
    s.userId = userId;
    if (usePersistentChatSessions()) await saveToMongo(s);
  }
  return s;
}

export async function getSession(sessionId: string): Promise<SessionRecord | undefined> {
  const cached = memory.get(sessionId);
  if (cached) return cached;
  if (usePersistentChatSessions()) return loadFromMongo(sessionId);
  return undefined;
}

export async function appendUserMessage(
  sessionId: string,
  content: string,
  userId?: string,
): Promise<ChatMessage> {
  const s = await getOrCreateSession(sessionId, userId);
  const m: ChatMessage = {
    id: msgId(),
    role: "user",
    content,
    timestamp: new Date().toISOString(),
  };
  s.messages.push(m);
  memory.set(sessionId, s);
  if (usePersistentChatSessions()) await saveToMongo(s);
  return m;
}

export async function appendAssistantMessage(
  sessionId: string,
  content: string,
  agentId: string,
): Promise<ChatMessage> {
  const s = await getOrCreateSession(sessionId);
  const m: ChatMessage = {
    id: msgId(),
    role: "assistant",
    content,
    timestamp: new Date().toISOString(),
    agentId,
  };
  s.messages.push(m);
  memory.set(sessionId, s);
  if (usePersistentChatSessions()) await saveToMongo(s);
  return m;
}

export async function deleteSession(sessionId: string, userId?: string): Promise<boolean> {
  let cur = memory.get(sessionId);
  if (!cur && usePersistentChatSessions()) {
    cur = await loadFromMongo(sessionId);
  }
  if (!cur) return false;
  if (userId && cur.userId && cur.userId !== userId) return false;
  memory.delete(sessionId);
  if (usePersistentChatSessions()) await deleteFromMongo(sessionId);
  return true;
}

function listFromMemory(userId?: string): SessionSummary[] {
  const out: SessionSummary[] = [];
  for (const s of memory.values()) {
    if (userId && s.userId && s.userId !== userId) continue;
    const last = s.messages[s.messages.length - 1];
    const updatedAt = last?.timestamp ?? s.createdAt;
    out.push({
      sessionId: s.sessionId,
      userId: s.userId,
      createdAt: s.createdAt,
      updatedAt,
      messageCount: s.messages.length,
    });
  }
  out.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0));
  return out;
}

/**
 * All sessions, newest activity first.
 * When userId is provided, only sessions owned by that user are returned (plus sessions with no userId — same rules as in-memory).
 */
export async function listSessions(userId?: string): Promise<SessionSummary[]> {
  if (!usePersistentChatSessions()) {
    return listFromMemory(userId);
  }

  const coll = await getChatSessionsCollection();
  if (!coll) {
    return listFromMemory(userId);
  }

  try {
    const filter: Filter<ChatSessionDoc> =
      userId === undefined ? {} : { $or: [{ userId }, { userId: { $exists: false } }] };

    const docs = await coll
      .find(filter)
      .project({ sessionId: 1, userId: 1, createdAt: 1, updatedAt: 1, messages: 1 })
      .toArray();

    const out: SessionSummary[] = docs.map((d) => {
      const msgs = d.messages ?? [];
      const last = msgs[msgs.length - 1];
      const updatedAt = d.updatedAt ?? last?.timestamp ?? d.createdAt;
      return {
        sessionId: d.sessionId,
        userId: d.userId,
        createdAt: d.createdAt,
        updatedAt,
        messageCount: msgs.length,
      };
    });
    out.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0));
    return out;
  } catch (e) {
    logger.warn("[session-store] listSessions mongo failed; falling back to memory", {
      error: e instanceof Error ? e.message : String(e),
    });
    return listFromMemory(userId);
  }
}

/**
 * Tag the most recent assistant message in `sessionId` with a `traceId`.
 * Writes through to MongoDB when session persistence is enabled.
 */
export async function setLastTraceId(
  sessionId: string,
  messageId: string,
  traceId: string,
): Promise<void> {
  const s = memory.get(sessionId);
  if (!s) return;
  const target =
    s.messages.find((m) => m.id === messageId) ??
    [...s.messages].reverse().find((m) => m.role === "assistant");
  if (!target) return;
  target.traceId = traceId;
  memory.set(sessionId, s);
  if (usePersistentChatSessions()) await saveToMongo(s);
}

/** Clears in-memory cache (tests). Does not delete MongoDB rows. */
export function clearAllSessionsForTests(): void {
  memory.clear();
}
