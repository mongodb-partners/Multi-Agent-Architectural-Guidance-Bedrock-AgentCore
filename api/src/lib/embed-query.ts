/**
 * Text → embedding for `mongodb_vector_search` and write-side indexing.
 *
 * Strict provider selection — `EMBEDDINGS_PROVIDER` (in `.env`) is the single
 * source of truth and is mandatory. There is **no cross-provider fallback**
 * under any circumstance:
 *
 *   1. `voyage` — Voyage AI on SageMaker via `VOYAGE_SAGEMAKER_ENDPOINT`.
 *      If Voyage is unconfigured, throws, or returns an unrecognized shape,
 *      the function returns `{ ok: false, code: "voyage_strict_failed" }`.
 *      Bedrock is **never** called.
 *   2. `titan` — Bedrock Titan / Cohere via `EMBEDDING_MODEL_ID`. On any
 *      failure returns `{ ok: false, code: "titan_strict_failed" }`. Voyage
 *      is **never** called.
 *   3. anything else (including unset / empty) — returns
 *      `{ ok: false, code: "no_provider_configured" }`. There is no legacy
 *      soft-fallback branch.
 *
 * Sits between the LLM (which passes natural-language `queryText`) and the
 * MongoDB MCP gateway (which only accepts a pre-computed `queryVector`). The
 * wrapper in `api/src/adapters/mongodb-mcp-client.ts` calls `embedQueryText`
 * once per vector search call to produce the `queryVector` it forwards.
 *
 * Errors are returned as structured `EmbedResult` values rather than thrown,
 * so the wrapper can pass them back to the LLM as a tool-result error block
 * (the model can then fall back to keyword search via `mongodb_query`).
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
  | "voyage_strict_failed"
  | "titan_strict_failed"
  | "embed_threw";

/** Default Voyage model name when SageMaker omits the `model` field in the response. */
const VOYAGE_MODEL_FALLBACK = "voyage-multimodal-3";

/**
 * Run the configured embedding provider against `text`.
 *
 * Empty / whitespace-only input is treated as a caller bug — we return a
 * `no_provider_configured`-style error so the LLM sees a clean tool error
 * rather than an opaque downstream failure.
 *
 * In strict-voyage mode, any Voyage failure is hard — Bedrock is never tried.
 * In strict-titan mode, any Bedrock failure is hard — Voyage is never tried.
 */
export async function embedQueryText(text: string, abortSignal?: AbortSignal): Promise<EmbedResult> {
  return embedWithInputType(text, "query", abortSignal);
}

/**
 * Write-side embedder. Same provider rules as `embedQueryText` but passes
 * `input_type: "document"` to Voyage so the resulting vectors land in the
 * same semantic space as the offline seed pipeline (see
 * `db-seeding/seed-embeddings.ts`). Use this for indexing/save paths —
 * facts, chat messages — and `embedQueryText` for query-time embedding.
 */
export async function embedDocumentText(text: string, abortSignal?: AbortSignal): Promise<EmbedResult> {
  return embedWithInputType(text, "document", abortSignal);
}

function declaredProvider(): "voyage" | "titan" | "" {
  const raw = (process.env.EMBEDDINGS_PROVIDER ?? "").trim().toLowerCase();
  if (raw === "voyage" || raw === "titan") return raw;
  return "";
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

  const provider = declaredProvider();

  if (provider === "voyage") {
    return embedVoyageStrict(trimmed, inputType, abortSignal);
  }
  if (provider === "titan") {
    return embedTitanStrict(trimmed, abortSignal);
  }

  return {
    ok: false,
    code: "no_provider_configured",
    message:
      "EMBEDDINGS_PROVIDER must be set to 'voyage' or 'titan'. Strict mode — no implicit default, no cross-provider fallback.",
  };
}

async function embedVoyageStrict(
  text: string,
  inputType: "query" | "document",
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  if (!isVoyageConfigured()) {
    return {
      ok: false,
      code: "voyage_strict_failed",
      message:
        "EMBEDDINGS_PROVIDER=voyage but VOYAGE_SAGEMAKER_ENDPOINT is empty. Refusing to fall back to Bedrock.",
    };
  }
  try {
    const r = await voyageGenerateEmbedding(text, getVoyageEndpoint(), inputType, abortSignal);
    const v = extractEmbedding(r);
    if (v) {
      const modelId =
        v.modelId ?? process.env.VOYAGE_MODEL_NAME?.trim() ?? VOYAGE_MODEL_FALLBACK;
      return { ok: true, source: "voyage", modelId, vector: v.embedding };
    }
    logger.warn("[embed-query] voyage returned unrecognized shape (strict mode — no fallback)", {
      sample: previewJson(r),
      inputType,
    });
    return {
      ok: false,
      code: "voyage_strict_failed",
      message: `Voyage returned unrecognized embedding shape: ${previewJson(r)}`,
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.warn("[embed-query] voyage call threw (strict mode — no fallback)", {
      error: message,
      inputType,
    });
    return { ok: false, code: "voyage_strict_failed", message };
  }
}

async function embedTitanStrict(
  text: string,
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  const bedrockModelId = process.env.EMBEDDING_MODEL_ID?.trim();
  if (!bedrockModelId) {
    return {
      ok: false,
      code: "titan_strict_failed",
      message:
        "EMBEDDINGS_PROVIDER=titan but EMBEDDING_MODEL_ID is empty. Refusing to fall back to Voyage.",
    };
  }
  try {
    const r = await bedrockGenerateEmbedding(text, bedrockModelId, abortSignal);
    const v = extractEmbedding(r);
    if (v) {
      return { ok: true, source: "bedrock", modelId: v.modelId ?? bedrockModelId, vector: v.embedding };
    }
    return {
      ok: false,
      code: "titan_strict_failed",
      message: `Bedrock returned unrecognized embedding shape: ${previewJson(r)}`,
    };
  } catch (err) {
    return {
      ok: false,
      code: "titan_strict_failed",
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
