import {
  BedrockAgentCoreClient,
  CreateEventCommand,
  ListEventsCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import type { ChatMessage } from "./session-store.ts";
import { logger } from "./logger.ts";

function shortTermBackend(): string {
  return (process.env.SHORT_TERM_MEMORY_BACKEND ?? "").trim().toLowerCase();
}

function memoryId(): string | undefined {
  return process.env.AGENTCORE_MEMORY_STORE_ID?.trim() || undefined;
}

export function useAgentcoreShortTermMemory(userId?: string): boolean {
  // Short-term memory in AgentCore requires a stable actor identity.
  if (!userId) return false;
  return shortTermBackend() === "agentcore" && !!memoryId();
}

let client: BedrockAgentCoreClient | null = null;
function getClient(): BedrockAgentCoreClient {
  if (!client) {
    client = new BedrockAgentCoreClient({
      region: process.env.AWS_REGION ?? "us-east-1",
    });
  }
  return client;
}

function asChatMessagesFromEvents(
  sessionId: string,
  events: Array<{
    eventTimestamp?: Date;
    payload?: Array<{ conversational?: { role?: string; content?: { text?: string } } }>;
    metadata?: { agentId?: { stringValue?: string } };
  }>,
): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (const ev of events) {
    const ts = ev.eventTimestamp?.toISOString() ?? new Date().toISOString();
    for (const payload of ev.payload ?? []) {
      const conv = payload.conversational;
      if (!conv) continue;
      if (conv.role === "USER") {
        out.push({
          id: `msg_${crypto.randomUUID().slice(0, 12)}`,
          role: "user",
          content: conv.content?.text ?? "",
          timestamp: ts,
        });
      } else if (conv.role === "ASSISTANT") {
        out.push({
          id: `msg_${crypto.randomUUID().slice(0, 12)}`,
          role: "assistant",
          content: conv.content?.text ?? "",
          timestamp: ts,
          agentId: typeof ev.metadata?.agentId?.stringValue === "string"
            ? ev.metadata.agentId.stringValue
            : undefined,
        });
      }
    }
  }
  // Keep deterministic order for prompt replay.
  out.sort((a, b) => (a.timestamp < b.timestamp ? -1 : a.timestamp > b.timestamp ? 1 : 0));
  return out;
}

export async function readShortTermMessages(
  sessionId: string,
  userId: string,
  limit = 40,
): Promise<ChatMessage[]> {
  const memId = memoryId();
  if (!memId) return [];
  const c = getClient();
  const res = await c.send(
    new ListEventsCommand({
      memoryId: memId,
      actorId: userId,
      sessionId,
      includePayloads: true,
      maxResults: limit * 2,
    }),
  );
  return asChatMessagesFromEvents(sessionId, res.events ?? []).slice(-limit);
}

export async function writeShortTermUserMessage(
  sessionId: string,
  userId: string,
  content: string,
): Promise<void> {
  const memId = memoryId();
  if (!memId) return;
  const c = getClient();
  await c.send(
    new CreateEventCommand({
      memoryId: memId,
      actorId: userId,
      sessionId,
      eventTimestamp: new Date(),
      payload: [
        {
          conversational: {
            role: "USER",
            content: { text: content.slice(0, 2000) },
          },
        },
      ],
    }),
  );
}

export async function writeShortTermAssistantMessage(
  sessionId: string,
  userId: string,
  content: string,
  agentId: string,
): Promise<void> {
  const memId = memoryId();
  if (!memId) return;
  const c = getClient();
  await c.send(
    new CreateEventCommand({
      memoryId: memId,
      actorId: userId,
      sessionId,
      eventTimestamp: new Date(),
      payload: [
        {
          conversational: {
            role: "ASSISTANT",
            content: { text: content.slice(0, 4000) },
          },
        },
      ],
      metadata: {
        agentId: { stringValue: agentId },
      },
    }),
  );
}

export async function tryReadShortTermMessages(
  sessionId: string,
  userId: string,
  limit = 40,
): Promise<ChatMessage[]> {
  try {
    return await readShortTermMessages(sessionId, userId, limit);
  } catch (err) {
    logger.warn("[short-term-memory] AgentCore read failed; fallback enabled", {
      sessionId,
      userId,
      error: err instanceof Error ? err.message : String(err),
    });
    return [];
  }
}

export async function tryWriteShortTermUserMessage(
  sessionId: string,
  userId: string,
  content: string,
): Promise<void> {
  try {
    await writeShortTermUserMessage(sessionId, userId, content);
  } catch (err) {
    logger.warn("[short-term-memory] AgentCore write USER failed; fallback enabled", {
      sessionId,
      userId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

export async function tryWriteShortTermAssistantMessage(
  sessionId: string,
  userId: string,
  content: string,
  agentId: string,
): Promise<void> {
  try {
    await writeShortTermAssistantMessage(sessionId, userId, content, agentId);
  } catch (err) {
    logger.warn("[short-term-memory] AgentCore write ASSISTANT failed; fallback enabled", {
      sessionId,
      userId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}
