import { Agent, Message, TextBlock } from "@strands-agents/sdk";
import { resolveModel } from "../adapters/resolve-model.ts";
import { toolsForAgent } from "./base-tools.ts";
import { getAgent, loadAgentPersona } from "./config-scan.ts";
import { buildSystemPrompt } from "./prompt.ts";
import { SkillRegistry } from "./skill-loader.ts";
import type { ChatMessage } from "./session-store.ts";
import { getMcpTools } from "../adapters/mongodb-mcp-client.ts";
import { logger } from "./logger.ts";

export function strandsHistory(priorTurns: ChatMessage[] | undefined): Message[] | undefined {
  if (!priorTurns?.length) return undefined;
  return priorTurns.map(
    (m) =>
      new Message({
        role: m.role,
        content: [new TextBlock(m.content)],
      }),
  );
}

export type CreateStrandsAgentOptions = {
  priorTurns?: ChatMessage[];
  /** When true, pre-activate all skills (specialist agents). Default: true. */
  preActivateSkills?: boolean;
  /** Long-term memory context string to inject into the system prompt (Phase 5). */
  memoryContext?: string;
};

export async function createConfiguredStrandsAgent(
  agentId: string,
  options: CreateStrandsAgentOptions = {},
): Promise<Agent | undefined> {
  const agentConfig = getAgent(agentId);
  if (!agentConfig) return undefined;

  const { preActivateSkills = true, memoryContext } = options;

  const registry = new SkillRegistry(agentConfig.skills);
  if (preActivateSkills) {
    registry.activateAll();
  }

  const persona = loadAgentPersona(agentId) ?? "";
  const systemPrompt = buildSystemPrompt(
    persona,
    registry.discoveries,
    registry.activatedBlocks,
    memoryContext,
  );

  const model = resolveModel(agentConfig);

  // Tool composition is mutually exclusive by TOOL_HOSTING_MODE:
  //   - gateway → MCP tools (from AgentCore Gateway) + non-Mongo in-process tools
  //   - lambda / direct → only in-process tools (Mongo tools internally route
  //     to Lambda when TOOL_HOSTING_MODE=lambda, or to the local driver when
  //     "direct"). MCP tools are never attached.
  // The agent never sees both Mongo sources at once.
  const mode = (process.env.TOOL_HOSTING_MODE ?? "direct").trim().toLowerCase();
  const isGateway = mode === "gateway";

  const inProcessTools = toolsForAgent(agentConfig.tools, registry, {
    excludeMongoTools: isGateway,
  });

  let tools = inProcessTools;
  if (isGateway) {
    const mcpTools = await getMcpTools();
    if (mcpTools.length > 0) {
      logger.debug("[agent] attaching MCP tools (gateway mode)", { agentId, count: mcpTools.length });
    } else {
      logger.warn("[agent] gateway mode set but no MCP tools loaded — Mongo tool calls will fail", { agentId });
    }
    tools = [...inProcessTools, ...mcpTools];
  }

  const seed = strandsHistory(options.priorTurns);

  return new Agent({
    model,
    systemPrompt,
    name: agentConfig.name,
    id: agentConfig.id,
    description: agentConfig.description,
    printer: false,
    tools,
    messages: seed,
  });
}
