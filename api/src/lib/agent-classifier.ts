/**
 * Front-door agent classifier.
 *
 * Picks one or more specialist `agentId`s for a user message without paying
 * the cost of a full orchestrator runtime turn. Two backends, in order:
 *
 *   1. Heuristic — token-overlap scoring of the user message against each
 *      agent's `description`, `handoffs[].label`, and `handoffs[].prompt`
 *      (synthesized from `config/agents/*.agent.md`). Sub-millisecond, no
 *      network. When the top score clears `HEURISTIC_MIN_SCORE` and there
 *      is a clear winner (margin over 2nd place), we accept it.
 *
 *   2. Bedrock Haiku tool-forced classification — fired only when the
 *      heuristic is uncertain. One short Bedrock call (~150-300 ms warm).
 *
 * The result is cached per process in a small LRU keyed on a hash of the
 * normalized message so back-to-back identical chats don't re-run the call.
 *
 * Set `CLASSIFIER_BACKEND=heuristic` to disable the Haiku fallback (useful
 * when you're rate-limited or want zero classifier-driven LLM cost).
 *
 * ## Multi-select
 *
 * `classifyAgents(...)` is the multi-select API. By default it returns
 * **one** specialist (same behavior as the original `classifyAgent(...)`).
 * It returns multiple specialists ONLY when there is strong evidence the
 * user message spans multiple distinct domains. Concretely:
 *
 *   - Heuristic returns multiple iff the runner-up score clears
 *     `CLASSIFIER_MULTI_MIN_SCORE` (absolute floor) AND the runner-up is
 *     within `CLASSIFIER_MULTI_RELATIVE_MARGIN` of the leader (close-tie
 *     test). Both knobs default to values that mean every prompt in the
 *     existing single-specialist test suite still routes to one agent.
 *
 *   - Haiku is asked to return an ordered `agentIds` array, but the
 *     system prompt instructs it to return a SINGLE agent unless the
 *     message clearly requires multiple distinct domains. The tool
 *     schema enforces `minItems: 1, maxItems: CLASSIFIER_MULTI_MAX_AGENTS`.
 *
 *   - Multi-select is capped by `CLASSIFIER_MULTI_MAX_AGENTS` (default 2).
 *
 * `classifyAgent(...)` is preserved as a compatibility wrapper that
 * returns only the first selection.
 */

import { createHash } from "node:crypto";
import {
  BedrockRuntimeClient,
  ConverseCommand,
  type ToolConfiguration,
} from "@aws-sdk/client-bedrock-runtime";
import { getAgent, listAgents } from "./config-scan.ts";
import type { ChatMessage } from "./session-store.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";

export type ClassificationSource = "heuristic" | "haiku" | "cache";

/**
 * One selected specialist. Returned (singly) by `classifyAgent` and
 * (in arrays) by `classifyAgents`.
 */
export type ClassificationResult = {
  agentId: string;
  reasoning?: string;
  source: ClassificationSource;
  /** Top heuristic score for the chosen agent (when available). */
  score?: number;
};

/** A candidate that was considered but not selected. Surfaced in trace. */
export type RejectedCandidate = {
  agentId: string;
  score?: number;
  reason?: string;
};

/**
 * Multi-select classifier output. Always contains at least one selection
 * when the classifier is confident; `undefined` when nothing fits.
 */
export type MultiClassificationResult = {
  selections: ClassificationResult[];
  rejectedCandidates: RejectedCandidate[];
  thresholds: {
    multiMinScore: number;
    multiRelativeMargin: number;
    multiMaxAgents: number;
    heuristicMinScore: number;
    heuristicMargin: number;
  };
};

const STOPWORDS = new Set([
  "the", "a", "an", "and", "or", "of", "to", "is", "are", "for", "with",
  "my", "i", "you", "this", "that", "we", "he", "she", "it", "in", "on",
  "at", "by", "be", "as", "if", "do", "did", "had", "has", "have", "will",
  "would", "should", "could", "can", "may", "might", "shall", "yes", "no",
  "what", "where", "when", "how", "why", "who", "please", "help", "need",
  "want", "looking", "ordered", "got", "now", "just",
]);

