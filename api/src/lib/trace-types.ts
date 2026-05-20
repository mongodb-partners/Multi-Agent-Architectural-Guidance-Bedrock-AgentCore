/**
 * Trace event schema for the per-turn `Trace` document.
 *
 * Every event carries `{ id, parentId?, type, ts, durationMs?, agentId?, payload }`.
 * Event types form a discriminated union on `type`. `parentId` chains events
 * into a span tree (`chat.turn.start` is the implicit root via `chat.turn.end`).
 *
 * The OpenTelemetry shape (id/parent/duration/timestamp) is intentional — we
 * don't wire OTLP today but want zero-friction migration when we do.
 */

/** Common fields on every emitted event. */
export type TraceEventBase = {
  /** UUID minted at emission (`crypto.randomUUID()`). Globally unique. */
  id: string;
  /** Parent event id, if any. Roots have `parentId === undefined`. */
  parentId?: string;
  /** Discriminator. */
  type: TraceEventType;
  /** Emission timestamp (epoch ms). */
  ts: number;
  /** Optional duration for spans (start/end pairs collapsed into one record). */
  durationMs?: number;
  /** Agent id at the time of emission (null/undefined for chat-route-level events). */
  agentId?: string;
};

export type TraceEventType =
  | "chat.turn.start"
  | "chat.turn.end"
  | "auth.context_build"
  | "memory.shared_read"
  | "memory.scoped_read"
  | "memory.long_term_write"
  | "memory.long_term_skip"
  | "prompt.assembled"
  | "model.request"
  | "model.text_delta_batch"
  | "model.thinking_block"
  | "model.usage"
  | "model.stop"
  | "model.retry"
  | "skill.activated"
  | "tool.call"
  | "tool.http"
  | "tool.mcp"
  | "tools.batch"
  | "conversation.message_added"
  | "handoff.decision"
  | "agent.activate"
  | "mongo.intent"
  | "mongo.query"
  | "mongo.plan"
  | "mongo.result"
  | "mongo.diagnostic"
  | "mongo.vector_search"
  | "mongo.schema"
  | "agentcore.invoke"
  | "agentcore.classification"
  | "agentcore.nested_trace"
  | "agentcore.observability_link"
  | "agentcore.gateway"
  | "agentcore.retry"
  | "latency.checkpoint"
  | "dev.environment"
  | "dev.byte_cap_hit"
  | "error";

// ---------------------------------------------------------------------------
// Payload shapes
// ---------------------------------------------------------------------------

export type ChatTurnStartPayload = {
  sessionId: string;
  messageId: string;
  agentId: string;
  userId?: string;
  requestId?: string;
  startTs: number;
  /**
   * Allow-listed inbound headers for the dev panel's "copy curl to reproduce"
   * block. Auth-bearing headers are redacted to `***`. Allow list:
   * `x-request-id`, `user-agent`, `x-forwarded-for`, `accept`, `content-length`.
   */
  requestHeadersPreview?: Record<string, string>;
};

export type ChatTurnSummary = {
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  cacheReadInputTokens?: number;
  cacheWriteInputTokens?: number;
  toolCalls: number;
  mongoQueries: number;
  mongoDocsReturned: number;
  mcpCalls: number;
  agentcoreHops?: number;
  agentcoreRuntimeMs?: number;
  bytesIn: number;
  bytesOut: number;
  finalAgentId?: string;
  eventsDropped: number;
  nestedEventsDropped?: number;
  estimatedCostUsd: number | null;
  costBreakdown: Record<string, number>;
  costEstimateComplete: boolean;
};

export type ChatTurnEndPayload = {
  durationMs: number;
  summary: ChatTurnSummary;
};

export type AuthContextBuildPayload = {
  userId?: string;
  jwtClaims?: { sub?: string; iss?: string; aud?: string };
  customersResolved: number;
  ordersResolved: number;
};

