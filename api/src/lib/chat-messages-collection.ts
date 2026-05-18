/**
 * Vector-searchable mirror of individual chat messages.
 *
 * Why a separate collection (not embedded inside `chat_sessions.messages[]`):
 *   - Atlas `$vectorSearch` operates on top-level documents; nested arrays
 *     require `$lookup` + explicit `mapping` and are noticeably slower.
 *   - Per-message TTL, fanout indexes, and per-user/per-session retention
 *     are simpler to manage on a flat collection.
 *   - The session document stays cheap to fetch on every short-term replay.
 *
 * Schema:
 *   {
 *     messageId:       string  (matches ChatMessage.id; unique)
 *     sessionId:       string
 *     userId?:         string  (JWT sub; absent for legacy/unauthed)
 *     agentId?:        string  (assistant role only)
 *     role:            "user" | "assistant"
 *     content:         string
 *     timestamp:       ISO string
 *     embedding?:      number[] (1024-d Voyage / Bedrock Titan v2; absent
 *                                when no embedding provider is configured)
 *     embeddingModel?: string  ("voyage" | "bedrock:<modelId>" | ...)
 *     ts:              Date    (mirror of `timestamp` for recency decay /
 *                                Atlas filter scope)
 *   }
 *
 * Persistence is gated by the same flag as `chat_sessions`
 * (`PERSIST_CHAT_SESSIONS` + `MONGODB_URI`). Writes are best-effort and never
 * fail the chat turn — `persistChatMessage` logs and returns `false` on any
 * downstream error.
 */

import type { Collection } from "mongodb";
import { getMongoDb } from "./mongo-client.ts";
import { logger } from "./logger.ts";
import { usePersistentChatSessions } from "./chat-sessions-collection.ts";

const DEFAULT_COLLECTION = "chat_messages";

let indexEnsured = false;

export function chatMessagesCollectionName(): string {
  return process.env.CHAT_MESSAGES_COLLECTION?.trim() || DEFAULT_COLLECTION;
}

/** Mirrors `ChatMessage` from session-store plus embedding metadata. */
export type ChatMessageDoc = {
  messageId: string;
  sessionId: string;
  userId?: string;
  agentId?: string;
  role: "user" | "assistant";
  content: string;
  timestamp: string;
  ts: Date;
  embedding?: number[];
  embeddingModel?: string;
};

export async function getChatMessagesCollection(): Promise<Collection<ChatMessageDoc> | null> {
  if (!usePersistentChatSessions()) return null;
  try {
    const db = await getMongoDb();
    if (!db) return null;
    const coll = db.collection<ChatMessageDoc>(chatMessagesCollectionName());
    if (!indexEnsured) {
      indexEnsured = true;
      // Lookup index for short-term recall + cascade delete.
      await coll
        .createIndex({ sessionId: 1, timestamp: 1 })
        .catch((e) =>
          logger.warn("[chat-messages] createIndex(sessionId,timestamp) failed", {
            error: e instanceof Error ? e.message : String(e),
          }),
        );
      // Stable per-message unique key so retries dedupe naturally.
      await coll
        .createIndex({ messageId: 1 }, { unique: true })
        .catch((e) =>
          logger.warn("[chat-messages] createIndex(messageId) failed", {
            error: e instanceof Error ? e.message : String(e),
          }),
        );
      // Fanout: per-user listing + hybrid filter scope.
      await coll
        .createIndex({ userId: 1, ts: -1 })
        .catch((e) =>
          logger.warn("[chat-messages] createIndex(userId,ts) failed", {
            error: e instanceof Error ? e.message : String(e),
          }),
        );
    }
    return coll;
  } catch (e) {
    logger.warn("[chat-messages] MongoDB unavailable", {
      error: e instanceof Error ? e.message : String(e),
    });
    return null;
  }
}

/**
 * Persist a single chat message (with optional embedding) to the
 * `chat_messages` collection. Best-effort: returns `false` on any failure
 * after logging, so callers can keep streaming the chat turn.
 */
export async function persistChatMessage(doc: ChatMessageDoc): Promise<boolean> {
  const coll = await getChatMessagesCollection();
  if (!coll) return false;
  try {
    await coll.replaceOne({ messageId: doc.messageId }, doc, { upsert: true });
    return true;
  } catch (e) {
    logger.warn("[chat-messages] persistChatMessage failed", {
      messageId: doc.messageId,
      sessionId: doc.sessionId,
      error: e instanceof Error ? e.message : String(e),
    });
    return false;
  }
}

/**
 * Cascade-delete every `chat_messages` row tied to a given session. Called
 * from `deleteSession` so the user's privacy contract (delete the chat,
 * delete its memory mirror) holds. Best-effort.
 */
export async function deleteMessagesBySession(
  sessionId: string,
  userId?: string,
): Promise<number> {
  const coll = await getChatMessagesCollection();
  if (!coll) return 0;
  try {
    const filter = userId
      ? { sessionId, $or: [{ userId }, { userId: { $exists: false } }] }
      : { sessionId };
    const res = await coll.deleteMany(filter);
    return res.deletedCount ?? 0;
  } catch (e) {
    logger.warn("[chat-messages] deleteMessagesBySession failed", {
      sessionId,
      error: e instanceof Error ? e.message : String(e),
    });
    return 0;
  }
}
