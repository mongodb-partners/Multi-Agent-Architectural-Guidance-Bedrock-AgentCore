/**
 * Query-time text → embedding for `mongodb_vector_search`.
 *
 * Sits between the LLM (which passes natural-language `queryText`) and the
 * MongoDB MCP Lambda (which only accepts a pre-computed `queryVector`). The
 * wrapper in `api/src/adapters/mongodb-mcp-client.ts` calls this once per
 * vector search call to produce the `queryVector` it forwards to the gateway.
 *
 * Provider order:
 *   1. Voyage AI on SageMaker — when `VOYAGE_SAGEMAKER_ENDPOINT` is set
 *      (`voyageGenerateEmbedding(text, endpoint, "query")`). Default in EC2
 *      mode; matches the embeddings produced by `db-seeding/seed-embeddings.ts`.
 *   2. Bedrock Titan / Cohere — when `EMBEDDING_MODEL_ID` is set. Used as the
 *      fallback when Voyage is unconfigured or transiently fails.
 *
 * If neither provider is configured / both fail we return a structured error
 * instead of throwing so the wrapper can pass it back to the LLM as a
 * tool-result error block (the model can then fall back to `mongodb_query`
 * keyword search rather than crashing the turn).
 *
 * The vector dimensions must match the Atlas Vector Search index for the
 * collection (see `db-seeding/seed-indexes.ts` — both indexes are 1024-d by
 * default and `VOYAGE_OUTPUT_DIM` pins voyage-3.5-lite to 1024).
 */

import { logger } from "./logger.ts";
import {
  isVoyageConfigured,
  getVoyageEndpoint,
  voyageGenerateEmbedding,
} from "../adapters/voyage-embedding.ts";
import { bedrockGenerateEmbedding } from "../adapters/bedrock-retrieval.ts";

/** Result of an embedding attempt. Either a vector + provenance, or a structured error. */
export type EmbedResult =
  | { ok: true; source: "voyage" | "bedrock"; modelId: string; vector: number[] }
  | { ok: false; code: EmbedErrorCode; message: string };

export type EmbedErrorCode =
  | "no_provider_configured"
  | "voyage_failed_no_fallback"
  | "bedrock_failed";

/**
 * Run the configured embedding provider against `text`.
 *
 * Empty / whitespace-only input is treated as a caller bug — we return a
 * `no_provider_configured`-style error so the LLM sees a clean tool error
 * rather than an opaque downstream failure.
 *
 * Voyage soft-fails (caught + logged) and we proceed to Bedrock if
 * `EMBEDDING_MODEL_ID` is set. Bedrock failure is hard and surfaces as an
 * error to the caller.
 */
export async function embedQueryText(text: string, abortSignal?: AbortSignal): Promise<EmbedResult> {
  return embedWithInputType(text, "query", abortSignal);
}

/**
 * Write-side embedder. Same provider order as `embedQueryText` (Voyage primary,
 * Bedrock fallback) but passes `input_type: "document"` to Voyage so the
 * resulting vectors land in the same semantic space as the offline seed
 * pipeline (see `db-seeding/seed-embeddings.ts`). Use this for indexing/save
 * paths — facts, chat messages — and `embedQueryText` for query-time embedding.
 */
export async function embedDocumentText(text: string, abortSignal?: AbortSignal): Promise<EmbedResult> {
  return embedWithInputType(text, "document", abortSignal);
}

async function embedWithInputType(
  text: string,
  inputType: "query" | "document",
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  const trimmed = (text ?? "").trim();
  if (!trimmed) {
    return {
      ok: false,
      code: "no_provider_configured",
      message: "embedding input text is empty",
    };
  }

  const bedrockModelId = process.env.EMBEDDING_MODEL_ID?.trim();

  if (isVoyageConfigured()) {
    try {
      const r = await voyageGenerateEmbedding(trimmed, getVoyageEndpoint(), inputType, abortSignal);
      const v = extractEmbedding(r);
      if (v) {
        return { ok: true, source: "voyage", modelId: v.modelId ?? "voyage", vector: v.embedding };
      }
      logger.warn("[embed-query] voyage returned unrecognized shape, falling back", {
        sample: previewJson(r),
        inputType,
      });
    } catch (err) {
      logger.warn("[embed-query] voyage call threw, falling back", {
        error: err instanceof Error ? err.message : String(err),
        inputType,
      });
    }
    if (!bedrockModelId) {
      return {
        ok: false,
        code: "voyage_failed_no_fallback",
        message:
          "Voyage embedding failed and EMBEDDING_MODEL_ID is not set for Bedrock fallback",
      };
    }
  }

  if (!bedrockModelId) {
    return {
      ok: false,
      code: "no_provider_configured",
      message:
        "No embedding provider configured. Set VOYAGE_SAGEMAKER_ENDPOINT or EMBEDDING_MODEL_ID.",
    };
  }

  try {
    const r = await bedrockGenerateEmbedding(trimmed, bedrockModelId, abortSignal);
    const v = extractEmbedding(r);
    if (v) {
      return { ok: true, source: "bedrock", modelId: v.modelId ?? bedrockModelId, vector: v.embedding };
    }
    return {
      ok: false,
      code: "bedrock_failed",
      message: `Bedrock returned unrecognized embedding shape: ${previewJson(r)}`,
    };
  } catch (err) {
    return {
      ok: false,
      code: "bedrock_failed",
      message: err instanceof Error ? err.message : String(err),
    };
  }
}

/**
 * Compact preview of a vector for trace events. Atlas vector indexes are
 * routinely 1024-d / 1536-d — we record only length + the first 4 + last 4
 * entries so the per-event byte cap doesn't strip the whole field.
 */
export function previewVector(vector: number[]): {
  length: number;
  head: number[];
  tail: number[];
} {
  const head = vector.slice(0, 4).map(round6);
  const tail = vector.length > 8 ? vector.slice(-4).map(round6) : [];
  return { length: vector.length, head, tail };
}

function round6(n: number): number {
  if (!Number.isFinite(n)) return n;
  return Math.round(n * 1e6) / 1e6;
}

function previewJson(value: unknown): string {
  try {
    const s = JSON.stringify(value);
    return s.length > 200 ? `${s.slice(0, 200)}…` : s;
  } catch {
    return "[unserializable]";
  }
}

/**
 * Both `voyageGenerateEmbedding` and `bedrockGenerateEmbedding` return JSONValue
 * shapes ({ status: "ok", embedding, model? } | { status: "error", ... }) and
 * test mocks may pass through untyped objects. Narrow defensively here so the
 * caller always gets `number[]` or undefined.
 */
function extractEmbedding(
  raw: unknown,
): { embedding: number[]; modelId?: string } | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const obj = raw as Record<string, unknown>;
  if (obj.status && obj.status !== "ok") return undefined;
  const emb = obj.embedding;
  if (!Array.isArray(emb) || emb.length === 0) return undefined;
  if (!emb.every((n) => typeof n === "number" && Number.isFinite(n))) return undefined;
  const modelId =
    typeof obj.model === "string"
      ? obj.model
      : typeof obj.modelId === "string"
        ? obj.modelId
        : undefined;
  return { embedding: emb as number[], modelId };
}
