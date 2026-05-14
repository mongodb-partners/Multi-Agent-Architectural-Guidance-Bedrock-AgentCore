/**
 * LLM-driven long-term fact extractor.
 *
 * Decides which snippets of a user message should be stored in
 * `agent_memory_facts` by calling Amazon Bedrock with a small,
 * tool-forced JSON output schema. This is the only extractor — there
 * is no regex fallback. When this call fails, `writeLongTermMemory`
 * skips the write entirely and emits `memory.long_term_skip` with
 * `reason: "llm_extractor_failed"`.
 *
 * Returns an `accepted` list of fact strings (in the user's original
 * wording) plus a `considered` audit trail in a `FactCandidate` shape
 * the trace viewer renders.
 */

import {
  BedrockRuntimeClient,
  ConverseCommand,
  type ConverseCommandOutput,
  type Message as BedrockMessage,
  type ToolConfiguration,
} from "@aws-sdk/client-bedrock-runtime";

export type FactCategory =
  | "identity"
  | "preference"
  | "contact"
  | "address"
  | "order_id"
  | "device"
  | "other";

/**
 * Audit shape for a single line considered by the extractor.
 * Surfaces in `memory.long_term_write` trace events.
 */
export type FactCandidate = {
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
};

// Bedrock cross-region inference profile for Claude Haiku 4.5.
// Picked because (a) it is enabled by default on freshly granted Bedrock
// accounts in us-* regions, whereas the previous default
// `us.anthropic.claude-3-5-haiku-20241022-v1:0` is now deprecated and silently
// AccessDenied on new accounts (Marketplace subscription verification fails),
// and (b) Haiku 4.5 is materially cheaper + faster while still supporting the
// `record_facts` tool-use schema this extractor requires.
// Override via `MEMORY_EXTRACTION_MODEL_ID` env var if you've enabled a
// different extraction model in your account.
export const DEFAULT_LLM_EXTRACTOR_MODEL_ID =
  "us.anthropic.claude-haiku-4-5-20251001-v1:0";

const MAX_FACT_LEN = 220;
const MIN_FACT_LEN = 8;
const MAX_USER_MESSAGE_CHARS = 2000;
const TOOL_NAME = "record_facts";

let _runtimeClient: BedrockRuntimeClient | null = null;

function getBedrockClient(): BedrockRuntimeClient {
  if (!_runtimeClient) {
    const region = process.env.AWS_REGION?.trim() || "us-east-1";
    _runtimeClient = new BedrockRuntimeClient({ region });
  }
  return _runtimeClient;
}

/** Reset the cached Bedrock client (test isolation). */
export function resetLlmFactExtractorClientForTests(): void {
  _runtimeClient = null;
}

export type LlmExtractorOpts = {
  modelId?: string;
  maxFacts?: number;
};

export type LlmExtractorResult = {
  accepted: string[];
  considered: FactCandidate[];
  modelId: string;
  latencyMs: number;
  inputTokens?: number;
  outputTokens?: number;
};

const SYSTEM_PROMPT = `You decide which snippets from a user message should be stored as long-term personal facts about the user.

Store as facts:
- Identity (name, role, occupation)
- Preferences ("I prefer dark mode", "I like email contact")
- Contact details (email, phone, mailing address)
- Account / order / device IDs the user mentions about themselves
- Durable choices and ownership ("I drive a 2019 Civic", "ship to 221B Baker St")

DO NOT store:
- Greetings ("hi", "thanks")
- Questions ("what is my order status?", "can you help me")
- Ephemeral statements ("I need help today", "this is broken")
- General chitchat or weather
- Anything that is not specifically about the user as a person

Use the user's ORIGINAL wording — do not paraphrase. Each fact must be ${MIN_FACT_LEN}-${MAX_FACT_LEN} characters.

Return at most {{MAX_FACTS}} facts. If none qualify, return an empty list.

You MUST respond by calling the ${TOOL_NAME} tool exactly once.`;

const FEW_SHOT = `Examples (input → tool call):

INPUT: "hi there, my email is alice@example.com and I prefer dark roast coffee"
TOOL: { "facts": [
  { "text": "my email is alice@example.com", "category": "contact", "reason": "user-provided email address" },
  { "text": "I prefer dark roast coffee", "category": "preference", "reason": "stated preference" }
], "ignored": [{ "text": "hi there", "reason": "greeting" }] }

INPUT: "what is the status of my order?"
TOOL: { "facts": [], "ignored": [{ "text": "what is the status of my order?", "reason": "question, not a stored fact" }] }

INPUT: "I drive a 2019 Honda Civic and ship to 221B Baker St"
TOOL: { "facts": [
  { "text": "I drive a 2019 Honda Civic", "category": "device", "reason": "vehicle owned" },
  { "text": "ship to 221B Baker St", "category": "address", "reason": "shipping address" }
], "ignored": [] }`;

