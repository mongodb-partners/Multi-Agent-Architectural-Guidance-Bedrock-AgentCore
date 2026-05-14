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

  // Tools come from two places:
  //   - Non-Mongo in-process tools (HTTP, skill scripts, KB retrieve, etc.)
  //   - Mongo tools served as MCP from the AgentCore Gateway
  // The agent never has an in-process Mongo driver.
  const inProcessTools = toolsForAgent(agentConfig.tools, registry);
  const mcpTools = await getMcpTools();
  if (mcpTools.length > 0) {
    logger.debug("[agent] attached gateway MCP tools", { agentId, count: mcpTools.length });
  } else {
    logger.warn(
      "[agent] no MCP tools loaded from gateway — Mongo tool calls will fail",
      { agentId },
    );
  }
  const tools = [...inProcessTools, ...mcpTools];

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
