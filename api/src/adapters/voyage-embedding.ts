/**
 * Voyage AI multimodal embedding adapter — SINGLE TS SOURCE OF TRUTH.
 *
 * This file is the ONLY TypeScript file that may:
 *   - Read any `process.env.VOYAGE_*` variable.
 *   - Know which Voyage models are supported.
 *   - Construct the SageMaker request body.
 *   - Know the embedding dimension (`VOYAGE_DEFAULT_EMBEDDING_DIMS` /
 *     `getVoyageEmbeddingDims()`, configurable via `VOYAGE_OUTPUT_DIM`).
 *   - Validate model names or response dimensions.
 *
 * Every other TS file imports from here. Non-TS consumers (bash, python,
 * terraform-via-comment-pin) call `api/scripts/voyage-print.ts {body,models,dims}`
 * which re-exports this module's outputs.
 *
 * Drift prevention: `api/tests/unit/voyage-ssot-guard.test.ts` fails CI if
 * the canonical body literal, env reads, supported-model list, or embedding
 * dim leak into other files. `pf_check_voyage_ssot_only_source` enforces
 * the same on the bash side.
 *
 * Multimodal-only. There is exactly ONE envelope shape:
 *
 *     {
 *       "inputs": [
 *         { "content": [
 *           { "type": "text", "text": "..." } |
 *           { "type": "image_url", "image_url": "https://..." } |
 *           { "type": "image_base64", "image_base64": "data:image/png;base64,..." }
 *         ] },
 *         ...
 *       ],
 *       "input_type": "query" | "document",
 *       "truncation": true,
 *       "output_encoding": null
 *     }
 *
 * The legacy `{ input: [string], output_dimension }` text-only envelope is
 * DELETED — it was the proximate cause of the SageMaker "Pydantic: input
 * Field required" 400. The codebase no longer has a "format" concept.
 *
 * Transport: existing SageMaker Marketplace endpoint via
 * `@aws-sdk/client-sagemaker-runtime`. No direct `api.voyageai.com` calls.
 */

import { SageMakerRuntimeClient, InvokeEndpointCommand } from "@aws-sdk/client-sagemaker-runtime";
import type { JSONValue } from "@strands-agents/sdk";
import { z } from "zod";

// ---------------------------------------------------------------------------
// Canonical constants — SSOT
// ---------------------------------------------------------------------------

/** The two Voyage models this stack speaks to. Anything else is rejected at
 *  boot by `assertSupportedVoyageModel`. Adding a new model = edit this
 *  one literal; architecture-guard tests + bash include auto-pick it up. */
export const SUPPORTED_VOYAGE_MODELS = [
  "voyage-multimodal-3",
  "voyage-multimodal-3.5",
] as const;

export type SupportedVoyageModel = (typeof SUPPORTED_VOYAGE_MODELS)[number];

/** Default embedding dimension for the Voyage multimodal family. Both
 *  `voyage-multimodal-3` and `voyage-multimodal-3.5` emit 1024-d vectors by
 *  default, and Atlas vector indexes are sized to match. This is the value
 *  used when `VOYAGE_OUTPUT_DIM` is unset; it also pins the Terraform <-> TS
 *  and bash <-> TS parity guards in `voyage-ssot-guard.test.ts`. */
export const VOYAGE_DEFAULT_EMBEDDING_DIMS = 1024 as const;

/** Output dimensions the Voyage multimodal family can emit (Matryoshka).
 *  `voyage-multimodal-3.5` supports all four; `voyage-multimodal-3` is
 *  1024-only (enforced in `getVoyageEmbeddingDims`). */
const VOYAGE_ALLOWED_DIMS = [256, 512, 1024, 2048] as const;

/** Resolved embedding dimension. Reads `VOYAGE_OUTPUT_DIM` (the ONLY env read
 *  of this knob in the entire codebase — every other consumer derives from
 *  here via `voyage-print.ts dims` / the bash SSOT). Defaults to
 *  `VOYAGE_DEFAULT_EMBEDDING_DIMS` when unset.
 *
 *  Validation:
 *    - must be one of `VOYAGE_ALLOWED_DIMS`;
 *    - `voyage-multimodal-3` only emits 1024 — any other value is refused so
 *      the operator gets a clear boot error instead of a SageMaker 4xx or a
 *      silent Atlas dim mismatch. */