function buildToolConfig(maxFacts: number): ToolConfiguration {
  return {
    tools: [
      {
        toolSpec: {
          name: TOOL_NAME,
          description:
            "Record the long-term facts to remember about the user from this message.",
          inputSchema: {
            json: {
              type: "object",
              properties: {
                facts: {
                  type: "array",
                  maxItems: maxFacts,
                  items: {
                    type: "object",
                    properties: {
                      text: {
                        type: "string",
                        description:
                          "The fact in the user's original wording (8-220 chars).",
                      },
                      category: {
                        type: "string",
                        enum: [
                          "identity",
                          "preference",
                          "contact",
                          "address",
                          "order_id",
                          "device",
                          "other",
                        ],
                      },
                      reason: {
                        type: "string",
                        description:
                          "One short clause explaining why this is a long-term fact.",
                      },
                    },
                    required: ["text", "category"],
                  },
                },
                ignored: {
                  type: "array",
                  items: {
                    type: "object",
                    properties: {
                      text: { type: "string" },
                      reason: {
                        type: "string",
                        description:
                          "Why this snippet is not a long-term fact.",
                      },
                    },
                    required: ["text", "reason"],
                  },
                },
              },
              required: ["facts"],
            },
          },
        },
      },
    ],
    toolChoice: { tool: { name: TOOL_NAME } },
  };
}

type ToolReply = {
  facts?: Array<{ text?: unknown; category?: unknown; reason?: unknown }>;
  ignored?: Array<{ text?: unknown; reason?: unknown }>;
};

function parseToolUseFromConverse(out: ConverseCommandOutput): ToolReply | null {
  const content = out.output?.message?.content ?? [];
  for (const block of content) {
    const tu = (block as { toolUse?: { name?: string; input?: unknown } }).toolUse;
    if (tu?.name === TOOL_NAME && tu.input && typeof tu.input === "object") {
      return tu.input as ToolReply;
    }
  }
  return null;
}

/**
 * Call Bedrock with a tool-forced schema and map the reply into a
 * `{ accepted, considered }` shape compatible with the regex extractor.
 *
 * Throws on Bedrock error / missing tool call. The caller is expected
 * to fall back to the regex extractor on any thrown exception.
 */
export async function extractFactsWithLlm(
  userMessage: string,
  opts: LlmExtractorOpts = {},
): Promise<LlmExtractorResult> {
  const modelId =
    opts.modelId?.trim() ||
    process.env.MEMORY_EXTRACTION_MODEL_ID?.trim() ||
    DEFAULT_LLM_EXTRACTOR_MODEL_ID;
  const maxFacts = Math.max(
    1,
    opts.maxFacts ?? Number(process.env.MEMORY_EXTRACTION_MAX_FACTS ?? 6),
  );
  const message = userMessage.slice(0, MAX_USER_MESSAGE_CHARS);
  const t0 = Date.now();

  const messages: BedrockMessage[] = [
    {
      role: "user",
      content: [
        {
          text: `${FEW_SHOT}\n\nNow decide for this user message:\n\nINPUT: ${JSON.stringify(message)}`,
        },
      ],
    },
  ];

  const cmd = new ConverseCommand({
    modelId,
    messages,
    system: [{ text: SYSTEM_PROMPT.replace("{{MAX_FACTS}}", String(maxFacts)) }],
    inferenceConfig: { temperature: 0, maxTokens: 1024 },
    toolConfig: buildToolConfig(maxFacts),
  });

  const out = await getBedrockClient().send(cmd);
  const latencyMs = Date.now() - t0;
  const reply = parseToolUseFromConverse(out);
  if (!reply) {
    throw new Error(
      `Bedrock ${modelId} returned no ${TOOL_NAME} tool use; cannot extract facts.`,
    );
  }

  const considered: FactCandidate[] = [];
  const accepted: string[] = [];
  const seen = new Set<string>();

  const facts = (reply.facts ?? [])
    .map((f) => ({
      text: typeof f.text === "string" ? f.text.trim() : "",
      category: typeof f.category === "string" ? f.category : "other",
      reason: typeof f.reason === "string" ? f.reason : undefined,
    }))
    .filter((f) => f.text.length > 0);

  for (const f of facts) {
    if (accepted.length >= maxFacts) break;
    if (f.text.length < MIN_FACT_LEN) {
      considered.push({
        text: f.text,
        matched: false,
        rejectedReason: "too_short",
        length: f.text.length,
        category: f.category,
        note: f.reason,
      });
      continue;
    }
    if (f.text.length > MAX_FACT_LEN) {
      considered.push({
        text: f.text,
        matched: false,
        rejectedReason: "too_long",
        length: f.text.length,
        category: f.category,
        note: f.reason,
      });
      continue;
    }
    const k = f.text.toLowerCase();
    if (seen.has(k)) {
      considered.push({
        text: f.text,
        matched: true,
        matchedPatterns: [f.category],
        rejectedReason: "duplicate",
        length: f.text.length,
        category: f.category,
        note: f.reason,
      });
      continue;
    }
    seen.add(k);
    accepted.push(f.text);
    considered.push({
      text: f.text,
      matched: true,
      matchedPatterns: [f.category],
      length: f.text.length,
      category: f.category,
      note: f.reason,
    });
  }

  for (const ig of reply.ignored ?? []) {
    const text = typeof ig.text === "string" ? ig.text.trim() : "";
    if (!text) continue;
    const reason = typeof ig.reason === "string" ? ig.reason : "rejected by llm";
    considered.push({
      text,
      matched: false,
      rejectedReason: "llm_rejected",
      length: text.length,
      note: reason,
    });
  }

  return {
    accepted,
    considered,
    modelId,
    latencyMs,
    inputTokens: out.usage?.inputTokens,
    outputTokens: out.usage?.outputTokens,
  };
}