export type MemoryReadPayload = {
  scope: "scoped" | "shared";
  userId: string;
  agentId?: string;
  /** The actual fact strings the model will see (gated by MEMORY_TRACE_VALUES). */
  facts: string[];
  entryCount: number;
  bytesInjected: number;
  collectionsQueried: string[];
  injectionPoint: "system_prompt" | "tool_result";
  latencyMs: number;
  backend: "mongodb" | "agentcore_memory_store";
  primaryFailed?: boolean;
  // ---- Hybrid retrieval enrichments (optional; only present for vector path) ----
  /** Retrieval mode used: pure vector, pure lexical, or fused. */
  mode?: "hybrid" | "vector" | "lexical";
  /** Raw query string (redacted unless MEMORY_TRACE_VALUES=1). */
  queryText?: string;
  /** Embedding provider for the query embedding. */
  embeddingSource?: "voyage" | "bedrock" | string;
  /** Provider id for the query embedding. */
  embeddingModel?: string;
  /** Per-leg counts and per-collection telemetry for the hybrid retriever. */
  retrieval?: {
    topK: number;
    fetchK: number;
    vectorHits: number;
    lexicalHits: number;
    rrfMergedCount: number;
    perCollection: Array<{
      collection: string;
      vectorReturned: number;
      lexicalReturned: number;
      error?: string;
    }>;
  };
  retrievalErrorClass?: string;
  retrievalErrorMessage?: string;
  // ---- Live env-knob snapshot (debug-grade depth in Developer details) ------
  /** MMR diversity weight (0 = pure diversity, 1 = pure relevance). */
  mmrLambda?: number;
  /** Exponential recency decay half-life in days. `0` disables. */
  recencyHalflifeDays?: number;
  /** Multiplier on `agent_memory_facts` RRF score. */
  weightFacts?: number;
  /** Multiplier on `chat_messages` RRF score. */
  weightChatMessages?: number;
  /** `$vectorSearch.numCandidates` width. */
  numCandidates?: number;
};

export type MemoryLongTermWritePayload = {
  userId: string;
  agentId: string;
  ts: string;
  factCandidates: Array<{
    text: string;
    matched: boolean;
    /** Single-element array containing the LLM-emitted category. */
    matchedPatterns?: string[];
    rejectedReason?:
      | "too_short"
      | "too_long"
      | "duplicate"
      | "llm_rejected";
    length: number;
    /** LLM-emitted category. */
    category?: string;
    /** LLM-emitted short reason; either why a fact was kept or why it was ignored. */
    note?: string;
  }>;
  factsExtracted: string[];
  collection: "agent_memory_facts";
  op: "insertMany" | "bulkWrite" | "skip";
  docsInserted: number;
  /** Number of accepted facts already present (matched on `factHash`, skipped by upsert). */
  duplicatesSkipped?: number;
  /** Number of accepted facts that received an embedding before write. */
  embeddedCount?: number;
  /** Embedding model id (`"voyage"` | `"bedrock:<modelId>"`). */
  embeddingModel?: string;
  primaryBackend: "mongodb";
  primaryOutcome: "persisted" | "skipped" | "failed";
  primaryErrorClass?: string;
  primaryErrorMessage?: string;
  fallbackBackend?: "agentcore_memory_store";
  fallbackOutcome?: "persisted" | "skipped" | "failed";
  fallbackErrorClass?: string;
  fallbackErrorMessage?: string;
  userMessageBytes: number;
  userMessageBytesStored: number;
  assistantReplyBytes: number;
  assistantReplyBytesStored: number;
  priorEntryCount: number | null;
  newEntryCount: number | null;
  ttlExpiresAt: string;
  latencyMs: number;
  /** Bedrock model id used by the LLM fact extractor. */
  extractorModelId?: string;
  /** Latency of the extraction step itself (separate from the overall write `latencyMs`). */
  extractorLatencyMs?: number;
  /** Bedrock token usage for the extractor call. */
  extractorInputTokens?: number;
  extractorOutputTokens?: number;
};

export type MemoryLongTermSkipPayload = {
  reason:
    | "no_user_id"
    | "empty_assistant_reply"
    | "agent_memory_disabled"
    | "mongodb_unavailable"
    | "no_fact_candidates"
    | "llm_extractor_failed";
  userId?: string;
  agentId: string;
  userMessageExcerpt: string;
  /** Diagnostic fields surfaced when reason === "llm_extractor_failed". */
  extractorModelId?: string;
  extractorLatencyMs?: number;
  extractorError?: string;
};

export type PromptAssembledPayload = {
  personaBytes: number;
  discoveryBytes: number;
  memoryContextBytes: number;
  activatedSkills: Array<{ name: string; bytes: number; injectedVia: "system_prompt" | "tool_result" }>;
  totalBytes: number;
  body?: string; // full prompt; capped at 64 KB by truncation table, never dropped silently
  /** Length of the original body in bytes (pre-truncation). Always populated. */
  bodyBytes?: number;
  /** SHA-256 (first 16 hex chars) of the original body — diff-friendly chip. */
  bodyHash?: string;
};

