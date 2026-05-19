import { BedrockModel, type Model } from "@strands-agents/sdk";
import type { AgentDetail } from "../lib/config-scan.ts";
import { logger } from "../lib/logger.ts";
import { currentTrace } from "../lib/trace-context.ts";

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
  const model = new MetadataAwareBedrockModel({
    modelId,
    maxTokens: agentConfig.maxTokens,
    temperature: agentConfig.temperature,
    ...(region ? { region } : {}),
  }) as unknown as Model;
  cache.set(key, model);
  return model;
}

/**
 * BedrockModel subclass that injects per-turn `requestMetadata` (userId,
 * agentId) into the Converse / ConverseStream request, so the Bedrock
 * model-invocation log records carry per-user attribution. The Phase 3
 * `multiagent-cost` CloudWatch dashboard groups InputTokenCount /
 * OutputTokenCount by `requestMetadata.userId` to render the per-user cost
 * widget.
 *
 * Implementation:
 *   - Reads the active TraceCollector via AsyncLocalStorage (`currentTrace`)
 *     at call time, NOT at construction. The model itself is cached per
 *     agent + region (see `resolveModel` cache key), so caching the userId
 *     in the model would scope it to the first caller — not what we want.
 *   - Mutates `_config.additionalArgs.requestMetadata` for the duration of
 *     the `stream()` call. This is safe because Strands serializes Converse
 *     calls per Agent instance (the framework awaits each stream() before
 *     starting the next); concurrent turns use separate Agent instances
 *     that each resolve their own model.
 *   - Bedrock requestMetadata values are constrained to strings <= 256
 *     chars per AWS docs; we cast and truncate defensively.
 *
 * Documented caveats:
 *   - Strands does not formally expose `additionalArgs` as per-call state;
 *     this relies on `_config` being a mutable POJO and `_formatRequest`
 *     reading it at request time. A future Strands change that snapshots
 *     `_config` at construction would break this — we have a unit test
 *     under api/tests/unit/resolve-model-requestmetadata.test.ts (created
 *     in Phase 3) that catches regressions before deploy.
 */
class MetadataAwareBedrockModel extends BedrockModel {
  override stream(messages: Parameters<BedrockModel["stream"]>[0], options?: Parameters<BedrockModel["stream"]>[1]): ReturnType<BedrockModel["stream"]> {
    try {
      const trace = currentTrace();
      const userId = trace?.userId?.slice(0, 256);
      const agentId = trace?.agentId?.slice(0, 256);
      const metadata: Record<string, string> = {};
      if (userId) metadata.userId = userId;
      if (agentId) metadata.agentId = agentId;
      if (Object.keys(metadata).length > 0) {
        // _config is private but stable across Strands 0.7. We merge into
        // existing additionalArgs so per-agent .additionalArgs from the
        // .agent.md (if ever added) stay intact.
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const cfg = (this as any)._config as { additionalArgs?: Record<string, unknown> } | undefined;
        if (cfg) {
          const existing = (cfg.additionalArgs ?? {}) as Record<string, unknown>;
          cfg.additionalArgs = {
            ...existing,
            requestMetadata: {
              ...((existing.requestMetadata as Record<string, string> | undefined) ?? {}),
              ...metadata,
            },
          };
        }
      }
    } catch (err) {
      logger.warn("[resolve-model] failed to inject requestMetadata", {
        error: err instanceof Error ? err.message : String(err),
      });
    }
    return super.stream(messages, options);
  }
}

/** Test helper: clear the per-process model cache. */
export function resetResolveModelCacheForTests(): void {
  cache.clear();
}