function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9_-]+/i)
    .filter((t) => t.length > 2 && !STOPWORDS.has(t));
}

function bigramsOf(tokens: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i + 1 < tokens.length; i++) out.push(`${tokens[i]} ${tokens[i + 1]}`);
  return out;
}

// Read knobs per-call so test isolation works (any test that does
// `process.env = { ...saved }` in afterEach replaces the env object, and
// a captured reference would no longer see live mutations). Same pattern
// as `trace-collector.ts`.
function heuristicMinScore(): number {
  const v = Number(process.env.CLASSIFIER_HEURISTIC_MIN_SCORE ?? 1.5);
  return Number.isFinite(v) ? v : 1.5;
}
function heuristicMargin(): number {
  const v = Number(process.env.CLASSIFIER_HEURISTIC_MARGIN ?? 0.75);
  return Number.isFinite(v) ? v : 0.75;
}

/**
 * Multi-select absolute floor. The runner-up score must clear this to be
 * eligible for inclusion alongside the leader. Default `3.0` is high enough
 * to exclude every single-domain prompt in the existing test corpus
 * (runner-ups score < 2 there) while still allowing genuine multi-domain
 * prompts (where both top scores typically clear 4+) to fire.
 */
function multiMinScore(): number {
  const v = Number(process.env.CLASSIFIER_MULTI_MIN_SCORE ?? 3.0);
  return Number.isFinite(v) ? v : 3.0;
}

/**
 * Multi-select close-tie window. The runner-up must be within this many
 * points of the leader to be selected as a second specialist. Default `1.5`
 * means a leader scoring 5 admits a runner-up scoring ≥ 3.5.
 */
function multiRelativeMargin(): number {
  const v = Number(process.env.CLASSIFIER_MULTI_RELATIVE_MARGIN ?? 1.5);
  return Number.isFinite(v) ? v : 1.5;
}

/** Maximum specialists multi-select can return. Default 2. */
function multiMaxAgents(): number {
  const v = Number(process.env.CLASSIFIER_MULTI_MAX_AGENTS ?? 2);
  if (!Number.isFinite(v) || v < 1) return 2;
  return Math.floor(v);
}

const CACHE_MAX_ENTRIES = 256;

/** Cache stores the full multi-selection list so the single-result wrapper
 *  can degrade trivially while a future multi-call still hits the cache. */
type CachedDecision = {
  selections: Array<{ agentId: string; reasoning?: string }>;
};
const cache = new Map<string, CachedDecision>();

function cacheKey(message: string): string {
  return createHash("sha256").update(message.trim().toLowerCase()).digest("hex").slice(0, 32);
}

function rememberInCache(message: string, decision: CachedDecision): void {
  const key = cacheKey(message);
  if (cache.size >= CACHE_MAX_ENTRIES) {
    // Drop the oldest entry; insertion order is preserved by Map.
    const first = cache.keys().next().value;
    if (first !== undefined) cache.delete(first);
  }
  cache.set(key, decision);
}

/**
 * Build the candidate index from the orchestrator's generated handoff roster.
 * Any non-orchestrator `.agent.md` config becomes a routable specialist once
 * deploy-agents has created and injected its runtime ARN env var.
 */
type Candidate = {
  agentId: string;
  label: string;
  prompt?: string;
  description: string;
  tokenSet: Set<string>;
  bigramSet: Set<string>;
};

let _candidatesCache: Candidate[] | null = null;
let _candidatesAgentVersion: string | undefined;