export type ModelRequestPayload = {
  modelId: string;
  region?: string;
  systemPromptHash: string;
  systemPromptBytes: number;
  priorTurnsCount: number;
  userMessage: string;
  /** Lightweight preview of the prior conversation turns replayed into the
   *  Strands Agent (`messages: seed`). Max 6 turns, each preview ≤ 200 chars. */
  priorTurnsPreview?: Array<{ role: string; bytes: number; preview: string }>;
  /** Source-of-truth replay: the actual `messages: seed` array passed into the
   *  Strands `Agent` constructor. Whole array capped at 32 KB; per-item
   *  `contentPreview` capped at 4 KB via the per-event-type truncation table. */
  messagesSeed?: Array<{ role: string; contentBytes: number; contentPreview: string }>;
};

export type ModelUsagePayload = {
  modelId: string;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  cacheReadInputTokens?: number;
  cacheWriteInputTokens?: number;
  latencyMs?: number;
  timeToFirstByteMs?: number;
};

export type ModelStopPayload = {
  stopReason: "tool_use" | "end_turn" | "max_tokens" | "guardrail_intervened" | "stop_sequence" | string;
};

export type ModelTextDeltaBatchPayload = {
  text: string;
  bytes: number;
  windowMs: number;
  /** Running total of streamed assistant bytes since `model.request` start.
   *  Powers the Performance panel's streaming-throughput line chart. */
  cumulativeBytes?: number;
};

export type ModelThinkingBlockPayload = {
  text: string;
  bytes: number;
};

export type SkillActivatedPayload = {
  name: string;
  source: "pre_activate" | "model_tool_call";
  injectedVia: "system_prompt" | "tool_result";
  bytes: number;
  allowed: boolean;
  /** Preview of the skill body that got injected (4 KB cap via truncation
   *  table). Lets the dev panel show *which* skill body was injected without
   *  forcing them to diff `prompt.assembled.body` by hand. */
  bodyPreview?: string;
  /**
   * Per-skill roll-up of `read_skill_resource` tool calls observed for this
   * skill activation. Populated by `skill-loader.ts` / `base-tools.ts` and
   * folded in at finalize time. The flat `tool.call` events still stream
   * live; this array is metadata for the Skills sub-panel.
   */
  resourceReads?: Array<{
    resourcePath: string;
    bytes: number;
    toolUseId?: string;
    latencyMs?: number;
  }>;
};

export type ToolCallPayload = {
  toolName: string;
  toolUseId?: string;
  input?: unknown;
  result?: unknown;
  error?: { class: string; message: string };
};

export type ToolHttpPayload = {
  url: string;
  method: string;
  headers?: Record<string, string>;
  body?: unknown;
  status?: number;
  responseBytes?: number;
  responseSnippet?: string;
  errorClass?: string;
  errorMessage?: string;
  blocked?: "host_not_allowed" | "url_not_configured";
};

export type ToolMcpPayload = {
  server: string;
  toolName: string;
  args?: unknown;
  result?: unknown;
  errorClass?: string;
  errorMessage?: string;
};

export type ToolsBatchPayload = {
  toolCount: number;
};

export type ConversationMessageAddedPayload = {
  role: "user" | "assistant" | "system" | "tool";
  blockCount: number;
  bytes: number;
};

export type HandoffDecisionPayload = {
  fromAgentId: string;
  toAgentId: string;
  toAgentName?: string;
  toAgentDescription?: string;
  userMessage: string;
  userMessageId?: string;
  orchestratorReasoning: string;
  structuredOutput: unknown;
  reason?: string;
  matchedHandoffEntry?: { label: string; agent: string; prompt?: string };
  triggerSpans: Array<{
    phrase: string;
    source: "userMessage" | "orchestratorReasoning";
    offset: [number, number];
    matchedAgainst: "description" | "handoff.label" | "handoff.prompt" | "skill";
    matchedAgainstValue: string;
  }>;
  alternativesConsidered: Array<{
    agentId: string;
    label?: string;
    score: number;
    matchedPhrases: string[];
  }>;
  chosenScore?: number;
  confidence: number | null;
  priorToolCalls: Array<{ name: string; toolUseId?: string; durationMs?: number }>;
  priorHandoffCount: number;
  conversationContextTurns: Array<{ role: string; preview: string }>;
  latencyToDecisionMs: number;
  tokensBeforeDecision: number;
};

