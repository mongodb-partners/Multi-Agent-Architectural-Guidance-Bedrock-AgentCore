import type { Filter } from "mongodb";
import {
  getChatSessionsCollection,
  usePersistentChatSessions,
  type ChatSessionDoc,
} from "./chat-sessions-collection.ts";
import {
  deleteMessagesBySession,
  persistChatMessage,
  type ChatMessageDoc,
} from "./chat-messages-collection.ts";
import { embedDocumentText } from "./embed-query.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";
import { persistTrace } from "./trace-store.ts";
import { recordChatMirrorEmbeddingSkipped } from "./cw-metrics.ts";

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

/**
 * Mirror a chat message into the vector-searchable `chat_messages` collection.
 *
 * Strict-mode embedding failures (the declared `EMBEDDINGS_PROVIDER` was
 * unable to produce a vector) are non-fatal: the row is still persisted so
 * the transcript and Sessions UI stay complete, but with `embedding` /
 * `embeddingModel` absent and an `embeddingError` marker set instead. We
 * surface the failure on three channels:
 *
 *   1. JSON log line (operators / CloudWatch).
 *   2. Trace event `chat.mirror.embedding_failed` on the live collector
 *      (Trace Viewer per-turn timeline). `currentTrace()` returns the
 *      active collector via AsyncLocalStorage even from the
 *      `queueMicrotask` callback that schedules this function.
 *   3. EMF metric `Multiagent/Chat ChatMirrorEmbeddingSkipped` with the
 *      `EmbedErrorCode` as a low-cardinality dimension.
 *
 * After the row is persisted, if a trace event was emitted we re-persist
 * the trace doc (idempotent upsert; same pattern long-term-memory uses)
 * so the Trace Viewer's stored copy includes the new event. Runs as a
 * microtask — never on the user's TTFB clock — so the extra upsert is free.
 */