function buildCandidates(): Candidate[] {
  // Invalidate cache when the listAgents output changes; this is cheap because
  // listAgents is itself mtime-cached.
  const versionKey = listAgents()
    .map((a) => `${a.id}:${a.name}:${a.description}`)
    .join("|");
  if (_candidatesCache && _candidatesAgentVersion === versionKey) return _candidatesCache;

  const orchestrator = getAgent("orchestrator");
  if (!orchestrator) {
    _candidatesCache = [];
    _candidatesAgentVersion = versionKey;
    return _candidatesCache;
  }

  const out: Candidate[] = [];
  for (const entry of orchestrator.handoffs ?? []) {
    const meta = getAgent(entry.agent);
    if (!meta) continue;
    const corpus = [entry.label ?? "", entry.prompt ?? "", meta.description ?? "", meta.skills.join(" ")]
      .filter(Boolean)
      .join(" ");
    const tokens = tokenize(corpus);
    out.push({
      agentId: entry.agent,
      label: entry.label,
      prompt: entry.prompt,
      description: meta.description ?? "",
      tokenSet: new Set(tokens),
      bigramSet: new Set(bigramsOf(tokens)),
    });
  }
  _candidatesCache = out;
  _candidatesAgentVersion = versionKey;
  return out;
}

function heuristicScore(messageTokens: Set<string>, messageBigrams: Set<string>, candidate: Candidate): number {
  let score = 0;
  for (const tok of candidate.tokenSet) {
    if (messageTokens.has(tok)) score += Math.log(1 + tok.length);
  }
  for (const bg of candidate.bigramSet) {
    if (messageBigrams.has(bg)) score += 1.5;
  }
  return score;
}

type HeuristicScored = { agentId: string; score: number };

function scoreAllCandidates(message: string): HeuristicScored[] {
  const candidates = buildCandidates();
  if (candidates.length === 0) return [];
  const tokens = tokenize(message);
  const tokenSet = new Set(tokens);
  const bigramSet = new Set(bigramsOf(tokens));
  return candidates
    .map((c) => ({ agentId: c.agentId, score: heuristicScore(tokenSet, bigramSet, c) }))
    .sort((a, b) => b.score - a.score);
}

function heuristicClassify(message: string): { agentId: string; score: number; runnerUp: number } | undefined {
  const scored = scoreAllCandidates(message);
  const top = scored[0];
  const second = scored[1]?.score ?? 0;
  if (!top || top.score < heuristicMinScore()) return undefined;
  if (top.score - second < heuristicMargin()) return undefined;
  return { agentId: top.agentId, score: top.score, runnerUp: second };
}

/**
 * Multi-select heuristic.
 *
 * Decision tree:
 *   - top.score < heuristicMinScore → undefined (too weak, caller falls
 *     back to Haiku).
 *   - runner-up clears multiMinScore AND is within multiRelativeMargin of
 *     leader → MULTI mode, return [top, runner-up, …] up to
 *     multiMaxAgents.
 *   - else → SINGLE mode. Apply the original `heuristicMargin` ambiguity
 *     gate: if (top - second) < heuristicMargin, return undefined (caller
 *     falls back to Haiku). Otherwise return [top].
 *
 * This preserves the original single-specialist behavior exactly:
 *   - "Recommend a budget gaming laptop" → top scores ~5, runner-up ~1.5,
 *     runner-up does NOT clear multiMinScore (3.0), single mode, margin
 *     check passes → returns [product-recommendation].
 *   - With HEURISTIC_MARGIN=999, the ambiguity gate fires and returns
 *     undefined — same as before.
 *   - "Track my order AND recommend a laptop" → both top scores clear
 *     multiMinScore and are close → multi mode, returns both.
 */
