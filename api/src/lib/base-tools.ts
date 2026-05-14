import { tool, type JSONValue, type Tool } from "@strands-agents/sdk";
import { z } from "zod";
import { logger } from "./logger.ts";
import {
  bedrockKbRetrieve,
  bedrockGenerateEmbedding,
} from "../adapters/bedrock-retrieval.ts";
import {
  voyageGenerateEmbedding,
  isVoyageConfigured,
  getVoyageEndpoint,
} from "../adapters/voyage-embedding.ts";
import { pathToFileURL } from "node:url";
import { readSkillResourceFile, resolveSkillResourcePath, type SkillRegistry } from "./skill-loader.ts";
import {
  getHttpToolsMap,
  makeSkillHttpConfigTool,
} from "./http-tools-runtime.ts";
import {
  findSkillHttpToolDefinition,
  parseSkillScopedHttpToolName,
} from "./skill-http-tools-load.ts";

/** Shared by `makeReadSkillResourceTool` and unit tests. */
export function readSkillResourceWithRegistry(
  registry: SkillRegistry,
  skillName: string,
  resourcePath: string,
): JSONValue {
  if (!registry.allowedSkills.has(skillName)) {
    return {
      ok: false,
      error: "skill_not_allowed_for_agent",
      skillName,
      path: resourcePath,
      hint: "This agent's .agent.md skills list does not include that skill.",
    };
  }
  if (!registry.isSkillActivated(skillName)) {
    return {
      ok: false,
      error: "skill_not_activated",
      skillName,
      path: resourcePath,
      hint: "Call activate_skill with this skillName first (or use a specialist agent that pre-loads skills).",
    };
  }
  const r = readSkillResourceFile(skillName, resourcePath);
  if (!r.ok) {
    return { ok: false, error: r.error, skillName, path: resourcePath };
  }
  return { ok: true, skillName, path: resourcePath, content: r.content };
}

const notConfigured = (hint: string) =>
  ({
    status: "not_configured" as const,
    hint,
  }) as const;

export function makeReadSkillResourceTool(registry: SkillRegistry): Tool {
  return tool({
    name: "read_skill_resource",
    description:
      "Load a file under config/skills/<skillName>/. The skill must be in this agent's skills list and already activated (activate_skill or specialist pre-load). Args: skillName, path relative to that skill folder.",
    inputSchema: z.object({
      skillName: z.string().min(1).describe("Skill folder name, e.g. order-management"),
      path: z
        .string()
        .min(1)
        .describe("Relative path, e.g. references/order-schema.md or scripts/validate-return.mjs"),
    }),
    callback: async (input): Promise<JSONValue> => {
      return readSkillResourceWithRegistry(registry, input.skillName, input.path);
    },
  });
}

/**
 * Generic: dynamically import a `.mjs` from `config/skills/<skillName>/scripts/…`
 * and call a named export. Same allowlist/activation gates as `read_skill_resource`.
 * The export's return value becomes the Strands tool result (model sees it on next step).
 */
