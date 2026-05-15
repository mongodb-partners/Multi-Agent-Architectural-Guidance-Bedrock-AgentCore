import { BedrockModel, type Model } from "@strands-agents/sdk";
import type { AgentDetail } from "../lib/config-scan.ts";
import { logger } from "../lib/logger.ts";

/**
 * Construct the Bedrock model for an agent.
 *
 * Cached per `agentId + (modelId, maxTokens, temperature, region)`. The
 * BedrockModel constructor instantiates a fresh AWS SDK Bedrock Runtime
 * client under the hood (with credential provider chain + retry middleware
 * + signing key derivation), which used to fire on every chat — and once
 * per agent inside the swarm, so 4× per turn. With this cache it fires
 * once per process per agent config.
 *
 * Cache key includes `region` so a hot-reload of `AWS_REGION` (mostly only
 * tests do this) still produces a fresh client. Cache key includes
 * `modelId/maxTokens/temperature` so editing an `.agent.md` and updating
 * any of those still rebuilds the model on the next call (config-scan's
 * mtime cache invalidation forces a new `agentConfig` object first).
 */

type CacheKey = string;
const cache = new Map<CacheKey, Model>();

function makeCacheKey(agentConfig: AgentDetail, region: string | undefined): CacheKey {
  return `${agentConfig.id}::${agentConfig.model}::${agentConfig.maxTokens}::${agentConfig.temperature}::${region ?? ""}`;
}

/** Resolve the Bedrock model for an agent. Throws if the agent's .agent.md has no model: field. */
export function resolveModel(agentConfig: AgentDetail): Model {
  const modelId = agentConfig.model?.trim();
  if (!modelId) {
    throw new Error(
      `Agent '${agentConfig.id}' has no model configured. Add a 'model:' field to ${agentConfig.id}.agent.md.`,
    );
  }

  const region = process.env.AWS_REGION?.trim();
  const key = makeCacheKey(agentConfig, region);
  const hit = cache.get(key);
  if (hit) {
    logger.debug("[resolve-model] cache hit", { agentId: agentConfig.id, modelId });
    return hit;
  }

  logger.info("[resolve-model] creating BedrockModel", {
    agentId: agentConfig.id,
    modelId,
    region: region ?? "default",
    maxTokens: agentConfig.maxTokens,
    temperature: agentConfig.temperature,
  });
  const model = new BedrockModel({
    modelId,
    maxTokens: agentConfig.maxTokens,
    temperature: agentConfig.temperature,
    ...(region ? { region } : {}),
  });
  cache.set(key, model);
  return model;
}

/** Test helper: clear the per-process model cache. */
export function resetResolveModelCacheForTests(): void {
  cache.clear();
}
