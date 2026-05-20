import { BedrockModel, type Model } from "@strands-agents/sdk";
import { ConfiguredRetryStrategy } from "@smithy/util-retry";
import type { RetryErrorInfo, StandardRetryToken } from "@smithy/types";
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
  // Bedrock retry visibility (`model.retry` trace events): the Strands SDK
  // 0.7 does NOT natively surface AWS SDK v3 retries through its hook
  // surface (`AfterModelCallEvent.retry` is a *user-driven* application
  // retry flag, not an SDK-level observer — see scripts/validate-strands-
  // retries.ts). The actual Bedrock retries (`ThrottlingException`,
  // `InternalServerException`, etc.) happen below Strands inside the AWS
  // SDK v3 `BedrockRuntimeClient`. We wrap the client's `retryStrategy`
  // with a `TracingRetryStrategy` that delegates to a standard strategy
  // and emits one `model.retry` event per refresh — giving the Developer
  // details panel a complete picture of "why was this turn slow" without
  // having to grep CloudWatch.
  const maxAttempts = envInt("BEDROCK_MAX_ATTEMPTS", 3);
  const retryStrategy = new TracingRetryStrategy(maxAttempts, modelId);
  const model = new MetadataAwareBedrockModel({
    modelId,
    maxTokens: agentConfig.maxTokens,
    temperature: agentConfig.temperature,
    ...(region ? { region } : {}),
    clientConfig: {
      ...(region ? { region } : {}),
      retryStrategy,
    },
  }) as unknown as Model;
  cache.set(key, model);
  return model;
}

function envInt(name: string, fallback: number): number {
  const v = process.env[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/**
 * AWS SDK v3 retry strategy wrapper that emits a `model.retry` trace event
 * each time the underlying strategy decides to retry. Wraps `ConfiguredRetryStrategy`
 * with exponential backoff (`attempt ** 2 * 100ms`) — same defaults the SDK
 * uses internally, just observable from our trace pipeline.
 *
 * The trace event lives in `model.retry` (see `api/src/lib/trace-types.ts`)
 * and is rendered in Developer details → Retries.
 *
 * Failure mode: if `currentTrace()` is `undefined` (turn started without a
 * collector) the retry still happens; we just don't observe it. The strategy
 * never throws — emitting the trace event is wrapped in try/catch.
 */
export class TracingRetryStrategy extends ConfiguredRetryStrategy {
  constructor(
    maxAttempts: number,
    private readonly modelId: string,
  ) {
    // Exponential backoff: 100ms, 400ms, 900ms, 1600ms, 2500ms…
    super(maxAttempts, (attempt: number) => attempt ** 2 * 100);
  }

  override async refreshRetryTokenForRetry(
    tokenToRenew: StandardRetryToken,
    errorInfo: RetryErrorInfo,
  ): Promise<StandardRetryToken> {
    const newToken = await super.refreshRetryTokenForRetry(tokenToRenew, errorInfo);
    try {
      const trace = currentTrace();
      if (trace) {
        // `retryCount` on a StandardRetryToken is post-increment (the
        // refresh just bumped it). Surfacing it as `attempt` matches the
        // convention "attempt 1 = first retry after the initial call".
        const attempt = (newToken as unknown as { retryCount?: number }).retryCount ?? 1;
        const errClass =
          (errorInfo as unknown as { errorType?: string }).errorType ??
          (errorInfo as unknown as { error?: { name?: string } }).error?.name ??
          "RetryableError";
        const errMessage =
          (errorInfo as unknown as { error?: { message?: string } }).error?.message ??
          "Retryable Bedrock error";
        // retryDelay lives on the token after `super.refreshRetryTokenForRetry`.
        const backoffMs =
          (newToken as unknown as { getRetryDelay?: () => number }).getRetryDelay?.() ?? 0;
        trace.event("model.retry", {
          provider: "bedrock",
          modelId: this.modelId,
          attempt,
          previousErrorClass: errClass,
          previousErrorMessage: errMessage,
          backoffMs,
        });
      }
    } catch (err) {
      logger.warn("[resolve-model] failed to emit model.retry event", {
        modelId: this.modelId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
    return newToken;
  }
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
