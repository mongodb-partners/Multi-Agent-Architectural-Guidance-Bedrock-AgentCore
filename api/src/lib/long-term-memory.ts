/**
 * Long-term memory: per-user, per-agent conversation history.
 *
 * Backends and priority:
 *
 *   Primary: MongoDB facts store (`agent_memory_facts`) with TTL.
 *   Fallback: AgentCore Memory Store if MongoDB read/write is unavailable.
 *
 * This keeps long-term memory scoped to user profile/preferences/facts while
 * still providing resilience when one backend is temporarily unavailable.
 *
 * Public API stays: writeLongTermMemory / readLongTermMemory.
 * Agents in .agent.md activate this via `memory.longTerm: true`.
 */

import {
  BedrockAgentCoreClient,
  CreateEventCommand,
  ListEventsCommand,
  ListSessionsCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { getMongoDb } from "../lib/mongo-client.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";

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

  // Group consecutive USER+ASSISTANT pairs back into MemoryTurn objects.
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
// MongoDB backend (legacy / local fallback)
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

type FactCandidate = {
  text: string;
  matched: boolean;
  matchedPatterns?: string[];
  rejectedReason?: "too_short" | "too_long" | "no_pattern_match" | "duplicate";
  length: number;
};

const PATTERNS: Array<{ name: string; re: RegExp }> = [
  {
    name: "identity",
    re: /\b(i am|i'm|my name is|my email is|i prefer|i like|i need|my order is|my serial|my device|for me)\b/i,
  },
  {
    name: "topic",
    re: /\b(email|order|serial|preference|budget|address|phone)\b/i,
  },
];

export function extractFactCandidates(userMessage: string): {
  accepted: string[];
  considered: FactCandidate[];
} {
  const src = userMessage
    .replace(/\r/g, "")
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
  const considered: FactCandidate[] = [];
  const accepted: string[] = [];
  const seen = new Set<string>();
  for (const line of src) {
    const candidate: FactCandidate = { text: line, matched: false, length: line.length };
    if (line.length < 8) {
      candidate.rejectedReason = "too_short";
      considered.push(candidate);
      continue;
    }
    if (line.length > 220) {
      candidate.rejectedReason = "too_long";
      considered.push(candidate);
      continue;
    }
    const matchedNames = PATTERNS.filter((p) => p.re.test(line)).map((p) => p.name);
    if (matchedNames.length === 0) {
      candidate.rejectedReason = "no_pattern_match";
      considered.push(candidate);
      continue;
    }
    const k = line.toLowerCase();
    if (seen.has(k)) {
      candidate.matched = true;
      candidate.matchedPatterns = matchedNames;
      candidate.rejectedReason = "duplicate";
      considered.push(candidate);
      continue;
    }
    seen.add(k);
    candidate.matched = true;
    candidate.matchedPatterns = matchedNames;
    considered.push(candidate);
    accepted.push(line);
    if (accepted.length >= 6) break;
  }
  return { accepted, considered };
}

function memoryTraceValuesEnabled(): boolean {
  const v = process.env.MEMORY_TRACE_VALUES?.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

async function mongoWriteFacts(turn: MemoryTurn): Promise<{
  outcome: "persisted" | "skipped" | "failed";
  reason?: "mongodb_unavailable" | "no_fact_candidates";
  accepted: string[];
  considered: FactCandidate[];
  inserted: number;
  priorEntryCount: number | null;
  newEntryCount: number | null;
  ttlExpiresAt: string;
  errorClass?: string;
  errorMessage?: string;
}> {
  const ttlDays = Number(process.env.MEMORY_TTL_DAYS ?? 90);
  const ttlExpiresAt = new Date(Date.now() + ttlDays * 86_400_000).toISOString();
  const { accepted, considered } = extractFactCandidates(turn.userMessage);

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
      wouldHaveStored: extractFactCandidates(userMessage).accepted.length > 0,
    });
    return;
  }
  if (!assistantReply.trim()) {
    trace?.event("memory.long_term_skip", {
      reason: "empty_assistant_reply",
      userId,
      agentId,
      userMessageExcerpt: userMessage.slice(0, 200),
      wouldHaveStored: extractFactCandidates(userMessage).accepted.length > 0,
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
    };
  }

  // Skip → emit memory.long_term_skip and exit.
  if (result.outcome === "skipped") {
    trace?.event("memory.long_term_skip", {
      reason: result.reason ?? "no_fact_candidates",
      userId,
      agentId,
      userMessageExcerpt: userMessage.slice(0, 200),
      wouldHaveStored: result.accepted.length > 0,
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
    logger.warn("[memory] failed to write long-term memory", {
      userId,
      agentId,
      backend: "mongodb",
      error: result.errorMessage,
    });
  } else {
    logger.debug("[memory] wrote facts to MongoDB agent_memory_facts", { userId, agentId });
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