async function mirrorMessageToMongo(
  rec: SessionRecord,
  message: ChatMessage,
): Promise<void> {
  if (!usePersistentChatSessions()) return;
  const ts = new Date(message.timestamp);
  const doc: ChatMessageDoc = {
    messageId: message.id,
    sessionId: rec.sessionId,
    userId: rec.userId,
    agentId: message.agentId,
    role: message.role,
    content: message.content,
    timestamp: message.timestamp,
    ts,
  };
  let failureCode: string | undefined;
  try {
    const emb = await embedDocumentText(message.content);
    if (emb.ok) {
      doc.embedding = emb.vector;
      doc.embeddingModel = emb.modelId;
    } else {
      failureCode = emb.code;
      doc.embeddingError = {
        code: emb.code,
        message: emb.message,
        ts: new Date(),
      };
      logger.warn("[session-store] chat message embedding failed; storing without vector", {
        sessionId: rec.sessionId,
        messageId: message.id,
        code: emb.code,
        message: emb.message,
      });
      currentTrace()?.event("chat.mirror.embedding_failed", {
        messageId: message.id,
        sessionId: rec.sessionId,
        agentId: message.agentId,
        role: message.role,
        code: emb.code,
        message: emb.message,
      });
      try {
        recordChatMirrorEmbeddingSkipped({
          agentId: message.agentId,
          code: emb.code,
        });
      } catch {
        // metric emission must never destabilize the mirror
      }
    }
  } catch (e) {
    failureCode = "embed_threw";
    const errMessage = e instanceof Error ? e.message : String(e);
    doc.embeddingError = {
      code: "embed_threw",
      message: errMessage,
      ts: new Date(),
    };
    logger.warn("[session-store] chat message embedding threw; storing without vector", {
      sessionId: rec.sessionId,
      messageId: message.id,
      error: errMessage,
    });
    currentTrace()?.event("chat.mirror.embedding_failed", {
      messageId: message.id,
      sessionId: rec.sessionId,
      agentId: message.agentId,
      role: message.role,
      code: "embed_threw",
      message: errMessage,
    });
    try {
      recordChatMirrorEmbeddingSkipped({
        agentId: message.agentId,
        code: "embed_threw",
      });
    } catch {
      /* see above */
    }
  }
  await persistChatMessage(doc);

  // Re-persist the trace so the stored doc includes the new event. The route
  // already persisted the trace before sending `done`; this microtask outlives
  // that, so without re-persisting the event would only live in memory until
  // the collector is GC'd. `persistTrace` is upsert-idempotent (same contract
  // as the long-term-memory re-persist in routes/chat.ts).
  if (failureCode) {
    const collector = currentTrace();
    if (collector) {
      try {
        await persistTrace(collector.toJSON());
      } catch (e) {
        logger.warn("[session-store] post-mirror trace re-persist failed", {
          traceId: collector.traceId,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }
  }
}

/** Schedule the chat_messages mirror as a microtask so it never sits on the
 *  user's TTFB clock. Failures are logged inside `mirrorMessageToMongo`. */
function scheduleMirror(rec: SessionRecord, message: ChatMessage): void {
  if (!usePersistentChatSessions()) return;
  queueMicrotask(() => {
    void mirrorMessageToMongo(rec, message);
  });
}

/** Re-export for health / docs. */
export { usePersistentChatSessions };

/**
 * Sentinel returned by ownership-checked accessors when the session exists but belongs to a
 * different `userId`. Callers translate this to the same 404 the route returns when the
 * session does not exist at all, so we never confirm or deny existence to the wrong user.
 */
export const FORBIDDEN_SESSION = Symbol("FORBIDDEN_SESSION");
export type ForbiddenSession = typeof FORBIDDEN_SESSION;

/**
 * Strict ownership check: the session must be explicitly bound to `userId`.
 * Sessions with no `userId` are denied — they must be migrated before use.
 * This enforces the security requirement that jwt.sub is the sole tenant key and
 * one user can never access another user's session data.
 */
function owns(record: SessionRecord, userId: string): boolean {
  return !!record.userId && record.userId === userId;
}

/**
 * Return the existing session for `sessionId` if `userId` owns it; create a
 * new session bound to `userId` otherwise.
 *
 * Returns `FORBIDDEN_SESSION` when the session exists but is owned by a
 * different user (or has no owner at all — legacy unscoped rows are denied,
 * not claimed). The caller must NOT distinguish that case from "not found"
 * externally so we never confirm or deny existence to the wrong user.
 */
export async function getOrCreateSession(
  sessionId: string,
  userId: string,
): Promise<SessionRecord | ForbiddenSession> {
  if (!userId) throw new Error("getOrCreateSession: userId is required");
  let s = memory.get(sessionId);
  if (!s && usePersistentChatSessions()) {
    s = await loadFromMongo(sessionId);
  }
  if (!s) {
    const now = new Date().toISOString();
    s = { sessionId, userId, createdAt: now, messages: [] };
    memory.set(sessionId, s);
    if (usePersistentChatSessions()) await saveToMongo(s);
    return s;
  }
  if (!owns(s, userId)) return FORBIDDEN_SESSION;
  return s;
}

/**
 * Look up an existing session for `userId`. Returns `undefined` when the session does
 * not exist and `FORBIDDEN_SESSION` when it belongs to a different user or has no owner.
 */
export async function getSession(
  sessionId: string,
  userId: string,
): Promise<SessionRecord | undefined | ForbiddenSession> {
  if (!userId) throw new Error("getSession: userId is required");
  let cached = memory.get(sessionId);
  if (!cached && usePersistentChatSessions()) {
    cached = await loadFromMongo(sessionId);
  }
  if (!cached) return undefined;
  if (!owns(cached, userId)) return FORBIDDEN_SESSION;
  return cached;
}

export async function appendUserMessage(
  sessionId: string,
  content: string,
  userId: string,
): Promise<ChatMessage | ForbiddenSession> {
  const s = await getOrCreateSession(sessionId, userId);
  if (s === FORBIDDEN_SESSION) return FORBIDDEN_SESSION;
  const m: ChatMessage = {
    id: msgId(),
    role: "user",
    content,
    timestamp: new Date().toISOString(),
  };
  s.messages.push(m);
  memory.set(sessionId, s);
  if (usePersistentChatSessions()) await saveToMongo(s);
  scheduleMirror(s, m);
  return m;
}

export async function appendAssistantMessage(
  sessionId: string,
  content: string,
  agentId: string,
  userId: string,
): Promise<ChatMessage | ForbiddenSession> {
  const s = await getOrCreateSession(sessionId, userId);
  if (s === FORBIDDEN_SESSION) return FORBIDDEN_SESSION;
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
  scheduleMirror(s, m);
  return m;
}

export async function deleteSession(sessionId: string, userId: string): Promise<boolean> {
  if (!userId) throw new Error("deleteSession: userId is required");
  let cur = memory.get(sessionId);
  if (!cur && usePersistentChatSessions()) {
    cur = await loadFromMongo(sessionId);
  }
  if (!cur) return false;
  if (!owns(cur, userId)) return false;
  memory.delete(sessionId);
  if (usePersistentChatSessions()) {
    await deleteFromMongo(sessionId);
    // Cascade-delete vector-searchable mirrors so the user's "delete chat" UX
    // also wipes the long-term retrieval surface. Best-effort, logged inside.
    await deleteMessagesBySession(sessionId, userId);
  }
  return true;
}

function listFromMemory(userId: string): SessionSummary[] {
  const out: SessionSummary[] = [];
  for (const s of memory.values()) {
    if (s.userId !== userId) continue;
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
 * Sessions owned by `userId`, newest activity first.
 *
 * `userId` is required: callers always come through `GET /sessions`, which sits behind the
 * mandatory JWT auth middleware, so `c.get("jwtPayload").sub` is always populated. Sessions
 * with a missing or different `userId` are excluded — they are never returned to anyone but
 * their owner, so a deployment with multiple Cognito users (or a leaked token) can never
 * enumerate someone else's chats.
 */
export async function listSessions(userId: string): Promise<SessionSummary[]> {
  if (!userId) {
    throw new Error("listSessions: userId is required (authenticated callers only)");
  }
  if (!usePersistentChatSessions()) {
    return listFromMemory(userId);
  }

  const coll = await getChatSessionsCollection();
  if (!coll) {
    return listFromMemory(userId);
  }

  try {
    const filter: Filter<ChatSessionDoc> = { userId };
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
