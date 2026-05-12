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
};

export type MemoryLongTermWritePayload = {
  userId: string;
  agentId: string;
  ts: string;
  factCandidates: Array<{
    text: string;
    matched: boolean;
    matchedPatterns?: string[];
    rejectedReason?: "too_short" | "too_long" | "no_pattern_match" | "duplicate";
    length: number;
  }>;
  factsExtracted: string[];
  collection: "agent_memory_facts";
  op: "insertMany" | "skip";
  docsInserted: number;
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
};

export type MemoryLongTermSkipPayload = {
  reason:
    | "no_user_id"
    | "empty_assistant_reply"
    | "agent_memory_disabled"
    | "mongodb_unavailable"
    | "no_fact_candidates";
  userId?: string;
  agentId: string;
  userMessageExcerpt: string;
  wouldHaveStored: boolean;
};

export type PromptAssembledPayload = {
  personaBytes: number;
  discoveryBytes: number;
  memoryContextBytes: number;
  activatedSkills: Array<{ name: string; bytes: number; injectedVia: "system_prompt" | "tool_result" }>;
  totalBytes: number;
  body?: string; // full prompt; dropped in degraded mode
};

export type ModelRequestPayload = {
  modelId: string;
  region?: string;
  systemPromptHash: string;
  systemPromptBytes: number;
  priorTurnsCount: number;
  userMessage: string;
  /** Backend flag — "bedrock" or "mock" (dev mock model). */
  backend: "bedrock" | "mock";
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
  transport: "stdio" | "http";
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
  /** Whether routing was decided by the LLM via structured output or by the DevMockModel's regex. */
  routingSource?: "llm" | "devmock_regex";
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
  mode: "direct" | "lambda" | "mcp";
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
  scoping?: "ok" | "missing_user_filter";
};

export type MongoPlanPayload = {
  mode: "direct" | "lambda" | "mcp";
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
  embeddingSource: "voyage" | "bedrock" | "mock" | string;
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
  | (TraceEventBase & { type: "error"; payload: ErrorPayload });

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
};