function heuristicClassifyMulti(message: string): {
  selections: Array<{ agentId: string; score: number }>;
  rejected: Array<{ agentId: string; score: number; reason: string }>;
} | undefined {
  const scored = scoreAllCandidates(message);
  const top = scored[0];
  if (!top || top.score < heuristicMinScore()) return undefined;

  const second = scored[1];
  const max = multiMaxAgents();
  const minScoreFloor = multiMinScore();
  const margin = multiRelativeMargin();

  const isMultiCandidate =
    !!second &&
    second.score >= minScoreFloor &&
    top.score - second.score <= margin;

  if (!isMultiCandidate) {
    // Single mode. Honor the original ambiguity gate: when there's no clear
    // winner (gap < heuristicMargin), let Haiku break the tie.
    if (second && top.score - second.score < heuristicMargin()) return undefined;
    const rejected: Array<{ agentId: string; score: number; reason: string }> = [];
    for (let i = 1; i < scored.length; i++) {
      const cand = scored[i];
      const reason =
        cand.score < minScoreFloor
          ? `below multi-min-score (${minScoreFloor.toFixed(2)})`
          : `outside multi-relative-margin (${margin.toFixed(2)} of leader=${top.score.toFixed(2)})`;
      rejected.push({ agentId: cand.agentId, score: cand.score, reason });
    }
    return {
      selections: [{ agentId: top.agentId, score: top.score }],
      rejected,
    };
  }

  // Multi mode. Include the runner-up plus any further candidates that also
  // clear the gates, capped at multiMaxAgents.
  const selections: Array<{ agentId: string; score: number }> = [
    { agentId: top.agentId, score: top.score },
  ];
  const rejected: Array<{ agentId: string; score: number; reason: string }> = [];
  for (let i = 1; i < scored.length; i++) {
    const cand = scored[i];
    if (selections.length >= max) {
      rejected.push({ agentId: cand.agentId, score: cand.score, reason: "max-agents-cap" });
      continue;
    }
    if (cand.score < minScoreFloor) {
      rejected.push({
        agentId: cand.agentId,
        score: cand.score,
        reason: `below multi-min-score (${minScoreFloor.toFixed(2)})`,
      });
      continue;
    }
    if (top.score - cand.score > margin) {
      rejected.push({
        agentId: cand.agentId,
        score: cand.score,
        reason: `outside multi-relative-margin (${margin.toFixed(2)} of leader=${top.score.toFixed(2)})`,
      });
      continue;
    }
    selections.push({ agentId: cand.agentId, score: cand.score });
  }
  return { selections, rejected };
}

// ---------------------------------------------------------------------------
// Haiku fallback
// ---------------------------------------------------------------------------

const DEFAULT_CLASSIFIER_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0";
const TOOL_NAME = "route_to_specialists";

