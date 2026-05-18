import { Agent, Message, TextBlock, type Model, type Tool } from "@strands-agents/sdk";
import { resolveModel } from "../adapters/resolve-model.ts";
import { toolsForAgent } from "./base-tools.ts";
import { getAgent, listAgents, loadAgentPersona, type AgentDetail } from "./config-scan.ts";
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

// ---------------------------------------------------------------------------
// Agent template cache
//
// Strands `Agent` construction is cheap on its own, but the inputs aren't:
// `resolveModel` builds an AWS SDK client (now itself cached), `toolsForAgent`
// constructs Tool factories that close over a per-turn SkillRegistry, and
// `buildSystemPrompt` re-runs string assembly. We cache the heavy parts
// (model, tools, registry, base prompt) per agentId so per-call work is
// just (a) splice memoryContext into the cached base prompt, and (b) hand
// the cached parts plus a fresh `messages: seed` array to a new Agent.
//
// Caching is safe when the SkillRegistry's activated set is fixed at build
// time: either the agent has no skills (orchestrator) or `preActivateSkills`
// is true (specialists). For lazy-skill orchestrator-style runs (skills > 0
// but preActivateSkills=false) we bypass the cache so `activate_skill` calls
// in one chat don't leak into the next.
// ---------------------------------------------------------------------------

export type AgentTemplate = {
  agentConfig: AgentDetail;
  registry: SkillRegistry;
  systemPromptBase: string;
  tools: Tool[];
  model: Model;
};

type TemplateCacheEntry = { template: AgentTemplate; agentRef: AgentDetail };
const templateCache = new Map<string, TemplateCacheEntry>();

function templateIsCacheable(agentConfig: AgentDetail, preActivateSkills: boolean): boolean {
  if (agentConfig.skills.length === 0) return true;
  return preActivateSkills;
}

async function buildTemplate(
  agentConfig: AgentDetail,
  opts: { preActivateSkills: boolean },
): Promise<AgentTemplate> {
  const registry = new SkillRegistry(agentConfig.skills);
  if (opts.preActivateSkills) registry.activateAll();

  const persona = loadAgentPersona(agentConfig.id) ?? "";
  // memoryContext is intentionally omitted; callers splice it in per-turn.
  const systemPromptBase = buildSystemPrompt(
    persona,
    registry.discoveries,
    registry.activatedBlocks,
    undefined,
  );

  const inProcessTools = toolsForAgent(agentConfig.tools, registry);
  const mcpTools = await getMcpTools();
  if (mcpTools.length === 0) {
    logger.warn(
      "[agent] no MCP tools loaded from gateway — Mongo tool calls will fail",
      { agentId: agentConfig.id },
    );
  }
  const tools = [...inProcessTools, ...mcpTools];

  const model = resolveModel(agentConfig);

  return { agentConfig, registry, systemPromptBase, tools, model };
}

/**
 * Get-or-build the cached template for `agentId`. Re-builds when the
 * underlying `AgentDetail` reference changes (config-scan returns a new
 * object whenever the `.agent.md` mtime changes).
 */
export async function getAgentTemplate(
  agentId: string,
  opts: { preActivateSkills: boolean },
): Promise<AgentTemplate | undefined> {
  const agentConfig = getAgent(agentId);
  if (!agentConfig) return undefined;

  if (!templateIsCacheable(agentConfig, opts.preActivateSkills)) {
    // Lazy-skill mode: registry must be fresh per turn.
    return buildTemplate(agentConfig, opts);
  }

  const cached = templateCache.get(agentId);
  if (cached && cached.agentRef === agentConfig) return cached.template;

  const template = await buildTemplate(agentConfig, opts);
  templateCache.set(agentId, { template, agentRef: agentConfig });
  return template;
}

/** Pre-build templates for every agent so the first chat hits a warm cache. */
export async function warmAgentCache(): Promise<void> {
  const agents = listAgents();
  await Promise.allSettled(
    agents.map(async (a) => {
      try {
        const preActivateSkills = a.id !== "orchestrator";
        await getAgentTemplate(a.id, { preActivateSkills });
        logger.debug("[agent-cache] warmed template", { agentId: a.id });
      } catch (err) {
        logger.warn("[agent-cache] failed to warm template", {
          agentId: a.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }),
  );
}

/** Clear the per-process template cache after a config refresh. */
export function clearAgentTemplateCache(): void {
  templateCache.clear();
}

/** Test-only: clear the per-process template cache. */
export const resetAgentTemplateCacheForTests = clearAgentTemplateCache;

export async function createConfiguredStrandsAgent(
  agentId: string,
  options: CreateStrandsAgentOptions = {},
): Promise<Agent | undefined> {
  const { preActivateSkills = true, memoryContext } = options;
  const template = await getAgentTemplate(agentId, { preActivateSkills });
  if (!template) return undefined;

  const systemPrompt = memoryContext?.trim()
    ? buildSystemPrompt(
        // Re-derive the base by stripping discoveries/activated when we splice
        // memory context. Cheaper path: build full prompt from cached parts
        // by re-using the underlying assemble pieces. Since `template.systemPromptBase`
        // already reflects persona + discoveries + activated blocks, we just
        // prepend the memory section using the same helper.
        loadAgentPersona(agentId) ?? "",
        template.registry.discoveries,
        template.registry.activatedBlocks,
        memoryContext,
      )
    : template.systemPromptBase;

  const seed = strandsHistory(options.priorTurns);

  return new Agent({
    model: template.model,
    systemPrompt,
    name: template.agentConfig.name,
    id: template.agentConfig.id,
    description: template.agentConfig.description,
    printer: false,
    tools: template.tools,
    messages: seed,
  });
}
