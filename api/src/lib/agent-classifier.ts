/**
 * Front-door agent classifier.
 *
 * Picks a specialist `agentId` for a user message without paying the cost of
 * a full orchestrator runtime turn. Two backends, in order:
 *
 *   1. Heuristic — token-overlap scoring of the user message against each
 *      agent's `description`, `handoffs[].label`, and `handoffs[].prompt`
 *      (drawn from the orchestrator's frontmatter). Sub-millisecond, no
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

export type ClassificationResult = {
  agentId: string;
  reasoning?: string;
  source: "heuristic" | "haiku" | "cache";
  /** Top heuristic score for the chosen agent (when available). */
  score?: number;
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
const CACHE_MAX_ENTRIES = 256;

type CachedDecision = { agentId: string; reasoning?: string };
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
 * Build the candidate index from the orchestrator's `handoffs` frontmatter.
 * Any agent that is in the orchestrator's list of allowed handoffs (and that
 * has a configured runtime ARN env var) is a routable specialist.
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
    .map((a) => a.id)
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

function heuristicClassify(message: string): { agentId: string; score: number; runnerUp: number } | undefined {
  const candidates = buildCandidates();
  if (candidates.length === 0) return undefined;

  const tokens = tokenize(message);
  const tokenSet = new Set(tokens);
  const bigramSet = new Set(bigramsOf(tokens));

  const scored = candidates
    .map((c) => ({ agentId: c.agentId, score: heuristicScore(tokenSet, bigramSet, c) }))
    .sort((a, b) => b.score - a.score);

  const top = scored[0];
  const second = scored[1]?.score ?? 0;
  if (!top || top.score < heuristicMinScore()) return undefined;
  if (top.score - second < heuristicMargin()) return undefined;
  return { agentId: top.agentId, score: top.score, runnerUp: second };
}

// ---------------------------------------------------------------------------
// Haiku fallback
// ---------------------------------------------------------------------------

const DEFAULT_CLASSIFIER_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0";
const TOOL_NAME = "route_to_specialist";

let _bedrockClient: BedrockRuntimeClient | null = null;
function getBedrockClient(): BedrockRuntimeClient {
  if (!_bedrockClient) {
    _bedrockClient = new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _bedrockClient;
}

function buildToolConfig(agentIds: string[]): ToolConfiguration {
  return {
    tools: [
      {
        toolSpec: {
          name: TOOL_NAME,
          description: "Pick the specialist agent best suited to answer this user message.",
          inputSchema: {
            json: {
              type: "object",
              properties: {
                agentId: {
                  type: "string",
                  enum: agentIds,
                  description: "ID of the chosen specialist agent.",
                },
                reasoning: {
                  type: "string",
                  description: "One short clause explaining the choice.",
                },
              },
              required: ["agentId"],
            },
          },
        },
      },
    ],
    toolChoice: { tool: { name: TOOL_NAME } },
  };
}

async function haikuClassify(
  message: string,
  priorTurns?: ChatMessage[],
): Promise<{ agentId: string; reasoning?: string } | undefined> {
  const candidates = buildCandidates();
  if (candidates.length === 0) return undefined;
  const agentIds = candidates.map((c) => c.agentId);

  const modelId = process.env.CLASSIFIER_MODEL_ID?.trim() || DEFAULT_CLASSIFIER_MODEL_ID;
  const directory = candidates
    .map(
      (c) =>
        `- ${c.agentId}: ${c.label}${c.prompt ? ` — ${c.prompt.replace(/\s+/g, " ").trim()}` : ""}`,
    )
    .join("\n");

  const systemPrompt = `You are a router that picks the single best specialist agent for a customer message.
Choose from this list ONLY:
${directory}

Rules:
- Read the message and recent chat context.
- Pick the agent whose label and prompt best match the user's intent.
- If nothing fits clearly, still pick the closest match — do NOT make up an agentId.
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
        toolConfig: buildToolConfig(agentIds),
      }),
    );
    const blocks = out.output?.message?.content ?? [];
    for (const block of blocks) {
      const tu = (block as { toolUse?: { name?: string; input?: unknown } }).toolUse;
      if (tu?.name === TOOL_NAME && tu.input && typeof tu.input === "object") {
        const input = tu.input as { agentId?: string; reasoning?: string };
        if (typeof input.agentId === "string" && agentIds.includes(input.agentId)) {
          return {
            agentId: input.agentId,
            reasoning: typeof input.reasoning === "string" ? input.reasoning : undefined,
          };
        }
      }
    }
    logger.warn("[classifier] Haiku returned no usable agentId", {
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

export async function classifyAgent(input: {
  message: string;
  priorTurns?: ChatMessage[];
}): Promise<ClassificationResult | undefined> {
  const trace = currentTrace();
  const cached = cache.get(cacheKey(input.message));
  if (cached) {
    trace?.event("agentcore.classification", {
      inputMessage: input.message.slice(0, 500),
      chosenSpecialist: cached.agentId,
      reasoning: cached.reasoning ?? "cache hit",
      latencyMs: 0,
    });
    return { agentId: cached.agentId, reasoning: cached.reasoning, source: "cache" };
  }

  const heuristic = heuristicClassify(input.message);
  if (heuristic) {
    rememberInCache(input.message, { agentId: heuristic.agentId, reasoning: "heuristic match" });
    return {
      agentId: heuristic.agentId,
      reasoning: `heuristic match (score=${heuristic.score.toFixed(2)} runnerUp=${heuristic.runnerUp.toFixed(2)})`,
      source: "heuristic",
      score: heuristic.score,
    };
  }

  const backend = process.env.CLASSIFIER_BACKEND?.trim().toLowerCase();
  if (backend === "heuristic") return undefined;

  const haiku = await haikuClassify(input.message, input.priorTurns);
  if (haiku) {
    rememberInCache(input.message, haiku);
    return { agentId: haiku.agentId, reasoning: haiku.reasoning, source: "haiku" };
  }
  return undefined;
}

/** Test-only: clear caches between runs. */
export function resetAgentClassifierCacheForTests(): void {
  cache.clear();
  _candidatesCache = null;
  _candidatesAgentVersion = undefined;
  _bedrockClient = null;
}
