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

import {
  BedrockAgentCoreClient,
  CreateEventCommand,
  ListEventsCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { getMongoDb } from "../lib/mongo-client.ts";
import {
  extractFactsWithLlm,
  type FactCandidate,
} from "./llm-fact-extractor.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";

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
  ts: string;
};

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
      priorEntryCount: null,
      newEntryCount: null,
      ttlExpiresAt,
      ...extractorMeta,
    };
  }
  const docs: MemoryFact[] = accepted.map((fact) => ({
    userId: turn.userId,
    agentId: turn.agentId,
    fact,
    source: "user",
    ts: turn.ts,
  }));
  let priorEntryCount: number | null = null;
  let newEntryCount: number | null = null;
  try {
    priorEntryCount = await db
      .collection(FACTS_COLLECTION)
      .countDocuments({ userId: turn.userId, agentId: turn.agentId });
  } catch {
    /* best-effort */
  }
  try {
    await db.collection(FACTS_COLLECTION).insertMany(docs);
  } catch (err) {
    return {
      outcome: "failed",
      accepted,
      considered,
      inserted: 0,
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
    inserted: docs.length,
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
    op: result.outcome === "persisted" ? "insertMany" : "skip",
    docsInserted: result.inserted,
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