export function getVoyageEmbeddingDims(): number {
  const raw = process.env.VOYAGE_OUTPUT_DIM?.trim();
  if (!raw) return VOYAGE_DEFAULT_EMBEDDING_DIMS;
  const n = Number(raw);
  if (!Number.isInteger(n) || !(VOYAGE_ALLOWED_DIMS as readonly number[]).includes(n)) {
    throw new Error(
      `VOYAGE_OUTPUT_DIM='${raw}' is not a supported Voyage output dimension. ` +
        `Allowed: ${VOYAGE_ALLOWED_DIMS.join(", ")}. Leave unset to use the default ${VOYAGE_DEFAULT_EMBEDDING_DIMS}.`,
    );
  }
  const model = getVoyageModelName();
  if (model === "voyage-multimodal-3" && n !== VOYAGE_DEFAULT_EMBEDDING_DIMS) {
    throw new Error(
      `VOYAGE_OUTPUT_DIM=${n} is invalid for model 'voyage-multimodal-3' (1024-d only). ` +
        "Set VOYAGE_MARKETPLACE_MODEL=voyage-multimodal-3.5 to use Matryoshka dimensions " +
        `(${VOYAGE_ALLOWED_DIMS.join(", ")}), or unset VOYAGE_OUTPUT_DIM.`,
    );
  }
  return n;
}

/** Per-text-segment truncation budget. Voyage's documented multimodal limit
 *  is ~32k characters per text piece; we enforce a hard slice so a long
 *  doc segment doesn't blow the per-request byte budget on its own. */
const VOYAGE_TEXT_MAX_CHARS = 32_000;

/** Hard byte cap for the entire SageMaker request body. The SageMaker
 *  Runtime synchronous invoke limit is 5 MB; we leave headroom for
 *  HTTP/JSON overhead and the SageMaker envelope so a single oversized
 *  `image_base64` payload returns a clear `voyage_body_too_large` error
 *  with an actionable hint rather than a generic SageMaker 413. */
const VOYAGE_MAX_BODY_BYTES = 4 * 1024 * 1024;

/** Default Voyage model name when neither env nor response carries one. */
const VOYAGE_MODEL_FALLBACK: SupportedVoyageModel = "voyage-multimodal-3";

// ---------------------------------------------------------------------------
// Public types — multimodal boundary
// ---------------------------------------------------------------------------

export type VoyageInputType = "query" | "document";

/** Text segment. The Voyage container truncates internally too, but we
 *  pre-slice at `VOYAGE_TEXT_MAX_CHARS` so the byte cap math is predictable. */
export type MultimodalTextSegment = {
  type: "text";
  text: string;
};

/** HTTPS URL segment. Voyage SDK takes a plain string here (NOT
 *  `{ url: string }`). The SageMaker container resolves the URL itself. */
export type MultimodalImageUrlSegment = {
  type: "image_url";
  image_url: string;
};

/** Base64 image segment. MUST include the `data:image/<mime>;base64,`
 *  header per the Voyage container contract (and per the reference doc's
 *  guardrail #4). Bare base64 strings are rejected at the zod boundary. */
export type MultimodalImageBase64Segment = {
  type: "image_base64";
  image_base64: string;
};

export type MultimodalSegment =
  | MultimodalTextSegment
  | MultimodalImageUrlSegment
  | MultimodalImageBase64Segment;

/** One interleaved input. Each item produces one embedding in the response. */
export type MultimodalItem = MultimodalSegment[];

// ---------------------------------------------------------------------------
// Public zod schemas — re-exported into Strands tool inputs + container probe
// ---------------------------------------------------------------------------

const BASE64_HEADER_RE =
  /^data:image\/(png|jpeg|jpg|webp|gif);base64,/;