export type AgentActivatePayload = {
  agentId: string;
  agentName?: string;
  specialist: boolean;
  suppressed: boolean;
};

// MongoDB event family ------------------------------------------------------

export type MongoIntentPayload = {
  collection: string;
  triggeringUserMessage?: string;
  thinkingSnippet?: string;
  skillInstructionSnippet?: string;
  conversationTurnIndex?: number;
};

export type MongoQueryPayload = {
  mode: "mcp";
  database?: string;
  collection: string;
  op: "find" | "findOne" | "aggregate" | "updateOne" | "insertOne" | "vector_search" | string;
  filter?: unknown;
  normalizedFilter?: unknown;
  projection?: unknown;
  sort?: unknown;
  limit?: number;
  skip?: number;
  pipeline?: unknown;
  /**
   * Tenant-leak audit. Required for queries on user-scoped collections
   * (`agent_memory_facts`, `chat_messages`, `chat_sessions`, `traces`); the
   * dev panel surfaces `missing_user_filter` as a red chip. Optional for
   * other collections (products catalog, troubleshooting docs, etc.).
   */
  scoping?: "ok" | "missing_user_filter";
};

export type MongoPlanPayload = {
  mode: "mcp";
  explainSupported: boolean;
  stage?: string;
  indexName?: string;
  nReturned?: number;
  totalDocsExamined?: number;
  totalKeysExamined?: number;
  executionTimeMillis?: number;
  rejectedPlans?: number;
  selectivity?: number;
  selectivity_low?: boolean;
  index_missing_suggested?: string;
};

export type MongoResultPayload = {
  docCount: number;
  latencyMs: number;
  status: "ok" | "empty" | "error";
  errorClass?: string;
  errorMessage?: string;
  sampleDocs?: unknown[];
  uncovered?: string[];
  perStageReturned?: number[];
  /** Mirrors `mongo.plan` fields when they're available alongside the result. */
  documentsExamined?: number;
  keysExamined?: number;
};

export type MongoDiagnosticPayload = {
  ranProbes: number;
  budgetMs: number;
  offendingClause?: {
    field: string;
    op: string;
    value: unknown;
    countWith: number;
    countWithout: number;
  };
  field_not_in_sample?: string[];
  valueTypeWarnings?: Array<{ field: string; kind: "objectid_string" | "case_sensitive" | "iso_string_vs_date"; detail: string }>;
  index_missing_suggested?: string;
  schemaMismatch?: boolean;
};

export type MongoVectorSearchPayload = {
  collection?: string;
  embeddingSource: "voyage" | "bedrock" | string;
  embeddingModelId?: string;
  queryText: string;
  queryVectorPreview?: { length: number; head: number[]; tail: number[] };
  numCandidates?: number;
  limit?: number;
  filter?: unknown;
  scores?: number[];
  scoreSummary?: { min: number; max: number; avg: number };
  histogram?: number[];
  recallWithoutFilter?: number;
  /** True when the wrapper routed through `mongodb_hybrid_search` (vector + lexical RRF). */
  hybrid?: boolean;
  /**
   * Atlas Vector Search / Atlas Search index name actually used by the
   * `$vectorSearch.index` or `$search.index` operator. Source-of-truth
   * defaults live in `db-seeding/seed-indexes.ts`; surfacing the value the
   * runtime sent helps catch typo drift between code and what Atlas created.
   */
  indexName?: string;
  /** Time spent embedding the query text (excluded from `searchMs`). */
  embedQueryMs?: number;
  /** Time spent inside `$vectorSearch` / `$search` (excludes embedding). */
  searchMs?: number;
  documentPreviews?: Array<{
    rank: number;
    collection?: string;
    /** Native MongoDB document id, when the result document carried `_id`. */
    _id?: string;
    /** Stable display id; falls back to domain ids such as `docId`, `messageId`, or `sku`. */
    id?: string;
    score?: number;
    title?: string;
    snippet?: string;
    sourceUrl?: string;
    sources?: string[];
    fields?: Record<string, string | number | boolean | null>;
  }>;
};

export type MongoSchemaPayload = {
  collection: string;
  fields: Array<{ name: string; type: string }>;
  estimatedDocumentCount: number;
};

// AgentCore event family ----------------------------------------------------