let _bedrockClient: BedrockRuntimeClient | null = null;
function getBedrockClient(): BedrockRuntimeClient {
  if (!_bedrockClient) {
    _bedrockClient = new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _bedrockClient;
}

/**
 * Test-only injection point. Lets unit tests swap the Bedrock client used
 * by the Haiku fallback for a fake without mocking `@aws-sdk/client-bedrock-runtime`
 * at the package level (which would bleed across test files in the same Bun spawn).
 * Pass `null` to restore the lazy-init default.
 */
export function _setBedrockClientForTests(client: BedrockRuntimeClient | null): void {
  _bedrockClient = client;
}

function buildToolConfig(agentIds: string[], maxAgents: number): ToolConfiguration {
  return {
    tools: [
      {
        toolSpec: {
          name: TOOL_NAME,
          description:
            "Pick one or more specialist agents best suited to answer this user message. Return ONE agent unless the message clearly requires multiple distinct domains.",
          inputSchema: {
            json: {
              type: "object",
              properties: {
                agentIds: {
                  type: "array",
                  minItems: 1,
                  maxItems: maxAgents,
                  items: {
                    type: "string",
                    enum: agentIds,
                  },
                  description:
                    "Ordered list of specialist agent IDs (most relevant first). Return a single-element array unless the message clearly spans multiple domains.",
                },
                reasoning: {
                  type: "string",
                  description: "One short clause explaining the choice and (if multi-select) why each agent is needed.",
                },
              },
              required: ["agentIds"],
            },
          },
        },
      },
    ],
    toolChoice: { tool: { name: TOOL_NAME } },
  };
}

async function haikuClassifyMulti(
  message: string,
  priorTurns?: ChatMessage[],
): Promise<{ agentIds: string[]; reasoning?: string } | undefined> {
  const candidates = buildCandidates();
  if (candidates.length === 0) return undefined;
  const agentIds = candidates.map((c) => c.agentId);
  const maxAgents = multiMaxAgents();

  const modelId = process.env.CLASSIFIER_MODEL_ID?.trim() || DEFAULT_CLASSIFIER_MODEL_ID;
  const directory = candidates
    .map(
      (c) =>
        `- ${c.agentId}: ${c.label}${c.prompt ? ` — ${c.prompt.replace(/\s+/g, " ").trim()}` : ""}`,
    )
    .join("\n");

  const systemPrompt = `You are a router that picks the best specialist agent(s) for a customer message.
Choose from this list ONLY:
${directory}

Rules:
- Read the message and recent chat context.
- Default to a SINGLE agent. Return one agent unless the message clearly requires multiple distinct domains.
- Examples of single-agent (correct):
    "Track my order ABC-123" → ["order-management"]
    "Recommend a budget gaming laptop" → ["product-recommendation"]
    "Error code PWR-001 won't power on" → ["troubleshooting"]
- Examples of multi-agent (correct):
    "Track my order AND recommend a replacement laptop" → ["order-management", "product-recommendation"]
    "My device shows error PWR-001 and I want to return it" → ["troubleshooting", "order-management"]
- If nothing fits clearly, still pick the closest single match — do NOT make up an agentId.
- Maximum ${maxAgents} agents. Order most-relevant first.
- You MUST call the ${TOOL_NAME} tool exactly once.`;

  const recent = (priorTurns ?? [])
    .slice(-4)
    .map((m) => `${m.role.toUpperCase()}: ${m.content.slice(0, 400)}`)
    .join("\n");
  const inputBlock = recent
    ? `Recent context:\n${recent}\n\nCurrent message:\n${message}`
    : `Current message:\n${message}`;

  const t0 = Date.now();
  try {
    const out = await getBedrockClient().send(
      new ConverseCommand({
        modelId,
        system: [{ text: systemPrompt }],
        messages: [{ role: "user", content: [{ text: inputBlock }] }],
        inferenceConfig: { temperature: 0, maxTokens: 256 },
        toolConfig: buildToolConfig(agentIds, maxAgents),
      }),
    );
    const blocks = out.output?.message?.content ?? [];
    for (const block of blocks) {
      const tu = (block as { toolUse?: { name?: string; input?: unknown } }).toolUse;
      if (tu?.name === TOOL_NAME && tu.input && typeof tu.input === "object") {
        const input = tu.input as { agentIds?: unknown; reasoning?: string };
        const ids = Array.isArray(input.agentIds)
          ? (input.agentIds as unknown[]).filter(
              (s): s is string => typeof s === "string" && agentIds.includes(s),
            )
          : [];
        // De-duplicate while preserving order.
        const seen = new Set<string>();
        const unique: string[] = [];
        for (const id of ids) {
          if (!seen.has(id)) {
            seen.add(id);
            unique.push(id);
          }
        }
        if (unique.length > 0) {
          return {
            agentIds: unique.slice(0, maxAgents),
            reasoning: typeof input.reasoning === "string" ? input.reasoning : undefined,
          };
        }
      }
    }
    logger.warn("[classifier] Haiku returned no usable agentIds", {
      modelId,
      latencyMs: Date.now() - t0,
    });
    return undefined;
  } catch (err) {
    logger.warn("[classifier] Haiku call failed", {
      error: err instanceof Error ? err.message : String(err),
      latencyMs: Date.now() - t0,
    });
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

function snapshotThresholds(): MultiClassificationResult["thresholds"] {
  return {
    multiMinScore: multiMinScore(),
    multiRelativeMargin: multiRelativeMargin(),
    multiMaxAgents: multiMaxAgents(),
    heuristicMinScore: heuristicMinScore(),
    heuristicMargin: heuristicMargin(),
  };
}

/**
 * Multi-select classifier. Returns one or more specialists in ranked order,
 * along with rejected candidates and the threshold snapshot for trace.
 *
 * Returns `undefined` when no candidate fits (caller's fallback path).
 */
export async function classifyAgents(input: {
  message: string;
  priorTurns?: ChatMessage[];
}): Promise<MultiClassificationResult | undefined> {
  const trace = currentTrace();
  const thresholds = snapshotThresholds();
  const cached = cache.get(cacheKey(input.message));
  if (cached) {
    trace?.event("agentcore.classification", {
      inputMessage: input.message.slice(0, 500),
      chosenSpecialist: cached.selections[0]?.agentId,
      reasoning: cached.selections[0]?.reasoning ?? "cache hit",
      latencyMs: 0,
    });
    return {
      selections: cached.selections.map((s) => ({
        agentId: s.agentId,
        reasoning: s.reasoning,
        source: "cache",
      })),
      rejectedCandidates: [],
      thresholds,
    };
  }

  const heuristic = heuristicClassifyMulti(input.message);
  if (heuristic) {
    const reasoning =
      heuristic.selections.length > 1
        ? `heuristic multi-match (top=${heuristic.selections[0].score.toFixed(2)} runnerUp=${heuristic.selections[1].score.toFixed(2)})`
        : `heuristic match (score=${heuristic.selections[0].score.toFixed(2)})`;
    const decisions = heuristic.selections.map((s) => ({
      agentId: s.agentId,
      reasoning,
    }));
    rememberInCache(input.message, { selections: decisions });
    return {
      selections: heuristic.selections.map((s) => ({
        agentId: s.agentId,
        reasoning,
        source: "heuristic",
        score: s.score,
      })),
      rejectedCandidates: heuristic.rejected.map((r) => ({
        agentId: r.agentId,
        score: r.score,
        reason: r.reason,
      })),
      thresholds,
    };
  }

  const backend = process.env.CLASSIFIER_BACKEND?.trim().toLowerCase();
  if (backend === "heuristic") return undefined;

  const haiku = await haikuClassifyMulti(input.message, input.priorTurns);
  if (haiku) {
    const decisions = haiku.agentIds.map((id) => ({
      agentId: id,
      reasoning: haiku.reasoning,
    }));
    rememberInCache(input.message, { selections: decisions });
    return {
      selections: haiku.agentIds.map((id) => ({
        agentId: id,
        reasoning: haiku.reasoning,
        source: "haiku",
      })),
      rejectedCandidates: [],
      thresholds,
    };
  }

  return undefined;
}

/**
 * Compatibility wrapper. Returns the first selection from `classifyAgents`,
 * preserving the original single-result API for any caller that doesn't
 * yet need multi-select semantics.
 */
export async function classifyAgent(input: {
  message: string;
  priorTurns?: ChatMessage[];
}): Promise<ClassificationResult | undefined> {
  const multi = await classifyAgents(input);
  if (!multi || multi.selections.length === 0) return undefined;
  const first = multi.selections[0];
  // The original single-result `score` was only set on heuristic. Preserve
  // that contract so downstream branches that key on `source === "heuristic"`
  // still see a numeric score.
  return {
    agentId: first.agentId,
    reasoning: first.reasoning,
    source: first.source,
    score: first.score,
  };
}

/** Clear classifier decision/candidate caches after a config refresh. */
export function clearAgentClassifierCache(): void {
  cache.clear();
  _candidatesCache = null;
  _candidatesAgentVersion = undefined;
}

/** Test-only: clear caches between runs. */
export function resetAgentClassifierCacheForTests(): void {
  clearAgentClassifierCache();
  _bedrockClient = null;
}
