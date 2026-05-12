import { type JSONValue, Message, type ToolUseBlock } from "@strands-agents/sdk";
import type { ToolChoice, ToolSpec } from "@strands-agents/sdk";
import { Model, type BaseModelConfig, type StreamOptions } from "@strands-agents/sdk";
import type { ModelStreamEvent } from "@strands-agents/sdk";

export type DevMockModelConfig = BaseModelConfig & {
  agentId: string;
};

let toolUseSeq = 0;
function nextToolUseId(): string {
  toolUseSeq += 1;
  return `devmock-tool-${toolUseSeq}`;
}

function log(msg: string, data?: Record<string, unknown>): void {
  if (data) console.log(`[DevMockModel] ${msg}`, data);
  else console.log(`[DevMockModel] ${msg}`);
}

function extractUserTextFromMessage(m: Message): string {
  const parts: string[] = [];
  for (const block of m.content) {
    if (block.type === "textBlock") {
      parts.push(block.text);
    }
  }
  return parts.join("\n").trim();
}

/** Last user message text (may include handoff instructions from Swarm). */
export function extractLatestUserText(messages: Message[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.role === "user") {
      return extractUserTextFromMessage(m);
    }
  }
  return "";
}

function lastUserMessageHasToolResults(messages: Message[]): boolean {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.role !== "user") continue;
    return m.content.some((b) => b.type === "toolResultBlock");
  }
  return false;
}

function collectToolResultPreview(messages: Message[]): string {
  const previews: string[] = [];
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.role !== "user") break;
    for (const block of m.content) {
      if (block.type !== "toolResultBlock") continue;
      for (const c of block.content) {
        if (c.type === "textBlock") previews.push(c.text);
        else if (c.type === "jsonBlock") previews.push(JSON.stringify(c.json));
      }
    }
  }
  return previews.join("\n").slice(0, 4000);
}

function toolSpecNames(toolSpecs: ToolSpec[] | undefined): Set<string> {
  return new Set((toolSpecs ?? []).map((t) => t.name));
}

function wantsMongoOrderQuery(userText: string): boolean {
  return /\b(order|orders|ORD-|tracking|shipment)\b/i.test(userText);
}

function wantsProductRecommend(userText: string): boolean {
  return /\b(recommend|product|similar|widget|gadget|sku|catalog|buy|for my home|which one)\b/i.test(
    userText,
  );
}

function wantsTroubleshootingQuery(userText: string): boolean {
  return /\b(fix|broken|error|issue|troubleshoot|not working|power|device|help|won't|wont|cable)\b/i.test(
    userText,
  );
}

function buildMongoOrderInput(userText: string): JSONValue {
  const idMatch = userText.match(/\bORD-[A-Z0-9_-]+\b/i);
  if (idMatch) {
    return {
      collection: "orders",
      operation: "find",
      query: { orderId: idMatch[0]!.toUpperCase() },
      limit: 5,
    };
  }
  return {
    collection: "orders",
    operation: "find",
    query: {},
    limit: 5,
  };
}

function routeOrchestratorHandoff(userText: string): { agentId?: string; message: string } {
  const t = userText.toLowerCase();
  if (/\b(order|orders|ord-|tracking|shipment|delivery)\b/i.test(userText)) {
    return {
      agentId: "order-management",
      message: `Hand off: customer order question. User said: ${userText.slice(0, 500)}`,
    };
  }
  if (/\b(product|recommend|compare|which\s+one|buy)\b/i.test(t)) {
    return {
      agentId: "product-recommendation",
      message: `Hand off: product guidance. User said: ${userText.slice(0, 500)}`,
    };
  }
  if (/\b(fix|broken|error|issue|troubleshoot|not working|help)\b/i.test(t)) {
    return {
      agentId: "troubleshooting",
      message: `Hand off: troubleshooting. User said: ${userText.slice(0, 500)}`,
    };
  }
  return {
    message:
      "Thanks — I can help with orders, product recommendations, or troubleshooting. " +
      "Tell me which you need, or share an order id (e.g. ORD-1001).",
  };
}

function* emitToolUseStream(name: string, toolUseId: string, input: JSONValue): Generator<ModelStreamEvent> {
  yield { type: "modelMessageStartEvent", role: "assistant" };
  yield {
    type: "modelContentBlockStartEvent",
    start: { type: "toolUseStart", name, toolUseId },
  };
  yield {
    type: "modelContentBlockDeltaEvent",
    delta: { type: "toolUseInputDelta", input: JSON.stringify(input) },
  };
  yield { type: "modelContentBlockStopEvent" };
  yield { type: "modelMessageStopEvent", stopReason: "toolUse" };
}