export type AgentcoreInvokePayload = {
  arn: string;
  region?: string;
  qualifier?: string;
  runtimeSessionId?: string;
  mode: "ec2_to_orchestrator" | "orchestrator_to_specialist" | string;
  requestBytes?: number;
  responseBytes?: number;
  latencyMs: number;
  httpStatus?: number;
  errorClass?: string;
  errorMessage?: string;
  correlationId?: string;
  targetAgentId?: string;
  payload?: unknown;
  responseBody?: unknown;
  /** Auth-scrubbed allow-list of outbound request headers. */
  requestHeadersPreview?: Record<string, string>;
  /** Auth-scrubbed allow-list of response headers. */
  responseHeadersPreview?: Record<string, string>;
};

export type AgentcoreClassificationPayload = {
  inputMessage: string;
  chosenSpecialist: string;
  reasoning?: string;
  latencyMs: number;
};

export type AgentcoreNestedTracePayload = {
  nestedTraceId?: string;
  nestedRuntimeArn?: string;
  eventCount: number;
  nestedEventsDropped?: number;
};

export type AgentcoreObservabilityLinkPayload = {
  xrayUrl?: string;
  cloudwatchLogGroup?: string;
  cloudwatchLogStreamUrl?: string;
  runtimeRequestId?: string;
};

export type AgentcoreGatewayPayload = {
  gatewayArn?: string;
  targetName: string;
  routingDecision?: string;
};

export type LatencyCheckpointPayload = {
  name:
    | "api.stream.opened"
    | "api.runtime.first_frame"
    | "api.client.first_token"
    | "runtime.headers_flushed"
    | "runtime.first_frame"
    | "runtime.first_token"
    | "model.first_delta"
    | "model.first_tool_call";
  elapsedMs: number;
  agentId?: string;
  eventKind?: string;
  partType?: string;
  toolName?: string;
};

// Retry events --------------------------------------------------------------

export type ModelRetryPayload = {
  /** "bedrock" today; reserved for other providers later. */
  provider: "bedrock" | string;
  modelId: string;
  /** 1-indexed attempt number (1 = first retry after the initial call). */
  attempt: number;
  previousErrorClass: string;
  previousErrorMessage: string;
  /** Delay slept before the retry, ms. */
  backoffMs: number;
};

export type AgentcoreRetryPayload = {
  arn: string;
  targetAgentId?: string;
  mode: string;
  attempt: number;
  previousErrorClass: string;
  previousErrorMessage: string;
  backoffMs: number;
  httpStatus?: number;
};

// Dev events ----------------------------------------------------------------

export type DevEnvironmentPayload = {
  runtime: string;
  modelBackend: string;
  chatMode: string;
  devMockBackends: boolean;
  mongoUri: "configured" | "missing";
  voyageConfigured: boolean;
  bedrockRegion?: string;
  /** Other on/off flags surfaced for the Environment sub-panel. */
  flags: Record<string, "0" | "1">;
};

export type DevByteCapHitPayload = {
  droppedType: TraceEventType;
  bytes: number;
  reason: "per_event" | "per_turn";
};

// Error event ---------------------------------------------------------------

export type ErrorPayload = {
  class: string;
  message: string;
  stack?: string;
  source?: string;
};

// ---------------------------------------------------------------------------
// Discriminated union
// ---------------------------------------------------------------------------

