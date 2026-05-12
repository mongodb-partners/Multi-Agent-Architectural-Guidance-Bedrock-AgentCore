/**
 * Trace persistence + retrieval.
 *
 * Two-tier storage:
 *  1. **MongoDB `traces` collection** (when `MONGODB_URI` is set and tracing
 *     persistence is enabled). Documents have a TTL index on `createdAt` via
 *     `TRACE_TTL_DAYS` (default 30).
 *  2. **In-memory ring buffer** keyed by `sessionId:messageId` and `traceId`,
 *     bounded by `TRACE_RING_BUFFER_SIZE` (default 100). Used as a fallback
 *     when Mongo isn't configured and as a read-through cache.
 *
 * Reads (`getTrace*`) check the ring buffer first (cheap), then fall back to
 * Mongo when configured. Writes go to both.
 */

import type { Trace } from "./trace-types.ts";
import { getMongoDb } from "./mongo-client.ts";
import { logger } from "./logger.ts";
import { persistChatSessions } from "./runtime-defaults.ts";

// ---------------------------------------------------------------------------
// Env knobs
// ---------------------------------------------------------------------------

function envInt(name: string, fallback: number): number {
  const v = process.env[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function ttlSeconds(): number {
  return envInt("TRACE_TTL_DAYS", 30) * 86_400;
}

function ringBufferSize(): number {
  return envInt("TRACE_RING_BUFFER_SIZE", 100);
}

function collectionName(): string {
  return process.env.TRACES_COLLECTION?.trim() || "traces";
}

// ---------------------------------------------------------------------------
// Ring buffer (in-process)
// ---------------------------------------------------------------------------

const byTraceId = new Map<string, Trace>();
const byMessageKey = new Map<string, string>(); // "sessionId:messageId" -> traceId
const insertOrder: string[] = []; // traceIds, oldest first

function rememberInRing(trace: Trace): void {
  const cap = ringBufferSize();
  byTraceId.set(trace.traceId, trace);
  byMessageKey.set(`${trace.sessionId}:${trace.messageId}`, trace.traceId);
  insertOrder.push(trace.traceId);
  while (insertOrder.length > cap) {
    const evict = insertOrder.shift();
    if (!evict) break;
    const t = byTraceId.get(evict);
    byTraceId.delete(evict);
    if (t) byMessageKey.delete(`${t.sessionId}:${t.messageId}`);
  }
}

// ---------------------------------------------------------------------------
// Mongo persistence (best-effort, write-through)
// ---------------------------------------------------------------------------

let indexEnsured = false;

async function getCollection(): Promise<ReturnType<NonNullable<Awaited<ReturnType<typeof getMongoDb>>>["collection"]> | null> {
  if (!persistChatSessions()) return null; // tracing persistence follows the same gate
  try {
    const db = await getMongoDb();
    if (!db) return null;
    const coll = db.collection(collectionName());
    if (!indexEnsured) {
      indexEnsured = true;
      try {
        await coll.createIndex({ traceId: 1 }, { unique: true });
        await coll.createIndex({ sessionId: 1, messageId: 1 });
        // TTL — failed re-create with different ttl is silently swallowed (must match existing).
        await coll.createIndex({ createdAt: 1 }, { expireAfterSeconds: ttlSeconds() });
      } catch (e) {
        logger.warn("[trace-store] createIndex failed (may already exist)", {
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }
    return coll;
  } catch (e) {
    logger.warn("[trace-store] mongo unavailable; using ring buffer only", {
      error: e instanceof Error ? e.message : String(e),
    });
    return null;
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Write the trace to the ring buffer (always) and to MongoDB (when configured).
 * Returns the persisted document.
 */
export async function persistTrace(trace: Trace): Promise<Trace> {
  rememberInRing(trace);
  const coll = await getCollection();
  if (coll) {
    try {
      // Use replaceOne (upsert) so duplicate writes for the same trace id are idempotent.
      const doc = { ...trace, createdAt: new Date(trace.createdAt) };
      await coll.replaceOne({ traceId: trace.traceId }, doc as never, { upsert: true });
    } catch (e) {
      logger.warn("[trace-store] mongo write failed", {
        traceId: trace.traceId,
        error: e instanceof Error ? e.message : String(e),
      });
    }
  }
  return trace;
}

/** Fetch a trace by id. Ring buffer first, then Mongo. */
export async function getTraceById(traceId: string): Promise<Trace | undefined> {
  const cached = byTraceId.get(traceId);
  if (cached) return cached;
  const coll = await getCollection();
  if (!coll) return undefined;
  try {
    const doc = await coll.findOne({ traceId } as never);
    if (!doc) return undefined;
    const trace = normalizeDoc(doc as never);
    rememberInRing(trace);
    return trace;
  } catch (e) {
    logger.warn("[trace-store] mongo lookup failed", {
      traceId,
      error: e instanceof Error ? e.message : String(e),
    });
    return undefined;
  }
}

/** Fetch the latest trace for a given (sessionId, messageId). */
export async function getTraceForMessage(
  sessionId: string,
  messageId: string,
): Promise<Trace | undefined> {
  const cachedId = byMessageKey.get(`${sessionId}:${messageId}`);
  if (cachedId) {
    const t = byTraceId.get(cachedId);
    if (t) return t;
  }
  const coll = await getCollection();
  if (!coll) return undefined;
  try {
    const doc = await coll.findOne({ sessionId, messageId } as never);
    if (!doc) return undefined;
    const trace = normalizeDoc(doc as never);
    rememberInRing(trace);
    return trace;
  } catch (e) {
    logger.warn("[trace-store] mongo lookup failed", {
      sessionId,
      messageId,
      error: e instanceof Error ? e.message : String(e),
    });
    return undefined;
  }
}

function normalizeDoc(doc: { createdAt?: unknown } & Partial<Trace>): Trace {
  const created = doc.createdAt;
  let createdIso: string;
  if (created && typeof created === "object" && typeof (created as Date).toISOString === "function") {
    createdIso = (created as Date).toISOString();
  } else if (typeof created === "string") {
    createdIso = created;
  } else {
    createdIso = new Date().toISOString();
  }
  return {
    traceId: doc.traceId ?? "",
    sessionId: doc.sessionId ?? "",
    messageId: doc.messageId ?? "",
    userId: doc.userId,
    agentId: doc.agentId ?? "orchestrator",
    events: doc.events ?? [],
    summary: doc.summary as Trace["summary"],
    createdAt: createdIso,
    truncated: doc.truncated,
    eventsDropped: doc.eventsDropped,
  };
}

/** For tests / fixtures. */
export function _clearTraceStoreForTests(): void {
  byTraceId.clear();
  byMessageKey.clear();
  insertOrder.length = 0;
}

/** For the live-metrics sidebar — best-effort, may be undefined if Mongo is offline. */
export async function listRecentTraces(limit = 50): Promise<Trace[]> {
  // Ring buffer always available.
  const ring = insertOrder
    .slice(-limit)
    .map((id) => byTraceId.get(id))
    .filter((t): t is Trace => Boolean(t))
    .reverse();
  if (ring.length >= limit) return ring;
  const coll = await getCollection();
  if (!coll) return ring;
  try {
    const docs = await coll
      .find({} as never)
      .sort({ createdAt: -1 })
      .limit(limit)
      .toArray();
    return docs.map((d) => normalizeDoc(d as never));
  } catch {
    return ring;
  }
}