export const multimodalSegmentSchema: z.ZodType<MultimodalSegment> = z.discriminatedUnion("type", [
  z.object({ type: z.literal("text"), text: z.string().min(1) }),
  z.object({ type: z.literal("image_url"), image_url: z.string().url() }),
  z.object({
    type: z.literal("image_base64"),
    image_base64: z.string().regex(BASE64_HEADER_RE, {
      message:
        "image_base64 must begin with `data:image/(png|jpeg|jpg|webp|gif);base64,` (header retained per Voyage contract)",
    }),
  }),
]);

export const multimodalItemSchema: z.ZodType<MultimodalItem> = z
  .array(multimodalSegmentSchema)
  .min(1, { message: "MultimodalItem must contain at least one segment" });

// ---------------------------------------------------------------------------
// Public helpers
// ---------------------------------------------------------------------------

/** Wrap a plain string into the canonical MultimodalItem shape. Existing
 *  text-only call sites (`embedDocumentText("hello")`, `embedQueryText(q)`)
 *  stay unchanged — `string` arguments auto-wrap via this helper before
 *  hitting the typed adapter boundary. */
export function textToMultimodal(text: string): MultimodalItem {
  return [{ type: "text", text }];
}

/** Does any segment in this item carry image data (URL or base64)? Used by
 *  the embed-query gate to refuse `EMBEDDINGS_PROVIDER=titan` + image input
 *  with a structured `titan_no_multimodal` error. */
export function hasImageSegment(item: MultimodalItem): boolean {
  return item.some((s) => s.type === "image_url" || s.type === "image_base64");
}

/** Has any item in this batch got an image segment? */
export function anyItemHasImage(items: MultimodalItem[]): boolean {
  return items.some(hasImageSegment);
}

/** Redact base64 image bytes from a MultimodalItem before logging. We
 *  keep the header (so the mime type is visible) and append a `<elided NB>`
 *  marker so payloads of any size produce bounded log lines. */
export function redactBase64Segments(items: MultimodalItem[]): MultimodalItem[] {
  return items.map((segs) =>
    segs.map((seg) => {
      if (seg.type !== "image_base64") return seg;
      const header = seg.image_base64.split(",")[0] ?? "data:image/?;base64";
      const bodyLen = Math.max(0, seg.image_base64.length - header.length - 1);
      return {
        type: "image_base64" as const,
        image_base64: `${header},<elided ${bodyLen}B>`,
      };
    }),
  );
}

// ---------------------------------------------------------------------------
// Env reads — only this file
// ---------------------------------------------------------------------------

/** True when the Voyage AI SageMaker endpoint is configured. */
export function isVoyageConfigured(): boolean {
  return Boolean(process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim());
}

export function getVoyageEndpoint(): string {
  const ep = process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim();
  if (!ep) throw new Error("VOYAGE_SAGEMAKER_ENDPOINT is not set");
  return ep;
}

/** The Voyage model name from `VOYAGE_MARKETPLACE_MODEL` (preferred) or
 *  `VOYAGE_MODEL_NAME` (legacy), defaulting to `voyage-multimodal-3`. */
export function getVoyageModelName(): string {
  return (
    process.env.VOYAGE_MARKETPLACE_MODEL?.trim() ||
    process.env.VOYAGE_MODEL_NAME?.trim() ||
    VOYAGE_MODEL_FALLBACK
  );
}

// ---------------------------------------------------------------------------
// Assertions — call at boot + per-response
// ---------------------------------------------------------------------------

/** Throws if `name` is not in `SUPPORTED_VOYAGE_MODELS`. Called from both
 *  `api/src/index.ts` (existing assertEmbeddingsProvider) AND
 *  `api/src/agent-runtime-code.ts:501` (the AgentCore-bundled boot guard).
 *  Both must remain in lockstep — `agent-runtime-code.ts` is bundled into
 *  `dist/agent-runtime-code.js` and deployed via `./deploy/deploy-agents.sh`,
 *  so missing it means specialist runtimes boot with a stale guard. */