export type TraceEvent =
  | (TraceEventBase & { type: "chat.turn.start"; payload: ChatTurnStartPayload })
  | (TraceEventBase & { type: "chat.turn.end"; payload: ChatTurnEndPayload })
  | (TraceEventBase & { type: "auth.context_build"; payload: AuthContextBuildPayload })
  | (TraceEventBase & { type: "memory.shared_read"; payload: MemoryReadPayload })
  | (TraceEventBase & { type: "memory.scoped_read"; payload: MemoryReadPayload })
  | (TraceEventBase & { type: "memory.long_term_write"; payload: MemoryLongTermWritePayload })
  | (TraceEventBase & { type: "memory.long_term_skip"; payload: MemoryLongTermSkipPayload })
  | (TraceEventBase & { type: "prompt.assembled"; payload: PromptAssembledPayload })
  | (TraceEventBase & { type: "model.request"; payload: ModelRequestPayload })
  | (TraceEventBase & { type: "model.text_delta_batch"; payload: ModelTextDeltaBatchPayload })
  | (TraceEventBase & { type: "model.thinking_block"; payload: ModelThinkingBlockPayload })
  | (TraceEventBase & { type: "model.usage"; payload: ModelUsagePayload })
  | (TraceEventBase & { type: "model.stop"; payload: ModelStopPayload })
  | (TraceEventBase & { type: "model.retry"; payload: ModelRetryPayload })
  | (TraceEventBase & { type: "skill.activated"; payload: SkillActivatedPayload })
  | (TraceEventBase & { type: "tool.call"; payload: ToolCallPayload })
  | (TraceEventBase & { type: "tool.http"; payload: ToolHttpPayload })
  | (TraceEventBase & { type: "tool.mcp"; payload: ToolMcpPayload })
  | (TraceEventBase & { type: "tools.batch"; payload: ToolsBatchPayload })
  | (TraceEventBase & { type: "conversation.message_added"; payload: ConversationMessageAddedPayload })
  | (TraceEventBase & { type: "handoff.decision"; payload: HandoffDecisionPayload })
  | (TraceEventBase & { type: "agent.activate"; payload: AgentActivatePayload })
  | (TraceEventBase & { type: "mongo.intent"; payload: MongoIntentPayload })
  | (TraceEventBase & { type: "mongo.query"; payload: MongoQueryPayload })
  | (TraceEventBase & { type: "mongo.plan"; payload: MongoPlanPayload })
  | (TraceEventBase & { type: "mongo.result"; payload: MongoResultPayload })
  | (TraceEventBase & { type: "mongo.diagnostic"; payload: MongoDiagnosticPayload })
  | (TraceEventBase & { type: "mongo.vector_search"; payload: MongoVectorSearchPayload })
  | (TraceEventBase & { type: "mongo.schema"; payload: MongoSchemaPayload })
  | (TraceEventBase & { type: "agentcore.invoke"; payload: AgentcoreInvokePayload })
  | (TraceEventBase & { type: "agentcore.classification"; payload: AgentcoreClassificationPayload })
  | (TraceEventBase & { type: "agentcore.nested_trace"; payload: AgentcoreNestedTracePayload })
  | (TraceEventBase & { type: "agentcore.observability_link"; payload: AgentcoreObservabilityLinkPayload })
  | (TraceEventBase & { type: "agentcore.gateway"; payload: AgentcoreGatewayPayload })
  | (TraceEventBase & { type: "agentcore.retry"; payload: AgentcoreRetryPayload })
  | (TraceEventBase & { type: "latency.checkpoint"; payload: LatencyCheckpointPayload })
  | (TraceEventBase & { type: "dev.environment"; payload: DevEnvironmentPayload })
  | (TraceEventBase & { type: "dev.byte_cap_hit"; payload: DevByteCapHitPayload })
  | (TraceEventBase & { type: "error"; payload: ErrorPayload });

/**
 * Precomputed span-tree node built by `TraceCollector.buildSpanTree()` at
 * finalize time. Stored on `Trace.spanTree` so the dev panel doesn't have to
 * walk every event to reconstruct the hierarchy.
 */
export type TraceSpanNode = {
  id: string;
  type: TraceEventType;
  ts: number;
  durationMs?: number;
  agentId?: string;
  children: TraceSpanNode[];
};

/** Rolled-up trace document persisted to MongoDB / served by the trace endpoints. */
export type Trace = {
  traceId: string;
  sessionId: string;
  messageId: string;
  userId?: string;
  agentId: string;
  events: TraceEvent[];
  summary: ChatTurnSummary;
  createdAt: string;
  truncated?: boolean;
  eventsDropped?: number;
  // ---- Dev-only top-level fields (populated when capture is on; stripped by
  //      `projectTraceForInclude(trace, "core")` so demos stay fast). --------
  /** Build/release metadata. Surfaced in Developer details → Environment. */
  release?: {
    gitSha?: string;
    deployTs?: string;
    nodeVersion?: string;
    bunVersion?: string;
    env?: string;
  };
  /** Request-level correlation (auth-scrubbed). */
  correlation?: {
    requestId?: string;
    apiClientIp?: string;
    userAgent?: string;
  };
  /** OTel root span/trace id, 16-byte hex. Powers ServiceLens / X-Ray deep
   *  links in Developer details → Identifiers. */
  otel?: {
    traceId: string;
    rootSpanId: string;
  };
  /** Precomputed span tree (`parentId` hierarchy). */
  spanTree?: TraceSpanNode[];
};