export function makeRunSkillScriptTool(registry: SkillRegistry): Tool {
  return tool({
    name: "run_skill_script",
    description:
      "Dynamically import and call an exported function from a skill's scripts/ directory. " +
      "The skill must be in this agent's skills: list and activated. " +
      "Example: skillName='order-management', scriptPath='scripts/validate-return.mjs', " +
      "exportName='validateReturnEligibility', args={order document}.",
    inputSchema: z.object({
      skillName: z.string().min(1).describe("Skill folder name"),
      scriptPath: z
        .string()
        .min(1)
        .describe("Relative path to the .mjs file, e.g. scripts/validate-return.mjs"),
      exportName: z.string().min(1).describe("Named export to call"),
      args: z.unknown().describe("Argument passed to the function (object, array, or primitive)"),
    }),
    callback: async (input): Promise<JSONValue> => {
      if (!registry.allowedSkills.has(input.skillName)) {
        return { status: "error", code: "skill_not_allowed_for_agent", skillName: input.skillName };
      }
      if (!registry.isSkillActivated(input.skillName)) {
        return {
          status: "error",
          code: "skill_not_activated",
          skillName: input.skillName,
          hint: "Call activate_skill first.",
        };
      }
      const resolved = resolveSkillResourcePath(input.skillName, input.scriptPath);
      if (!resolved.ok) {
        return { status: "error", code: resolved.error, skillName: input.skillName, scriptPath: input.scriptPath };
      }
      let mod: Record<string, unknown>;
      try {
        mod = (await import(pathToFileURL(resolved.absolutePath).href)) as Record<string, unknown>;
      } catch (e) {
        return { status: "error", code: "import_failed", message: e instanceof Error ? e.message : String(e) };
      }
      const fn = mod[input.exportName];
      if (typeof fn !== "function") {
        return {
          status: "error",
          code: "export_not_found",
          exportName: input.exportName,
          availableExports: Object.keys(mod).filter((k) => typeof mod[k] === "function"),
        };
      }
      try {
        const result = fn(input.args);
        const value = result instanceof Promise ? await result : result;
        return { status: "ok", skillName: input.skillName, result: value as JSONValue };
      } catch (e) {
        return { status: "error", code: "script_threw", message: e instanceof Error ? e.message : String(e) };
      }
    },
  });
}

export const bedrockKbRetrieveTool = tool({
  name: "bedrock_kb_retrieve",
  description:
    "Retrieve relevant chunks from an Amazon Bedrock Knowledge Base (RAG). " +
    "Requires AWS credentials and a provisioned Knowledge Base. " +
    "Set BEDROCK_KB_ID as the default knowledgeBaseId (can be overridden per call).",
  inputSchema: z.object({
    query: z.string(),
    knowledgeBaseId: z
      .string()
      .optional()
      .describe("Knowledge Base ID — defaults to BEDROCK_KB_ID env var if omitted."),
    numberOfResults: z.number().optional(),
  }),
  callback: async (input): Promise<JSONValue> => {
    const kbId = input.knowledgeBaseId?.trim() || process.env.BEDROCK_KB_ID?.trim();
    if (!kbId) {
      return notConfigured(
        "Set BEDROCK_KB_ID env var or pass knowledgeBaseId. Provision a Knowledge Base in the AWS console first.",
      );
    }
    return bedrockKbRetrieve(input.query, kbId, input.numberOfResults ?? 5);
  },
});

export const generateEmbeddingTool = tool({
  name: "generate_embedding",
  description:
    "Generate a text embedding. " +
    "EC2/POC mode: uses Voyage AI voyage-3.5-lite via SageMaker (VOYAGE_SAGEMAKER_ENDPOINT). " +
    "Local mode: falls back to Amazon Bedrock Titan (EMBEDDING_MODEL_ID). " +
    "input_type: 'query' for search queries, 'document' for content to be indexed.",
  inputSchema: z.object({
    text: z.string(),
    input_type: z.enum(["query", "document"]).optional().default("query"),
  }),
  callback: async (input): Promise<JSONValue> => {
    if (isVoyageConfigured()) {
      return voyageGenerateEmbedding(input.text, getVoyageEndpoint(), input.input_type ?? "query");
    }
    const modelId = process.env.EMBEDDING_MODEL_ID?.trim();
    if (!modelId) {
      return { status: "not_configured", hint: "Set VOYAGE_SAGEMAKER_ENDPOINT or EMBEDDING_MODEL_ID." };
    }
    return bedrockGenerateEmbedding(input.text, modelId);
  },
});

// ---------------------------------------------------------------------------
// activate_skill — Phase 2 tool (factory, closes over per-turn SkillRegistry)
// ---------------------------------------------------------------------------

/**
 * Build the `activate_skill` Strands tool bound to a specific SkillRegistry.
 * When the model calls this tool, the registry loads the full SKILL.md body
 * and the next model call will include it in the system prompt.
 *
 * NOTE: Strands does not support dynamic system-prompt mutation mid-stream.
 * The activated body is available to subsequent tool calls and the final
 * answer within the same agent loop turn.
 */
