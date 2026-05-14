import type { Collection } from "mongodb";
import { getMongoDb } from "./mongo-client.ts";
import { logger } from "./logger.ts";

/** Mirrors `ChatMessage` in session-store (avoid circular import). */
export type ChatSessionMessage = {
  id: string;
  role: "user" | "assistant";
  content: string;
  timestamp: string;
  agentId?: string;
};

const DEFAULT_COLLECTION = "chat_sessions";

let indexEnsured = false;

export function chatSessionsCollectionName(): string {
  return process.env.CHAT_SESSIONS_COLLECTION?.trim() || DEFAULT_COLLECTION;
}

/**
 * True when short-term chat turns should be mirrored to MongoDB.
 * Requires MONGODB_URI; opt out with PERSIST_CHAT_SESSIONS=0 (or =false).
 */
export function persistChatSessions(env: NodeJS.ProcessEnv = process.env): boolean {
  const v = env.PERSIST_CHAT_SESSIONS?.trim().toLowerCase();
  if (v === "0" || v === "false") return false;
  return Boolean(env.MONGODB_URI?.trim());
}

export function usePersistentChatSessions(): boolean {
  return persistChatSessions();
}

export async function getChatSessionsCollection(): Promise<Collection<ChatSessionDoc> | null> {
  if (!usePersistentChatSessions()) return null;
  try {
    const db = await getMongoDb();
    if (!db) return null;
    const coll = db.collection<ChatSessionDoc>(chatSessionsCollectionName());
    if (!indexEnsured) {
      indexEnsured = true;
      await coll.createIndex({ sessionId: 1 }, { unique: true }).catch((e) => {
        logger.warn("[chat-sessions] createIndex sessionId failed (may already exist)", {
          error: e instanceof Error ? e.message : String(e),
        });
      });
    }
    return coll;
  } catch (e) {
    logger.warn("[chat-sessions] MongoDB unavailable; using in-memory sessions only for this process", {
      error: e instanceof Error ? e.message : String(e),
    });
    return null;
  }
}

export type ChatSessionDoc = {
  sessionId: string;
  userId?: string;
  createdAt: string;
  updatedAt: string;
  messages: ChatSessionMessage[];
};
