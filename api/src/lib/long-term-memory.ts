/**
 * Long-term memory: per-user, per-agent fact store.
 *
 * Backends and priority:
 *
 *   Primary: MongoDB facts store (`agent_memory_facts`) with TTL.
 *   Fallback: AgentCore Memory Store if MongoDB read/write is unavailable.
 *
 * Public API: `writeLongTermMemory` / `readLongTermMemory` /
 * `readSharedLongTermMemory`. Agents opt in via `memory.longTerm: true`
 * in their `.agent.md` frontmatter.
 *
 * Fact extraction always runs the LLM extractor (Bedrock Haiku via
 * `extractFactsWithLlm`). When that call fails the write is skipped and a
 * `memory.long_term_skip` event is emitted with `reason: "llm_extractor_failed"`
 * — we deliberately do NOT fall back to a regex heuristic, because regex
 * false-positives would silently store wrong "facts" on every Bedrock blip.
 */

import { createHash } from "node:crypto";
import {
  BedrockAgentCoreClient,
  CreateEventCommand,
  ListEventsCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import type { AnyBulkWriteOperation } from "mongodb";
import { getMongoDb } from "../lib/mongo-client.ts";
import { embedDocumentText, embedQueryText } from "./embed-query.ts";
import {
  hybridRetrieve,
  type HybridCollectionSpec,
  type MergedHit,
} from "./vector-retrieval.ts";
import { chatMessagesCollectionName } from "./chat-messages-collection.ts";
import {
  extractFactsWithLlm,
  type FactCandidate,
} from "./llm-fact-extractor.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";
import { recordMemoryWrite } from "./cw-metrics.ts";

export type { FactCandidate } from "./llm-fact-extractor.ts";

export type MemoryTurn = {
  userId: string;
  agentId: string;
  userMessage: string;
  assistantReply: string;
  ts: string;
};

/** Read at call-time so tests can override MEMORY_INJECT_TURNS at runtime. */
function maxInjectTurns(): number {
  return Math.max(1, Number(process.env.MEMORY_INJECT_TURNS ?? 5));
}

// ---------------------------------------------------------------------------
// Backend selection
// ---------------------------------------------------------------------------

function agentcoreMemoryStoreId(): string | undefined {
  return process.env.AGENTCORE_MEMORY_STORE_ID?.trim() || undefined;
}

function hasAgentcoreMemoryStore(): boolean {
  return !!agentcoreMemoryStoreId();
}

// ---------------------------------------------------------------------------
// AgentCore Memory backend
// ---------------------------------------------------------------------------

let _agentcoreClient: BedrockAgentCoreClient | null = null;

function getAgentCoreClient(): BedrockAgentCoreClient {
  if (!_agentcoreClient) {
    _agentcoreClient = new BedrockAgentCoreClient({
      region: process.env.AWS_REGION ?? "us-east-1",
    });
  }
  return _agentcoreClient;
}

/** Stable session ID: one session per user-agent pair. */
function sessionId(userId: string, agentId: string): string {
  return `${userId}::${agentId}`;
}

async function agentcoreWrite(turn: MemoryTurn): Promise<void> {
  const memoryId = agentcoreMemoryStoreId()!;
  const client = getAgentCoreClient();
  const ts = new Date(turn.ts);

  await client.send(
    new CreateEventCommand({
      memoryId,
      actorId: turn.userId,
      sessionId: sessionId(turn.userId, turn.agentId),
      eventTimestamp: ts,
      payload: [
        {
          conversational: {
            role: "USER",
            content: { text: turn.userMessage.slice(0, 2000) },
          },
        },
        {
          conversational: {
            role: "ASSISTANT",
            content: { text: turn.assistantReply.slice(0, 4000) },
          },
        },
      ],
      metadata: {
        agentId: { stringValue: turn.agentId },
      },
    }),
  );
}

async function agentcoreRead(userId: string, agentId: string, limit: number): Promise<MemoryTurn[]> {
  const memoryId = agentcoreMemoryStoreId()!;
  const client = getAgentCoreClient();
  const sid = sessionId(userId, agentId);

  const out = await client.send(
    new ListEventsCommand({
      memoryId,
      actorId: userId,
      sessionId: sid,
      includePayloads: true,
      maxResults: limit * 2, // each turn = 2 events (USER + ASSISTANT)
    }),
  );

  const events = out.events ?? [];

  const turns: MemoryTurn[] = [];
  for (let i = 0; i < events.length - 1; i++) {
    const ev = events[i];
    const evNext = events[i + 1];
    const userPayload = ev.payload?.find((p) => p.conversational?.role === "USER");
    const assistPayload = evNext.payload?.find((p) => p.conversational?.role === "ASSISTANT");
    if (userPayload && assistPayload) {
      turns.push({
        userId,
        agentId,
        userMessage: userPayload.conversational?.content?.text ?? "",
        assistantReply: assistPayload.conversational?.content?.text ?? "",
        ts: ev.eventTimestamp?.toISOString() ?? new Date().toISOString(),
      });
      i++; // skip the ASSISTANT event we just consumed
    }
  }

  return turns.slice(-limit);
}

// ---------------------------------------------------------------------------
// MongoDB backend
// ---------------------------------------------------------------------------

const FACTS_COLLECTION = "agent_memory_facts";
let ttlIndexEnsured = false;

type MemoryFact = {
  userId: string;
  agentId: string;
  fact: string;
  source: "user" | "assistant";
  ts: Date;
  /** Stable content fingerprint used as the dedup key for `bulkWrite` upsert. */
  factHash: string;
  /** Voyage / Bedrock embedding for vector retrieval. Absent when no provider configured. */
  embedding?: number[];
  /** Provider id used to compute `embedding` (`"voyage"` | `"bedrock:<modelId>"`). */
  embeddingModel?: string;
};

export function computeFactHash(userId: string, agentId: string, fact: string): string {
  const normalized = fact.normalize("NFKC").trim().toLowerCase().replace(/\s+/g, " ");
  return createHash("sha256")
    .update(`${userId}|${agentId}|${normalized}`)
    .digest("hex");
}

async function ensureTtlIndex(db: Awaited<ReturnType<typeof getMongoDb>>): Promise<void> {
  if (ttlIndexEnsured || !db) return;
  ttlIndexEnsured = true;
  const ttlDays = Number(process.env.MEMORY_TTL_DAYS ?? 90);
  const expireAfterSeconds = Math.max(1, Math.round(ttlDays * 86400));
  try {
    await db.collection(FACTS_COLLECTION).createIndex(
      { ts: 1 },
      { expireAfterSeconds, background: true },
    );
    logger.info("[memory] TTL index ensured on agent_memory_facts", { expireAfterSeconds });
  } catch (err) {
    logger.warn("[memory] could not create TTL index on agent_memory_facts (may already exist)", {
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

/** Reset TTL index creation guard (for test isolation). */
export function resetTtlIndexGuardForTests(): void {
  ttlIndexEnsured = false;
}

// ---------------------------------------------------------------------------
// Fact extraction (LLM only)
// ---------------------------------------------------------------------------

export type ExtractFactCandidatesResult = {
  accepted: string[];
  considered: FactCandidate[];
  extractorModelId?: string;
  extractorLatencyMs: number;
  extractorInputTokens?: number;
  extractorOutputTokens?: number;
  /** Set when the Bedrock call failed; the caller treats this as a hard skip
   *  (no regex fallback — see file header comment for rationale). */
  extractorError?: string;
};

/**
 * Run the LLM extractor and return its candidates. On Bedrock failure we
 * return an empty result with `extractorError` set; the caller (`mongoWriteFacts`)
 * treats that as a skip. Extractor never throws.
 */
export async function extractFactCandidates(
  userMessage: string,
): Promise<ExtractFactCandidatesResult> {
  const t0 = Date.now();
  try {
    const llm = await extractFactsWithLlm(userMessage);
    return {
      accepted: llm.accepted,
      considered: llm.considered,
      extractorModelId: llm.modelId,
      extractorLatencyMs: llm.latencyMs,
      extractorInputTokens: llm.inputTokens,
      extractorOutputTokens: llm.outputTokens,
    };
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    logger.warn(
      "[memory] LLM fact extractor failed; skipping long-term write",
      { error: errMsg },
    );
    return {
      accepted: [],
      considered: [],
      extractorLatencyMs: Date.now() - t0,
      extractorError: errMsg,
    };
  }
}

function memoryTraceValuesEnabled(): boolean {
  const v = process.env.MEMORY_TRACE_VALUES?.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

type MongoWriteFactsResult = {
  outcome: "persisted" | "skipped" | "failed";
  reason?: "mongodb_unavailable" | "no_fact_candidates" | "llm_extractor_failed";
  accepted: string[];
  considered: FactCandidate[];
  inserted: number;
  /** Number of facts that already existed (matched on `factHash`); deduped at upsert time. */
  duplicates: number;
  /** Number of facts embedded successfully (the rest were stored without `embedding`). */
  embeddedCount: number;
  /** Embedding model id (Voyage or `bedrock:<modelId>`). */
  embeddingModel?: string;
  priorEntryCount: number | null;
  newEntryCount: number | null;
  ttlExpiresAt: string;
  errorClass?: string;
  errorMessage?: string;
  extractorModelId?: string;
  extractorLatencyMs: number;
  extractorInputTokens?: number;
  extractorOutputTokens?: number;
  extractorError?: string;
};

async function mongoWriteFacts(turn: MemoryTurn): Promise<MongoWriteFactsResult> {
  const ttlDays = Number(process.env.MEMORY_TTL_DAYS ?? 90);
  const ttlExpiresAt = new Date(Date.now() + ttlDays * 86_400_000).toISOString();
  const ext = await extractFactCandidates(turn.userMessage);
  const { accepted, considered } = ext;
  const extractorMeta = {
    extractorModelId: ext.extractorModelId,
    extractorLatencyMs: ext.extractorLatencyMs,
    extractorInputTokens: ext.extractorInputTokens,
    extractorOutputTokens: ext.extractorOutputTokens,
    extractorError: ext.extractorError,
  };

  if (ext.extractorError) {
    return {
      outcome: "skipped",
      reason: "llm_extractor_failed",
      accepted: [],
      considered: [],
      inserted: 0,
      duplicates: 0,
      embeddedCount: 0,
      priorEntryCount: null,
      newEntryCount: null,
      ttlExpiresAt,
      ...extractorMeta,
    };
  }

  const db = await getMongoDb();
  if (!db) {
    logger.warn("[memory] MONGODB_URI not set; skipping mongo long-term memory write");
    return {
      outcome: "skipped",
      reason: "mongodb_unavailable",
      accepted,
      considered,
      inserted: 0,
      duplicates: 0,
      embeddedCount: 0,
      priorEntryCount: null,
      newEntryCount: null,
      ttlExpiresAt,
      ...extractorMeta,
    };
  }
  await ensureTtlIndex(db);
  if (accepted.length === 0) {
    return {
      outcome: "skipped",
      reason: "no_fact_candidates",
      accepted,
      considered,
      inserted: 0,
      duplicates: 0,
      embeddedCount: 0,
      priorEntryCount: null,
      newEntryCount: null,
      ttlExpiresAt,
      ...extractorMeta,
    };
  }

  // Embed each accepted fact in parallel using the document-mode embedder.
  // Failures don't block persistence — the row is stored without `embedding`.
  // Vector retrieval won't surface it until an embedding is present; lexical
  // search still will, and the trace payload exposes the degraded write.
  const embedSettled = await Promise.all(
    accepted.map(async (fact) => {
      const r = await embedDocumentText(fact);
      if (!r.ok) {
        logger.warn("[memory] fact embedding failed; storing fact without vector", {
          userId: turn.userId,
          agentId: turn.agentId,
          code: r.code,
          message: r.message,
        });
        return null;
      }
      return r;
    }),
  );
  const embeddingModel = embedSettled.find((r) => r && r.ok)?.modelId;
  const embeddedCount = embedSettled.filter((r) => r !== null).length;

  const ops: AnyBulkWriteOperation<MemoryFact>[] = accepted.map((fact, i) => {
    const factHash = computeFactHash(turn.userId, turn.agentId, fact);
    const emb = embedSettled[i];
    const doc: MemoryFact = {
      userId: turn.userId,
      agentId: turn.agentId,
      fact,
      source: "user",
      ts: new Date(turn.ts),
      factHash,
      ...(emb && emb.ok
        ? { embedding: emb.vector, embeddingModel: emb.modelId }
        : {}),
    };
    return {
      updateOne: {
        filter: { userId: turn.userId, factHash },
        update: { $setOnInsert: doc },
        upsert: true,
      },
    };
  });

  let priorEntryCount: number | null = null;
  let newEntryCount: number | null = null;
  try {
    priorEntryCount = await db
      .collection(FACTS_COLLECTION)
      .countDocuments({ userId: turn.userId, agentId: turn.agentId });
  } catch {
    /* best-effort */
  }

  let inserted = 0;
  let duplicates = 0;
  try {
    const res = await db
      .collection<MemoryFact>(FACTS_COLLECTION)
      .bulkWrite(ops, { ordered: false });
    inserted = res.upsertedCount ?? 0;
    duplicates = accepted.length - inserted;
  } catch (err) {
    return {
      outcome: "failed",
      accepted,
      considered,
      inserted: 0,
      duplicates: 0,
      embeddedCount,
      embeddingModel,
      priorEntryCount,
      newEntryCount,
      ttlExpiresAt,
      errorClass: err instanceof Error ? err.constructor.name : "Error",
      errorMessage: err instanceof Error ? err.message : String(err),
      ...extractorMeta,
    };
  }
  try {
    newEntryCount = await db
      .collection(FACTS_COLLECTION)
      .countDocuments({ userId: turn.userId, agentId: turn.agentId });
  } catch {
    /* best-effort */
  }
  return {
    outcome: "persisted",
    accepted,
    considered,
    inserted,
    duplicates,
    embeddedCount,
    embeddingModel,
    priorEntryCount,
    newEntryCount,
    ttlExpiresAt,
    ...extractorMeta,
  };
}

async function mongoReadFacts(userId: string, agentId: string, limit: number): Promise<string[]> {
  const db = await getMongoDb();
  if (!db) return [];
  const docs = await db
    .collection(FACTS_COLLECTION)
    .find({ userId, agentId })
    .sort({ ts: -1 })
    .limit(limit)
    .toArray();
  return docs.reverse().map((d) => String(d.fact ?? "")).filter(Boolean);
}

async function mongoReadSharedFacts(userId: string, limit: number): Promise<string[]> {
  const db = await getMongoDb();
  if (!db) return [];
  const docs = await db
    .collection(FACTS_COLLECTION)
    .find({ userId })
    .sort({ ts: -1 })
    .limit(limit * 2)
    .toArray();
  const out: string[] = [];
  const seen = new Set<string>();
  for (const d of docs) {
    const fact = String(d.fact ?? "").trim();
    if (!fact) continue;
    const key = fact.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(fact);
    if (out.length >= limit) break;
  }
  return out.reverse();
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Persist a completed conversation turn to long-term memory.
 * Called after the assistant reply is fully assembled.
 */
export async function writeLongTermMemory(
  userId: string,
  agentId: string,
  userMessage: string,
  assistantReply: string,
): Promise<void> {
  const trace = currentTrace();
  if (!userId) {
    trace?.event("memory.long_term_skip", {
      reason: "no_user_id",
      agentId,
      userMessageExcerpt: userMessage.slice(0, 200),
    });
    return;
  }
  if (!assistantReply.trim()) {
    trace?.event("memory.long_term_skip", {
      reason: "empty_assistant_reply",
      userId,
      agentId,
      userMessageExcerpt: userMessage.slice(0, 200),
    });
    return;
  }
  const ts = new Date().toISOString();
  const userMessageBytes = Buffer.byteLength(userMessage, "utf8");
  const assistantReplyBytes = Buffer.byteLength(assistantReply, "utf8");
  const turn: MemoryTurn = {
    userId,
    agentId,
    userMessage: userMessage.slice(0, 2000),
    assistantReply: assistantReply.slice(0, 4000),
    ts,
  };
  const includeValues = memoryTraceValuesEnabled();
  const t0 = Date.now();

  let result: Awaited<ReturnType<typeof mongoWriteFacts>>;
  try {
    result = await mongoWriteFacts(turn);
  } catch (err) {
    result = {
      outcome: "failed",
      accepted: [],
      considered: [],
      inserted: 0,
      duplicates: 0,
      embeddedCount: 0,
      priorEntryCount: null,
      newEntryCount: null,
      ttlExpiresAt: "",
      errorClass: err instanceof Error ? err.constructor.name : "Error",
      errorMessage: err instanceof Error ? err.message : String(err),
      extractorLatencyMs: 0,
    };
  }

  if (result.outcome === "skipped") {
    const reason = result.reason ?? "no_fact_candidates";
    trace?.event("memory.long_term_skip", {
      reason,
      userId,
      agentId,
      userMessageExcerpt: userMessage.slice(0, 200),
      ...(reason === "llm_extractor_failed"
        ? {
            extractorModelId: result.extractorModelId,
            extractorLatencyMs: result.extractorLatencyMs,
            extractorError: result.extractorError,
          }
        : {}),
    });
    return;
  }

  let fallbackOutcome: "persisted" | "failed" | undefined;
  let fallbackErrorClass: string | undefined;
  let fallbackErrorMessage: string | undefined;
  if (result.outcome === "failed" && hasAgentcoreMemoryStore()) {
    try {
      await agentcoreWrite(turn);
      fallbackOutcome = "persisted";
      logger.debug("[memory] fallback write to AgentCore Memory Store succeeded", { userId, agentId });
    } catch (fallbackErr) {
      fallbackOutcome = "failed";
      fallbackErrorClass = fallbackErr instanceof Error ? fallbackErr.constructor.name : "Error";
      fallbackErrorMessage = fallbackErr instanceof Error ? fallbackErr.message : String(fallbackErr);
      logger.warn("[memory] fallback write to AgentCore failed", {
        userId,
        agentId,
        error: fallbackErrorMessage,
      });
    }
  }

  if (result.outcome === "failed") {
    logger.audit().warn("[memory] failed to write long-term memory", {
      userId,
      agentId,
      backend: "mongodb",
      error: result.errorMessage,
    });
  } else {
    // Audit-channel: every long-term memory write is a compliance-relevant
    // mutation (per-user PII facts) — surface count + bytes (no content).
    logger.audit().info("[memory] long-term memory facts persisted", {
      userId,
      agentId,
      backend: "mongodb",
      factCount: result.inserted,
      assistantBytes: assistantReplyBytes,
      userBytes: userMessageBytes,
    });
  }

  trace?.event("memory.long_term_write", {
    userId,
    agentId,
    ts,
    factCandidates: result.considered.map((c) => ({
      text: includeValues ? c.text : "<redacted>",
      matched: c.matched,
      matchedPatterns: c.matchedPatterns,
      rejectedReason: c.rejectedReason,
      length: c.length,
      category: c.category,
      note: c.note,
    })),
    factsExtracted: includeValues ? result.accepted : result.accepted.map(() => "<redacted>"),
    collection: "agent_memory_facts",
    op: result.outcome === "persisted" ? "bulkWrite" : "skip",
    docsInserted: result.inserted,
    duplicatesSkipped: result.duplicates,
    embeddedCount: result.embeddedCount,
    embeddingModel: result.embeddingModel,
    primaryBackend: "mongodb",
    primaryOutcome: result.outcome,
    primaryErrorClass: result.errorClass,
    primaryErrorMessage: result.errorMessage,
    fallbackBackend: fallbackOutcome ? "agentcore_memory_store" : undefined,
    fallbackOutcome,
    fallbackErrorClass,
    fallbackErrorMessage,
    userMessageBytes,
    userMessageBytesStored: Buffer.byteLength(turn.userMessage, "utf8"),
    assistantReplyBytes,
    assistantReplyBytesStored: Buffer.byteLength(turn.assistantReply, "utf8"),
    priorEntryCount: result.priorEntryCount,
    newEntryCount: result.newEntryCount,
    ttlExpiresAt: result.ttlExpiresAt,
    latencyMs: Date.now() - t0,
    extractorModelId: result.extractorModelId,
    extractorLatencyMs: result.extractorLatencyMs,
    extractorInputTokens: result.extractorInputTokens,
    extractorOutputTokens: result.extractorOutputTokens,
  });

  try {
    recordMemoryWrite({
      agentId,
      factsExtracted: Array.isArray(result.considered) ? result.considered.length : 0,
      factsWritten: result.inserted ?? 0,
      embeddingFailures:
        typeof result.embeddedCount === "number" && Array.isArray(result.accepted)
          ? Math.max(0, result.accepted.length - result.embeddedCount)
          : 0,
    });
  } catch {
    // metric emission must never destabilize the memory write
  }
}

/**
 * Retrieve recent memory turns for a user+agent pair.
 * Returns a formatted string for injection into the system prompt,
 * or null if there is nothing to inject.
 */
export async function readLongTermMemory(
  userId: string,
  agentId: string,
): Promise<string | null> {
  if (!userId) return null;
  const limit = maxInjectTurns();
  const trace = currentTrace();
  const includeValues = memoryTraceValuesEnabled();
  const t0 = Date.now();
  let primaryFailed = false;

  try {
    const facts = await mongoReadFacts(userId, agentId, limit);
    if (facts.length > 0) {
      const formatted = facts.map((f) => `- ${f}`).join("\n");
      trace?.event("memory.scoped_read", {
        scope: "scoped",
        userId,
        agentId,
        facts: includeValues ? facts : facts.map(() => "<redacted>"),
        entryCount: facts.length,
        bytesInjected: Buffer.byteLength(formatted, "utf8"),
        collectionsQueried: [FACTS_COLLECTION],
        injectionPoint: "system_prompt",
        latencyMs: Date.now() - t0,
        backend: "mongodb",
      });
      return formatted;
    }
  } catch (err) {
    primaryFailed = true;
    logger.warn("[memory] mongodb long-term read failed", {
      userId,
      agentId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
  if (hasAgentcoreMemoryStore()) {
    try {
      const turns = await agentcoreRead(userId, agentId, limit);
      if (turns.length === 0) {
        trace?.event("memory.scoped_read", {
          scope: "scoped",
          userId,
          agentId,
          facts: [],
          entryCount: 0,
          bytesInjected: 0,
          collectionsQueried: [FACTS_COLLECTION, "agentcore_memory_store"],
          injectionPoint: "system_prompt",
          latencyMs: Date.now() - t0,
          backend: "agentcore_memory_store",
          primaryFailed,
        });
        return null;
      }
      const lines = turns.map((t) => {
        const date = t.ts ? t.ts.slice(0, 10) : "unknown";
        return `[${date}] User: ${t.userMessage.slice(0, 300)}\nAssistant: ${t.assistantReply.slice(0, 600)}`;
      });
      const formatted = lines.join("\n\n---\n\n");
      trace?.event("memory.scoped_read", {
        scope: "scoped",
        userId,
        agentId,
        facts: includeValues ? lines : lines.map(() => "<redacted>"),
        entryCount: lines.length,
        bytesInjected: Buffer.byteLength(formatted, "utf8"),
        collectionsQueried: [FACTS_COLLECTION, "agentcore_memory_store"],
        injectionPoint: "system_prompt",
        latencyMs: Date.now() - t0,
        backend: "agentcore_memory_store",
        primaryFailed,
      });
      return formatted;
    } catch (err) {
      logger.warn("[memory] fallback AgentCore long-term read failed", {
        userId,
        agentId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }
  trace?.event("memory.scoped_read", {
    scope: "scoped",
    userId,
    agentId,
    facts: [],
    entryCount: 0,
    bytesInjected: 0,
    collectionsQueried: [FACTS_COLLECTION],
    injectionPoint: "system_prompt",
    latencyMs: Date.now() - t0,
    backend: "mongodb",
    primaryFailed,
  });
  return null;
}

// ---------------------------------------------------------------------------
// Hybrid retrieval (vector + lexical) — direct Mongo path for low latency
// ---------------------------------------------------------------------------

/** Indices created in db-seeding/seed-indexes.ts. Kept here so retrieval and
 *  the seeder stay in lockstep. */
const MEMORY_VECTOR_INDEX = "agent_memory_facts-vector-index";
const MEMORY_LEXICAL_INDEX = "agent_memory_facts-text-index";
const CHAT_MESSAGES_VECTOR_INDEX = "chat_messages-vector-index";
const CHAT_MESSAGES_LEXICAL_INDEX = "chat_messages-text-index";

function memoryTopK(): number {
  return Math.max(1, Number(process.env.MEMORY_VECTOR_TOPK ?? 6));
}

function memoryFetchK(): number {
  return Math.max(memoryTopK(), Number(process.env.MEMORY_VECTOR_FETCHK ?? 24));
}

function memoryNumCandidates(): number {
  return Math.max(50, Number(process.env.MEMORY_VECTOR_NUM_CANDIDATES ?? 200));
}

function memoryRecencyHalfLifeDays(): number {
  const raw = Number(process.env.MEMORY_RECENCY_HALFLIFE_DAYS ?? 30);
  return Number.isFinite(raw) ? raw : 30;
}

function memoryMmrLambda(): number {
  const raw = Number(process.env.MEMORY_MMR_LAMBDA ?? 0.7);
  if (!Number.isFinite(raw)) return 0.7;
  return Math.max(0, Math.min(1, raw));
}

function memoryMinScore(): number {
  const raw = Number(process.env.MEMORY_MIN_SCORE ?? 0);
  return Number.isFinite(raw) ? Math.max(0, raw) : 0;
}

function memoryWeightFacts(): number {
  const raw = Number(process.env.MEMORY_WEIGHT_FACTS ?? 1.5);
  return Number.isFinite(raw) ? raw : 1.5;
}

function memoryWeightChatMessages(): number {
  const raw = Number(process.env.MEMORY_WEIGHT_CHAT_MESSAGES ?? 1);
  return Number.isFinite(raw) ? raw : 1;
}

/**
 * Whether to include assistant-role messages from `chat_messages` during
 * long-term memory retrieval. Defaults to `true` so the agent can recall
 * what it previously said (e.g. "why did you list blake@example.com?").
 *
 * Set `MEMORY_INCLUDE_ASSISTANT_MESSAGES=0` to revert to the conservative
 * user-only behaviour if assistant replies cause retrieval noise.
 *
 * Exported so unit tests can call the real function without duplicating logic.
 */
export function memoryIncludeAssistantMessages(): boolean {
  const v = process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES?.trim().toLowerCase();
  if (v === "0" || v === "false") return false;
  return true;
}

function memorySearchMaxTimeMs(): number {
  const raw = Number(process.env.MEMORY_SEARCH_MAX_TIME_MS ?? 8000);
  return Number.isFinite(raw) && raw > 0 ? raw : 8000;
}

function memoryEmbedTimeoutMs(): number {
  const raw = Number(process.env.MEMORY_EMBED_TIMEOUT_MS ?? 5000);
  return Number.isFinite(raw) && raw > 0 ? raw : 5000;
}

const FALLBACK_STOPWORDS = new Set([
  "about",
  "after",
  "before",
  "could",
  "did",
  "does",
  "have",
  "tell",
  "that",
  "this",
  "what",
  "when",
  "where",
  "with",
  "you",
  "your",
]);

function fallbackKeywordRegex(queryText: string): RegExp | undefined {
  const parts = queryText
    .toLowerCase()
    .normalize("NFKC")
    .match(/[a-z0-9]{4,}/g)
    ?.map((w) => (w.length > 6 ? w.slice(0, 6) : w))
    .filter((w) => !FALLBACK_STOPWORDS.has(w));
  const unique = Array.from(new Set(parts ?? [])).slice(0, 8);
  if (unique.length === 0) return undefined;
  return new RegExp(unique.map((w) => escapeRegExp(w)).join("|"), "i");
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function fallbackReadFactsByKeyword(
  db: NonNullable<Awaited<ReturnType<typeof getMongoDb>>>,
  userId: string,
  agentId: string | undefined,
  queryText: string,
  limit: number,
): Promise<string[]> {
  const regex = fallbackKeywordRegex(queryText);
  const filter: Record<string, unknown> = { userId };
  if (agentId) filter.agentId = agentId;
  if (regex) filter.fact = regex;

  let docs = await db
    .collection<MemoryFact>(FACTS_COLLECTION)
    .find(filter)
    .sort({ ts: -1 })
    .limit(limit)
    .toArray();

  // If there are no keyword hits (or no useful keyword), fall back to a small
  // recent-facts window rather than injecting nothing after a vector/search
  // failure. This preserves recall during Atlas index build/outage windows.
  if (docs.length === 0 && regex) {
    const recentFilter: Record<string, unknown> = { userId };
    if (agentId) recentFilter.agentId = agentId;
    docs = await db
      .collection<MemoryFact>(FACTS_COLLECTION)
      .find(recentFilter)
      .sort({ ts: -1 })
      .limit(limit)
      .toArray();
  }

  return docs.map((d) => String(d.fact ?? "").trim()).filter(Boolean);
}

/**
 * Build the formatted "Relevant prior context" block that chat.ts injects
 * into the system prompt. Runs hybrid retrieval across `agent_memory_facts`
 * (curated user facts) and `chat_messages` (raw conversation history).
 *
 * Returns `null` when:
 *   - no `userId` is provided,
 *   - MongoDB is not configured (no `MONGODB_URI`),
 *   - the query embedding fails AND lexical search returns nothing,
 *   - retrieval succeeds but yields zero hits.
 *
 * Emits exactly one trace event: `memory.scoped_read` (kept for UI compat)
 * with the new hybrid retrieval payload fields populated. The agent-scoped
 * filter is applied when an `agentId` is passed so per-agent facts are
 * preferred without losing access to cross-agent user-level facts.
 */
export async function readLongTermMemoryContext(
  userId: string,
  queryText: string,
  opts: { agentId?: string; sessionId?: string; priorTurns?: Array<{ role: string; content?: string }> } = {},
): Promise<string | null> {
  if (!userId) return null;
  const trimmedQuery = (queryText ?? "").trim();
  if (!trimmedQuery) return null;

  const trace = currentTrace();
  const includeValues = memoryTraceValuesEnabled();
  const t0 = Date.now();
  const topK = memoryTopK();
  const fetchK = memoryFetchK();
  const collectionsQueried = [FACTS_COLLECTION, chatMessagesCollectionName()];

  const db = await getMongoDb();
  if (!db) {
    trace?.event("memory.scoped_read", {
      scope: "scoped",
      userId,
      agentId: opts.agentId,
      facts: [],
      entryCount: 0,
      bytesInjected: 0,
      collectionsQueried,
      injectionPoint: "system_prompt",
      latencyMs: Date.now() - t0,
      backend: "mongodb",
      primaryFailed: true,
      mode: "hybrid",
      retrieval: {
        topK,
        fetchK,
        vectorHits: 0,
        lexicalHits: 0,
        rrfMergedCount: 0,
        perCollection: [],
      },
    });
    return null;
  }

  // Embed the query in query-mode. If it fails or stalls, fall back to
  // lexical-only so LTM recall never blocks the chat turn on SageMaker/Bedrock.
  const embedTimeoutMs = memoryEmbedTimeoutMs();
  const embedAbort = new AbortController();
  const embedTimer = setTimeout(() => embedAbort.abort(), embedTimeoutMs);
  const embed = await embedQueryText(trimmedQuery, embedAbort.signal)
    .catch((err) => ({
      ok: false as const,
      code: "bedrock_failed" as const,
      message: err instanceof Error ? err.message : String(err),
    }))
    .finally(() => clearTimeout(embedTimer));
  const mode: "hybrid" | "lexical" = embed.ok ? "hybrid" : "lexical";
  const queryVector = embed.ok ? embed.vector : [];
  if (!embed.ok) {
    logger.warn("[memory] query embedding failed; falling back to lexical-only retrieval", {
      userId,
      code: embed.code,
      message: embed.message,
    });
  }

  const collections: HybridCollectionSpec[] = [
    {
      collection: FACTS_COLLECTION,
      vectorIndex: MEMORY_VECTOR_INDEX,
      vectorPath: "embedding",
      lexicalIndex: MEMORY_LEXICAL_INDEX,
      lexicalPath: "fact",
      filter: { userId },
      weight: memoryWeightFacts(),
    },
    {
      collection: chatMessagesCollectionName(),
      vectorIndex: CHAT_MESSAGES_VECTOR_INDEX,
      vectorPath: "embedding",
      lexicalIndex: CHAT_MESSAGES_LEXICAL_INDEX,
      lexicalPath: "content",
      // Include both user and assistant messages by default so the agent can
      // recall what it previously said (e.g. "why did you return X?").
      // Opt out with MEMORY_INCLUDE_ASSISTANT_MESSAGES=0 if assistant replies
      // cause retrieval noise in your dataset.
      filter: memoryIncludeAssistantMessages()
        ? { userId }
        : { userId, role: "user" },
      weight: memoryWeightChatMessages(),
    },
  ];

  let retrievalErr: { class: string; message: string } | undefined;
  let items: MergedHit[] = [];
  let meta: { mode: "hybrid" | "vector" | "lexical"; vectorHits: number; lexicalHits: number; rrfMergedCount: number; perCollection: Array<{ collection: string; vectorReturned: number; lexicalReturned: number; error?: string }> } = {
    mode,
    vectorHits: 0,
    lexicalHits: 0,
    rrfMergedCount: 0,
    perCollection: [],
  };
  try {
    const res = await hybridRetrieve(db, {
      queryText: trimmedQuery,
      queryVector,
      collections,
      fetchK,
      topK,
      numCandidates: memoryNumCandidates(),
      minScore: memoryMinScore(),
      mmrLambda: memoryMmrLambda(),
      recencyHalfLifeDays: memoryRecencyHalfLifeDays(),
      recencyTsField: "ts",
      mode,
      maxTimeMS: memorySearchMaxTimeMs(),
    });
    items = opts.sessionId
      ? res.items.filter(
          (hit) =>
            hit.collection !== chatMessagesCollectionName() ||
            String(hit.doc?.sessionId ?? "") !== opts.sessionId,
        )
      : res.items;
    meta = res.meta;
  } catch (err) {
    retrievalErr = {
      class: err instanceof Error ? err.constructor.name : "Error",
      message: err instanceof Error ? err.message : String(err),
    };
    logger.warn("[memory] hybrid retrieval failed", {
      userId,
      error: retrievalErr.message,
    });
  }

  let fallbackLines: string[] = [];
  if (items.length === 0) {
    try {
      fallbackLines = (await fallbackReadFactsByKeyword(
        db,
        userId,
        opts.agentId,
        trimmedQuery,
        topK,
      )).map((fact) => `- ${fact}`);
      if (fallbackLines.length > 0) {
        logger.warn("[memory] hybrid retrieval returned no promptable facts; used scoped keyword fallback", {
          userId,
          agentId: opts.agentId,
          count: fallbackLines.length,
        });
      }
    } catch (err) {
      logger.warn("[memory] fallback memory read failed", {
        userId,
        agentId: opts.agentId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  // Render block (curated facts as bullets; chat messages as quoted lines
  // tagged with role + date so the model knows what it's looking at).
  const lines: string[] = [];
  for (const hit of items) {
    const isFact = hit.collection === FACTS_COLLECTION;
    if (isFact) {
      const fact = String(hit.doc?.fact ?? "").trim();
      if (fact) lines.push(`- ${fact}`);
      continue;
    }
    const role = String(hit.doc?.role ?? "");
    const content = String(hit.doc?.content ?? "").trim();
    const ts = String(hit.doc?.timestamp ?? hit.doc?.ts ?? "");
    if (!content) continue;
    const date = ts ? ts.slice(0, 10) : "unknown";
    lines.push(`- [${date} ${role}] ${content.slice(0, 400)}`);
  }
  if (lines.length === 0 && fallbackLines.length > 0) {
    lines.push(...fallbackLines);
  }
  const formatted = lines.join("\n");
  const bytesInjected = formatted ? Buffer.byteLength(formatted, "utf8") : 0;

  trace?.event("memory.scoped_read", {
    scope: "scoped",
    userId,
    agentId: opts.agentId,
    facts: includeValues ? lines : lines.map(() => "<redacted>"),
    entryCount: lines.length,
    bytesInjected,
    collectionsQueried,
    injectionPoint: "system_prompt",
    latencyMs: Date.now() - t0,
    backend: "mongodb",
    primaryFailed: Boolean(retrievalErr),
    mode,
    queryText: includeValues ? trimmedQuery : "<redacted>",
    embeddingSource: embed.ok ? embed.source : undefined,
    embeddingModel: embed.ok ? embed.modelId : undefined,
    retrieval: {
      topK,
      fetchK,
      vectorHits: meta.vectorHits,
      lexicalHits: meta.lexicalHits,
      rrfMergedCount: meta.rrfMergedCount,
      perCollection: meta.perCollection,
    },
    retrievalErrorClass: retrievalErr?.class,
    retrievalErrorMessage: retrievalErr?.message,
  });

  return formatted || null;
}

/**
 * Retrieve user-level profile/preferences facts across all agents.
 * This helps orchestrator/specialists personalize "my ..." requests even when
 * prior facts were learned in a different specialist conversation.
 */
export async function readSharedLongTermMemory(userId: string): Promise<string | null> {
  if (!userId) return null;
  const limit = Math.max(3, maxInjectTurns());
  const trace = currentTrace();
  const includeValues = memoryTraceValuesEnabled();
  const t0 = Date.now();
  let primaryFailed = false;
  try {
    const facts = await mongoReadSharedFacts(userId, limit);
    if (facts.length > 0) {
      const formatted = facts.map((f) => `- ${f}`).join("\n");
      trace?.event("memory.shared_read", {
        scope: "shared",
        userId,
        facts: includeValues ? facts : facts.map(() => "<redacted>"),
        entryCount: facts.length,
        bytesInjected: Buffer.byteLength(formatted, "utf8"),
        collectionsQueried: [FACTS_COLLECTION],
        injectionPoint: "system_prompt",
        latencyMs: Date.now() - t0,
        backend: "mongodb",
      });
      return formatted;
    }
  } catch (err) {
    primaryFailed = true;
    logger.warn("[memory] shared long-term read failed", {
      userId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
  trace?.event("memory.shared_read", {
    scope: "shared",
    userId,
    facts: [],
    entryCount: 0,
    bytesInjected: 0,
    collectionsQueried: [FACTS_COLLECTION],
    injectionPoint: "system_prompt",
    latencyMs: Date.now() - t0,
    backend: "mongodb",
    primaryFailed,
  });
  return null;
}