export function assertSupportedVoyageModel(name: string): void {
  const trimmed = (name ?? "").trim();
  if (!trimmed) {
    throw new Error(
      "Voyage model name is empty — set VOYAGE_MARKETPLACE_MODEL (or VOYAGE_MODEL_NAME) " +
        `to one of: ${SUPPORTED_VOYAGE_MODELS.join(", ")}`,
    );
  }
  if (!(SUPPORTED_VOYAGE_MODELS as readonly string[]).includes(trimmed)) {
    throw new Error(
      `Voyage model '${trimmed}' is not supported. ` +
        `This stack is multimodal-only. Allowed: ${SUPPORTED_VOYAGE_MODELS.join(", ")}. ` +
        "Set VOYAGE_MARKETPLACE_MODEL to voyage-multimodal-3 or voyage-multimodal-3.5.",
    );
  }
}

/** Throws if `actual` ≠ the resolved embedding dim (`getVoyageEmbeddingDims()`,
 *  i.e. `VOYAGE_OUTPUT_DIM` or the 1024 default). Called inside
 *  `voyageGenerateEmbedding` immediately after the SageMaker response is
 *  parsed — catches mid-stream container/model swaps that silently return
 *  a different dim (the failure mode the legacy EMBEDDING_DIMENSIONS
 *  preflight existed to catch). */
export function assertExpectedEmbeddingDims(actual: number): void {
  const expected = getVoyageEmbeddingDims();
  if (actual !== expected) {
    throw new Error(
      `Voyage embedding dimension mismatch: got ${actual}, expected ${expected}. ` +
        "The deployed model is returning a vector that does not match the Atlas vector index. " +
        "Likely causes: (a) endpoint serves a non-multimodal Voyage package despite the name, " +
        "(b) Atlas index was reseeded for a different provider. " +
        "Set VOYAGE_MODEL_PACKAGE_ARN to a supported multimodal package, then run " +
        "./deploy/scripts/deploy-shared.sh && ./deploy/deploy-api.sh && ./deploy/deploy-agents.sh --auto-approve.",
    );
  }
}

// ---------------------------------------------------------------------------
// Body builder — the ONLY function that converts the typed boundary into
// the SageMaker container's wire envelope.
// ---------------------------------------------------------------------------

export function buildVoyageRequestBody(
  items: MultimodalItem[],
  inputType: VoyageInputType,
): string {
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error("buildVoyageRequestBody: items must be a non-empty MultimodalItem[]");
  }

  // Validate every item via the canonical schema. This is the line that
  // makes it structurally impossible for a flat `string[]` (from a model
  // tool-call that down-cast multimodal intent) to reach the wire.
  const validated = items.map((item, idx) => {
    const parsed = multimodalItemSchema.parse(item) as MultimodalItem;
    return {
      content: parsed.map((seg) =>
        seg.type === "text"
          ? { type: "text" as const, text: seg.text.slice(0, VOYAGE_TEXT_MAX_CHARS) }
          : seg,
      ),
      // idx kept locally for error messages only; not emitted on the wire.
      __idx: idx,
    };
  });

  // Resolved output dimension. When it equals the family default (1024) we
  // omit `output_dimension` entirely so the default `voyage-multimodal-3`
  // envelope stays byte-identical to the legacy wire shape (and the
  // body-parity guard). Only an explicit non-default `VOYAGE_OUTPUT_DIM`
  // (voyage-multimodal-3.5 Matryoshka) adds the field.
  const dims = getVoyageEmbeddingDims();
  const envelope = {
    inputs: validated.map(({ content }) => ({ content })),
    input_type: inputType,
    truncation: true,
    output_encoding: null as null,
    ...(dims !== VOYAGE_DEFAULT_EMBEDDING_DIMS ? { output_dimension: dims } : {}),
  };

  const body = JSON.stringify(envelope);
  const byteLen = Buffer.byteLength(body, "utf8");
  if (byteLen > VOYAGE_MAX_BODY_BYTES) {
    throw new Error(
      `voyage_body_too_large: request body is ${byteLen}B (limit ${VOYAGE_MAX_BODY_BYTES}B). ` +
        "Hint: use `image_url` instead of `image_base64` for large images — the SageMaker " +
        "container fetches the URL server-side and does not consume request bytes.",
    );
  }
  return body;
}