function* emitTextStream(text: string, stopReason: "endTurn" | "toolUse" = "endTurn"): Generator<ModelStreamEvent> {
  yield { type: "modelMessageStartEvent", role: "assistant" };
  yield { type: "modelContentBlockStartEvent" };
  yield {
    type: "modelContentBlockDeltaEvent",
    delta: { type: "textDelta", text },
  };
  yield { type: "modelContentBlockStopEvent" };
  yield { type: "modelMessageStopEvent", stopReason };
}

function findPendingToolUse(messages: Message[], toolName: string): ToolUseBlock | undefined {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.role !== "assistant") continue;
    for (const block of m.content) {
      if (block.type === "toolUseBlock" && block.name === toolName) {
        return block;
      }
    }
  }
  return undefined;
}

function toolResultForUse(messages: Message[], toolUseId: string): boolean {
  for (const m of messages) {
    if (m.role !== "user") continue;
    for (const block of m.content) {
      if (block.type === "toolResultBlock" && block.toolUseId === toolUseId) return true;
    }
  }
  return false;
}

/**
 * Deterministic Strands `Model` for local dev: tool-use and Swarm structured-output paths
 * without Bedrock.
 */
export class DevMockModel extends Model<DevMockModelConfig> {
  private _config: DevMockModelConfig;

  constructor(config: DevMockModelConfig) {
    super();
    this._config = {
      modelId: config.modelId ?? "dev-mock-model",
      maxTokens: config.maxTokens,
      temperature: config.temperature,
      agentId: config.agentId,
    };
  }

  updateConfig(modelConfig: DevMockModelConfig): void {
    this._config = { ...this._config, ...modelConfig };
  }

  getConfig(): DevMockModelConfig {
    return { ...this._config };
  }

