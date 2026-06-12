/**
 * Orchestrator clarification reply.
 *
 * When the front-door classifier abstains (vague / low-signal message), the
 * orchestrator must ask the customer to clarify rather than force-routing to a
 * specialist (which would answer with the wrong domain's content). The
 * orchestrator persona is a router with no skills/tools, so this helper produces
 * a short, domain-agnostic clarifying question that lists the available
 * specialist domains.
 *
 * Reliability contract: this helper ALWAYS yields a sensible clarification.
 *   1. Primary: one short Bedrock `ConverseCommand` using the orchestrator's
 *      configured model + a focused system prompt.
 *   2. Fallback: if the model call throws, times out, or returns empty text, a
 *      deterministic template built from the specialist roster is emitted.
 *
 * It deliberately does NOT reuse the full Swarm (`runSwarmChatStream`) — the
 * Swarm can re-route to a specialist, but here we want a guaranteed
 * orchestrator-only reply.
 */

import { BedrockRuntimeClient, ConverseCommand } from "@aws-sdk/client-bedrock-runtime";
import { getAgent, listAgents } from "./config-scan.ts";
import type { ChatMessage } from "./session-store.ts";
import type { ChatStreamPart } from "./chat-stream-types.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";

const DEFAULT_CLARIFY_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0";

let _bedrockClient: BedrockRuntimeClient | null = null;
function getBedrockClient(): BedrockRuntimeClient {
  if (!_bedrockClient) {
    _bedrockClient = new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _bedrockClient;
}

/**
 * Test-only injection point. Mirrors `agent-classifier._setBedrockClientForTests`.
 * Pass `null` to restore the lazy-init default.
 */
export function _setBedrockClientForTests(client: BedrockRuntimeClient | null): void {
  _bedrockClient = client;
}

type RosterEntry = { name: string; description: string };

/**
 * Build the routable specialist roster (name + a short capability blurb) from
 * the orchestrator's generated handoffs, falling back to the raw agent list.
 */
function buildRoster(): RosterEntry[] {
  const orchestrator = getAgent("orchestrator");
  const handoffs = orchestrator?.handoffs ?? [];
  if (handoffs.length > 0) {
    return handoffs.map((h) => {
      const meta = getAgent(h.agent);
      const description = (meta?.description ?? h.prompt ?? "").replace(/\s+/g, " ").trim();
      return { name: meta?.name ?? h.label ?? h.agent, description };
    });
  }
  return listAgents()
    .filter((a) => a.id !== "orchestrator")
    .map((a) => ({ name: a.name, description: (a.description ?? "").replace(/\s+/g, " ").trim() }));
}

/** Human-readable "A, B, or C" list of specialist domains. */
function rosterNamesPhrase(roster: RosterEntry[]): string {
  const names = roster.map((r) => r.name).filter(Boolean);
  if (names.length === 0) return "a few different areas";
  if (names.length === 1) return names[0];
  if (names.length === 2) return `${names[0]} or ${names[1]}`;
  return `${names.slice(0, -1).join(", ")}, or ${names[names.length - 1]}`;
}

/**
 * Deterministic clarification used as the guaranteed fallback. Built purely
 * from config, so it is always available even with Bedrock unreachable.
 */
export function buildClarificationTemplate(roster: RosterEntry[]): string {
  return (
    `I can help with ${rosterNamesPhrase(roster)}. ` +
    `Could you tell me a bit more about what you need so I can point you to the right place?`
  );
}

function buildSystemPrompt(roster: RosterEntry[]): string {
  const directory = roster
    .map((r) => `- ${r.name}${r.description ? `: ${r.description}` : ""}`)
    .join("\n");
  return `You are the front-door orchestrator for a customer support assistant. The customer's latest message is too vague to route to a specialist.

Your ONLY job right now is to ask one brief, friendly clarifying question so you can later route them to the right specialist. The specialist areas available are:
${directory}

Rules:
- Respond in 1-2 short sentences.
- Briefly mention the kinds of things you can help with (the specialist areas above), then ask what they need.
- Do NOT answer any domain-specific question or invent order, product, or support details — you have no tools or data.
- Do NOT mention agents, routing, classifiers, or internal mechanics.
- Output only the message to the customer (no preamble).`;
}

function packInput(userMessage: string, priorTurns?: ChatMessage[]): string {
  const recent = (priorTurns ?? [])
    .slice(-4)
    .map((m) => `${m.role.toUpperCase()}: ${m.content.slice(0, 400)}`)
    .join("\n");
  return recent
    ? `Recent context:\n${recent}\n\nCurrent message:\n${userMessage}`
    : `Current message:\n${userMessage}`;
}

/**
 * Stream an orchestrator clarification reply for a vague message.
 *
 * Emits one or more `{ type: "token" }` parts. Always yields a non-empty
 * clarification (model output, or the deterministic template on failure).
 */
export async function* runOrchestratorClarification(params: {
  userMessage: string;
  priorTurns?: ChatMessage[];
  memoryContext?: string;
}): AsyncGenerator<ChatStreamPart> {
  const trace = currentTrace();
  const roster = buildRoster();
  const template = buildClarificationTemplate(roster);
  const modelId = getAgent("orchestrator")?.model?.trim() || DEFAULT_CLARIFY_MODEL_ID;

  const t0 = Date.now();
  let reply = "";
  let source: "model" | "template" = "model";

  try {
    const out = await getBedrockClient().send(
      new ConverseCommand({
        modelId,
        system: [{ text: buildSystemPrompt(roster) }],
        messages: [{ role: "user", content: [{ text: packInput(params.userMessage, params.priorTurns) }] }],
        inferenceConfig: { temperature: 0.3, maxTokens: 256 },
      }),
    );
    const blocks = out.output?.message?.content ?? [];
    reply = blocks
      .map((b) => (b as { text?: string }).text ?? "")
      .join("")
      .trim();
  } catch (err) {
    logger.warn("[orchestrator-clarify] model call failed; using template", {
      modelId,
      error: err instanceof Error ? err.message : String(err),
      latencyMs: Date.now() - t0,
    });
  }

  if (!reply) {
    reply = template;
    source = "template";
  }

  trace?.event("orchestrator.clarification", {
    inputMessage: params.userMessage.slice(0, 500),
    source,
    roster: roster.map((r) => r.name),
    outputBytes: Buffer.byteLength(reply, "utf8"),
    latencyMs: Date.now() - t0,
  });

  yield { type: "token", text: reply };
}
