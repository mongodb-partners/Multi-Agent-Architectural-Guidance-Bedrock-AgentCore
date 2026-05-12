import { getMongoDb } from "./mongo-client.ts";
import { getAgent, listAgents } from "./config-scan.ts";
import {
  getChatSessionsCollection,
  usePersistentChatSessions,
} from "./chat-sessions-collection.ts";
import { probeMcpServer } from "../adapters/mongodb-mcp-client.ts";
import {
  BedrockAgentCoreClient,
  ListSessionsCommand,
} from "@aws-sdk/client-bedrock-agentcore";

const PING_MS = 2500;

export type MongoDependencyStatus =
  | "not_configured"
  | "connected"
  | "unreachable";

export type StubDependencyStatus = "not_configured";

export type AgentcoreStatus =
  | "not_configured"  // AGENTCORE_MEMORY_STORE_ID not set
  | "connected"       // Memory Store reachable
  | "unreachable";    // configured but API call failed

export type McpStatus =
  | "not_configured"  // TOOL_HOSTING_MODE != "gateway"
  | "connected"       // mongodb-mcp-server reachable
  | "unreachable";    // configured but server not responding

export type LongTermMemoryStatus =
  | "not_configured"   // MONGODB_URI not set
  | "connected"        // MongoDB reachable and ≥1 agent has longTerm: true
  | "unreachable"      // MONGODB_URI set but ping failed
  | "no_agents";       // MongoDB reachable but no agent has longTerm: true

/** MongoDB connectivity status. Requires MONGODB_URI. */
export async function resolveMongoDependencyStatus(): Promise<MongoDependencyStatus> {
  const uri = process.env.MONGODB_URI?.trim();
  if (!uri) return "not_configured";
  try {
    const db = await getMongoDb();
    if (!db) return "not_configured";
    const pingPromise = db.admin().command({ ping: 1 });
    const timeout = new Promise<never>((_, reject) => {
      setTimeout(() => reject(new Error("MongoDB ping timeout")), PING_MS);
    });
    await Promise.race([pingPromise, timeout]);
    return "connected";
  } catch {
    return "unreachable";
  }
}

/** Bedrock KB retrieve tool — not yet wired to health check. */
export function resolveBedrockKbDependencyStatus(): StubDependencyStatus {
  return "not_configured";
}

/** Probe AgentCore Memory Store reachability via ListSessions. */
export async function resolveAgentcoreDependencyStatus(): Promise<AgentcoreStatus> {
  const memoryStoreId = process.env.AGENTCORE_MEMORY_STORE_ID?.trim();
  if (!memoryStoreId) return "not_configured";
  try {
    const client = new BedrockAgentCoreClient({
      region: process.env.AWS_REGION ?? "us-east-1",
    });
    await client.send(
      new ListSessionsCommand({
        memoryId: memoryStoreId,
        actorId: "health-probe",
        maxResults: 1,
      }),
    );
    return "connected";
  } catch {
    return "unreachable";
  }
}

/** Probe the mongodb-mcp-server via the MCP client adapter. */
export async function resolveMcpDependencyStatus(): Promise<McpStatus> {
  return probeMcpServer();
}

/** Short-term chat session storage: in-process Map vs MongoDB `chat_sessions`. */
export type ChatSessionsPersistenceStatus = "memory" | "mongodb" | "agentcore" | "unavailable";

export async function resolveChatSessionsPersistenceStatus(
  mongoStatus: MongoDependencyStatus,
): Promise<ChatSessionsPersistenceStatus> {
  const shortTermBackend = (process.env.SHORT_TERM_MEMORY_BACKEND ?? "").trim().toLowerCase();
  if (shortTermBackend === "agentcore" && process.env.AGENTCORE_MEMORY_STORE_ID?.trim()) {
    return "agentcore";
  }
  if (!usePersistentChatSessions()) return "memory";
  if (mongoStatus === "not_configured" || mongoStatus === "unreachable") return "unavailable";
  const coll = await getChatSessionsCollection();
  if (!coll) return "unavailable";
  return "mongodb";
}

/** Base tools: in-process, AgentCore Gateway, or direct Lambda MCP invocation. */
export type ToolHostingMode = "direct" | "gateway" | "lambda";

export function resolveToolHostingMode(): ToolHostingMode {
  const m = process.env.TOOL_HOSTING_MODE?.trim().toLowerCase();
  if (m === "gateway") return "gateway";
  if (m === "lambda") return "lambda";
  return "direct";
}

/** Count agents that have `memory.longTerm: true` in their frontmatter. */
function countLtmAgents(): number {
  return listAgents().filter((a) => getAgent(a.id)?.memory?.longTerm === true).length;
}

/**
 * Long-term memory status — reflects whether the feature will actually
 * write/read turns. Requires MongoDB (or dev mock) plus ≥1 agent with
 * `memory.longTerm: true`.
 */
export function resolveLongTermMemoryStatus(
  mongoStatus: MongoDependencyStatus,
): LongTermMemoryStatus {
  if (mongoStatus === "unreachable") return "unreachable";
  if (mongoStatus === "not_configured") return "not_configured";
  const ltmCount = countLtmAgents();
  if (ltmCount === 0) return "no_agents";
  return "connected";
}

export async function buildHealthPayload(): Promise<{
  status: "ok" | "degraded";
  version: string;
  timestamp: string;
  dependencies: {
    mongodb: MongoDependencyStatus;
    longTermMemory: LongTermMemoryStatus;
    chatSessions: ChatSessionsPersistenceStatus;
    toolHosting: ToolHostingMode;
    agentcore: AgentcoreStatus;
    mcpServer: McpStatus;
    bedrockKnowledgeBase: StubDependencyStatus;
  };
}> {
  const mongo = await resolveMongoDependencyStatus();
  const longTermMemory = resolveLongTermMemoryStatus(mongo);
  const chatSessions = await resolveChatSessionsPersistenceStatus(mongo);
  const persistWanted = usePersistentChatSessions();
  const agentcore = await resolveAgentcoreDependencyStatus();
  const mcpServer = await resolveMcpDependencyStatus();
  const degraded =
    mongo === "unreachable" || (persistWanted && chatSessions === "unavailable");

  return {
    status: degraded ? "degraded" : "ok",
    version: "0.1.0",
    timestamp: new Date().toISOString(),
    dependencies: {
      mongodb: mongo,
      longTermMemory,
      chatSessions,
      toolHosting: resolveToolHostingMode(),
      agentcore,
      mcpServer,
      bedrockKnowledgeBase: resolveBedrockKbDependencyStatus(),
    },
  };
}