export function makeActivateSkillTool(registry: SkillRegistry): Tool {
  return tool({
    name: "activate_skill",
    description:
      "Load the full instructions for a domain skill. Call this before answering questions in that domain. " +
      "Available skills are listed in the system prompt discovery index.",
    inputSchema: z.object({
      skillName: z
        .string()
        .min(1)
        .describe("Skill name from the discovery index (e.g. order-management)"),
    }),
    callback: async (input): Promise<JSONValue> => {
      const result = registry.activate(input.skillName);
      if (!result.ok) {
        return { ok: false, error: result.error, skillName: input.skillName };
      }
      return {
        ok: true,
        skillName: input.skillName,
        instructions: result.body,
        message:
          "Skill instructions loaded. Use them to answer the user's question accurately.",
      };
    },
  });
}

// ---------------------------------------------------------------------------
// Static tool registry + agent wiring
// ---------------------------------------------------------------------------

/**
 * In-process tool factory by name. Mongo tools (`mongodb_query`,
 * `mongodb_vector_search`, `mongodb_aggregate`) are NOT in this map: they
 * are served from the AgentCore Gateway as MCP tools and attached in
 * `createConfiguredStrandsAgent`. The agent never has an in-process Mongo
 * driver — gateway is the only Mongo transport.
 */
const staticToolByName: Record<string, Tool> = {
  bedrock_kb_retrieve: bedrockKbRetrieveTool,
  generate_embedding: generateEmbeddingTool,
};

/** Mongo tool names that always come from the gateway MCP target, never from
 * an in-process implementation. Names listed in an agent's `tools:` array
 * that match these are silently dropped by `toolsForAgent` — the agent will
 * still see them once `getMcpTools()` adds the gateway versions. */
const GATEWAY_MONGO_TOOL_NAMES: ReadonlySet<string> = new Set([
  "mongodb_query",
  "mongodb_vector_search",
  "mongodb_aggregate",
]);

/**
 * Build the Strands tool list for an agent.
 *
 * - Always includes `activate_skill` (bound to the per-turn registry).
 * - Adds static tools listed in the agent's `tools:` array.
 * - Silently drops Mongo tool names from the agent's `tools:` array; those
 *   are attached separately as MCP tools by `createConfiguredStrandsAgent`
 *   so the agent never has both an in-process and an MCP version.
 */
export function toolsForAgent(
  toolNames: string[],
  registry: SkillRegistry,
): Tool[] {
  const out: Tool[] = [makeActivateSkillTool(registry)];
  const seen = new Set<string>(["activate_skill"]);
  const httpTools = getHttpToolsMap();
  for (const raw of toolNames) {
    const name = raw.trim();
    if (seen.has(name)) continue;
    if (GATEWAY_MONGO_TOOL_NAMES.has(name)) {
      logger.debug("[tools] Mongo tool comes from gateway MCP, skipping in-process entry", { tool: name });
      continue;
    }
    seen.add(name);
    if (name === "read_skill_resource") {
      out.push(makeReadSkillResourceTool(registry));
      continue;
    }
    if (name === "run_skill_script") {
      out.push(makeRunSkillScriptTool(registry));
      continue;
    }
    const scoped = parseSkillScopedHttpToolName(name, registry.allowedSkills);
    if (scoped) {
      const def = findSkillHttpToolDefinition(scoped.skillName, scoped.localToolName);
      if (def) {
        out.push(makeSkillHttpConfigTool(name, scoped.skillName, def, registry));
        continue;
      }
      logger.warn("[tools] skill HTTP tool definition missing", {
        skill: scoped.skillName,
        tool: scoped.localToolName,
        agentEntry: name,
        hint: `Add it to config/skills/${scoped.skillName}/http-tools.json`,
      });
      continue;
    }
    const httpTool = httpTools.get(name);
    if (httpTool) {
      out.push(httpTool);
      continue;
    }
    const t = staticToolByName[name];
    if (t) out.push(t);
    else logger.warn("[tools] unknown tool in agent config, ignored", { tool: raw });
  }

  return out;
}