  async *stream(messages: Message[], options?: StreamOptions): AsyncIterable<ModelStreamEvent> {
    const agentId = this._config.agentId;
    const userText = extractLatestUserText(messages);
    const names = toolSpecNames(options?.toolSpecs);
    const toolChoice = options?.toolChoice as ToolChoice | undefined;
    const structured = names.has("strands_structured_output");

    log("stream turn", { agentId, hasStructured: structured, userPreview: userText.slice(0, 120) });

    const forcedName =
      toolChoice && "tool" in toolChoice && toolChoice.tool?.name ? toolChoice.tool.name : undefined;

    if (forcedName === "strands_structured_output") {
      const payload = structuredPayloadFor(agentId, userText, messages, true);
      log("forced structured output", payload as Record<string, unknown>);
      yield* emitToolUseStream("strands_structured_output", nextToolUseId(), payload);
      return;
    }

    if (structured) {
      if (lastUserMessageHasToolResults(messages)) {
        const preview = collectToolResultPreview(messages);
        // Swarm re-invokes the model after tool results; another strands_structured_output
        // would loop forever — finish with plain text for every agent role.
        log("text after tool results (dev mock)", { agentId });
        const text =
          agentId === "orchestrator"
            ? `[DevMockModel] Routing context: ${preview.slice(0, 2000)}`
            : `[DevMockModel] Summary (${agentId}): ${preview.slice(0, 2000)}`;
        yield* emitTextStream(text);
        return;
      }

      if (agentId === "orchestrator") {
        const route = routeOrchestratorHandoff(userText);
        const payload: JSONValue = {
          ...(route.agentId ? { agentId: route.agentId } : {}),
          message: route.message,
        };
        log("orchestrator handoff", payload as Record<string, unknown>);
        yield* emitToolUseStream("strands_structured_output", nextToolUseId(), payload);
        return;
      }

      if (
        agentId === "product-recommendation" &&
        names.has("mongodb_vector_search") &&
        wantsProductRecommend(userText)
      ) {
        const pending = findPendingToolUse(messages, "mongodb_vector_search");
        if (!pending || !toolResultForUse(messages, pending.toolUseId)) {
          const input: JSONValue = {
            collection: "products",
            queryText: userText,
            indexName: "products-dev-mock",
            limit: 5,
          };
          log("mongodb_vector_search (structured)", input as Record<string, unknown>);
          yield* emitToolUseStream("mongodb_vector_search", nextToolUseId(), input);
          return;
        }
      }

      if (
        agentId === "troubleshooting" &&
        names.has("bedrock_kb_retrieve") &&
        wantsTroubleshootingQuery(userText)
      ) {
        const pending = findPendingToolUse(messages, "bedrock_kb_retrieve");
        if (!pending || !toolResultForUse(messages, pending.toolUseId)) {
          const input: JSONValue = {
            query: userText.slice(0, 500),
            knowledgeBaseId: "dev-mock-kb",
            numberOfResults: 5,
          };
          log("bedrock_kb_retrieve (structured)", { queryPreview: userText.slice(0, 80) });
          yield* emitToolUseStream("bedrock_kb_retrieve", nextToolUseId(), input);
          return;
        }
      }

      if (names.has("mongodb_query") && wantsMongoOrderQuery(userText)) {
        const pending = findPendingToolUse(messages, "mongodb_query");
        if (!pending || !toolResultForUse(messages, pending.toolUseId)) {
          const input = buildMongoOrderInput(userText);
          log("mongodb_query tool use", input as Record<string, unknown>);
          yield* emitToolUseStream("mongodb_query", nextToolUseId(), input);
          return;
        }
      }

      const payload = structuredPayloadFor(agentId, userText, messages, false);
      log("structured fallback", payload as Record<string, unknown>);
      yield* emitToolUseStream("strands_structured_output", nextToolUseId(), payload);
      return;
    }

    // Single-agent path (no Swarm structured tool)
    if (
      agentId === "product-recommendation" &&
      names.has("mongodb_vector_search") &&
      wantsProductRecommend(userText)
    ) {
      const pending = findPendingToolUse(messages, "mongodb_vector_search");
      if (!pending || !toolResultForUse(messages, pending.toolUseId)) {
        const input: JSONValue = {
          collection: "products",
          queryText: userText,
          indexName: "products-dev-mock",
          limit: 5,
        };
        log("mongodb_vector_search (single agent)", input as Record<string, unknown>);
        yield* emitToolUseStream("mongodb_vector_search", nextToolUseId(), input);
        return;
      }
    }

    if (
      agentId === "troubleshooting" &&
      names.has("bedrock_kb_retrieve") &&
      wantsTroubleshootingQuery(userText)
    ) {
      const pending = findPendingToolUse(messages, "bedrock_kb_retrieve");
      if (!pending || !toolResultForUse(messages, pending.toolUseId)) {
        const input: JSONValue = {
          query: userText.slice(0, 500),
          knowledgeBaseId: "dev-mock-kb",
          numberOfResults: 5,
        };
        log("bedrock_kb_retrieve (single agent)", { queryPreview: userText.slice(0, 80) });
        yield* emitToolUseStream("bedrock_kb_retrieve", nextToolUseId(), input);
        return;
      }
    }

    if (names.has("mongodb_query") && wantsMongoOrderQuery(userText)) {
      const pending = findPendingToolUse(messages, "mongodb_query");
      if (!pending || !toolResultForUse(messages, pending.toolUseId)) {
        const input = buildMongoOrderInput(userText);
        log("mongodb_query (single agent)", input as Record<string, unknown>);
        yield* emitToolUseStream("mongodb_query", nextToolUseId(), input);
        return;
      }
    }

    if (lastUserMessageHasToolResults(messages)) {
      const preview = collectToolResultPreview(messages);
      const text = `[DevMockModel] Here is what the tools returned (abbreviated):\n${preview.slice(0, 2000)}`;
      yield* emitTextStream(text);
      return;
    }

    yield* emitTextStream(
      `[DevMockModel] (${agentId}) Echo: ${userText.slice(0, 500) || "(empty user message)"}`,
    );
  }
}

function structuredPayloadFor(
  agentId: string,
  userText: string,
  messages: Message[],
  forced: boolean,
): JSONValue {
  if (agentId === "orchestrator") {
    return routeOrchestratorHandoff(userText) as JSONValue;
  }
  if (lastUserMessageHasToolResults(messages)) {
    return {
      message: `Done (dev mock). Tool data: ${collectToolResultPreview(messages).slice(0, 1200)}`,
    };
  }
  if (forced) {
    return {
      message: "Structured output retry (dev mock): please continue with the user request.",
    };
  }
  return { message: `Acknowledged (${agentId}, dev mock): ${userText.slice(0, 400)}` };
}