// ---------------------------------------------------------------------------
// SageMaker invocation
// ---------------------------------------------------------------------------

let _client: SageMakerRuntimeClient | null = null;

function getClient(): SageMakerRuntimeClient {
  if (!_client) {
    _client = new SageMakerRuntimeClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _client;
}

/** Result envelope for a single invocation. Caller decides how to consume —
 *  the chat-message mirror, LTM writer, and MCP vector-search wrapper all
 *  speak this same shape via `embed-query.ts`. */
export type VoyageInvocationOk = {
  status: "ok";
  embedding: number[];
  model: string;
  dimensions: number;
};

export type VoyageInvocationError = {
  status: "error";
  error: string;
  raw?: unknown;
};

export type VoyageInvocationResult = VoyageInvocationOk | VoyageInvocationError;

/** Single-item convenience: send one MultimodalItem, return its embedding.
 *  All current consumers (embed-query, seeders, probe) embed one item at a
 *  time so we keep the API simple here. A batched form lives one call below. */
export async function voyageGenerateEmbedding(
  item: MultimodalItem,
  endpointName: string,
  inputType: VoyageInputType = "document",
  abortSignal?: AbortSignal,
): Promise<JSONValue> {
  const r = await voyageGenerateEmbeddings([item], endpointName, inputType, abortSignal);
  if (r.status !== "ok") return r as JSONValue;
  return {
    status: "ok",
    embedding: r.embeddings[0]!,
    model: r.model,
    dimensions: r.embeddings[0]!.length,
  } as JSONValue;
}

export type VoyageBatchOk = {
  status: "ok";
  embeddings: number[][];
  model: string;
};

/** Batched form. Returns one embedding per input item, in order. */
export async function voyageGenerateEmbeddings(
  items: MultimodalItem[],
  endpointName: string,
  inputType: VoyageInputType = "document",
  abortSignal?: AbortSignal,
): Promise<VoyageBatchOk | VoyageInvocationError> {
  const body = buildVoyageRequestBody(items, inputType);

  const cmd = new InvokeEndpointCommand({
    EndpointName: endpointName,
    ContentType: "application/json",
    Accept: "application/json",
    Body: Buffer.from(body),
  });

  const res = await getClient().send(cmd, abortSignal ? { abortSignal } : undefined);
  let decoded: {
    data: { embedding: number[]; index: number }[];
    model?: string;
    usage?: { total_tokens?: number };
  };
  try {
    decoded = JSON.parse(new TextDecoder().decode(res.Body));
  } catch (err) {
    return {
      status: "error",
      error: `Voyage returned a non-JSON body: ${err instanceof Error ? err.message : String(err)}`,
    };
  }

  if (!Array.isArray(decoded.data) || decoded.data.length === 0) {
    return { status: "error", error: "Voyage AI returned no embeddings", raw: decoded };
  }

  const ordered: number[][] = new Array(items.length);
  for (const row of decoded.data) {
    if (!Array.isArray(row.embedding)) {
      return { status: "error", error: "Voyage response row missing embedding array", raw: row };
    }
    const idx = typeof row.index === "number" ? row.index : -1;
    if (idx < 0 || idx >= items.length) {
      // Container may emit rows in arrival order without an `index` — fall
      // back to positional assignment for the next empty slot.
      const slot = ordered.findIndex((v) => v === undefined);
      if (slot === -1) {
        return { status: "error", error: "Voyage returned more rows than inputs", raw: decoded };
      }
      ordered[slot] = row.embedding;
    } else {
      ordered[idx] = row.embedding;
    }
  }

  for (let i = 0; i < ordered.length; i++) {
    if (!Array.isArray(ordered[i])) {
      return { status: "error", error: `Voyage response missing embedding for input[${i}]`, raw: decoded };
    }
  }

  // Single dim assertion against the first row — they're all the same model.
  assertExpectedEmbeddingDims(ordered[0]!.length);

  return {
    status: "ok",
    embeddings: ordered,
    model: decoded.model ?? getVoyageModelName(),
  };
}
