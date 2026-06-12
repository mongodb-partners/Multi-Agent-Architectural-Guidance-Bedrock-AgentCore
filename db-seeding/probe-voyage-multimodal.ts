/**
 * probe-voyage-multimodal.ts — gating live smoke against the deployed
 * Voyage SageMaker endpoint.
 *
 * Sends a *mixed* text + inline-base64 PNG payload to the live endpoint
 * named in `VOYAGE_SAGEMAKER_ENDPOINT` and asserts the response carries
 * a `VOYAGE_EMBEDDING_DIMS`-d vector. Zero external network dependency
 * (the base64 below is a 1×1 transparent PNG, embedded inline).
 *
 * This is the gating step in the rollout: if the endpoint actually
 * accepts the canonical multimodal envelope with an image segment, every
 * consumer downstream (LTM writer, chat mirror, MCP vector search, the
 * Strands `embed_multimodal_content` tool) is safe to ship. If it
 * doesn't, the failure code tells the operator exactly which corner is
 * broken — endpoint absent, endpoint name mistyped, schema rejected
 * (Marketplace model is text-only), or dimension mismatch (Atlas index
 * mis-sized).
 *
 * Exit codes:
 *   0 — ok (`{ ok, dimensions, modelReturned, code: "ok" }` printed)
 *   1 — usage / env
 *   2 — endpoint_not_provisioned (no VOYAGE_SAGEMAKER_ENDPOINT)
 *   3 — endpoint_404           (SageMaker rejects endpoint name)
 *   4 — schema_rejected        (4xx with body rejection — re-plan needed)
 *   5 — dim_mismatch           (200 with wrong dim — model/index drift)
 *   6 — voyage_body_too_large  (caller payload exceeds 4MB cap)
 *   7 — other_runtime_error
 *
 * Usage:
 *   source .env && source .env.live
 *   bun db-seeding/probe-voyage-multimodal.ts
 *   bun db-seeding/probe-voyage-multimodal.ts --endpoint <name>
 */

import {
  buildVoyageRequestBody,
  type MultimodalItem,
  getVoyageEmbeddingDims,
  voyageGenerateEmbeddings,
  getVoyageEndpoint,
  isVoyageConfigured,
  assertExpectedEmbeddingDims,
} from "../api/src/adapters/voyage-embedding.ts";

const VOYAGE_EMBEDDING_DIMS = getVoyageEmbeddingDims();

// 1×1 transparent PNG, base64-encoded with the canonical `data:image/png;base64,`
// header retained per the Voyage SDK contract.
const ONE_BY_ONE_PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=";

type ProbeResult =
  | { ok: true; dimensions: number; modelReturned: string; code: "ok" }
  | { ok: false; code: ProbeFailureCode; message: string; raw?: unknown };

type ProbeFailureCode =
  | "endpoint_not_provisioned"
  | "endpoint_404"
  | "schema_rejected"
  | "dim_mismatch"
  | "voyage_body_too_large"
  | "other_runtime_error";

const FAILURE_EXIT: Record<ProbeFailureCode, number> = {
  endpoint_not_provisioned: 2,
  endpoint_404: 3,
  schema_rejected: 4,
  dim_mismatch: 5,
  voyage_body_too_large: 6,
  other_runtime_error: 7,
};

function parseArgs(argv: string[]): { endpoint?: string } {
  const out: { endpoint?: string } = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--endpoint") out.endpoint = argv[++i];
    else if (a === "--help" || a === "-h") {
      console.log("Usage: bun db-seeding/probe-voyage-multimodal.ts [--endpoint NAME]");
      process.exit(0);
    }
  }
  return out;
}

function classifyError(err: unknown): ProbeFailureCode {
  const msg = err instanceof Error ? err.message : String(err);
  const name = err instanceof Error ? err.name : "";
  // SageMaker's "endpoint does not exist" surface — the Runtime client
  // returns ValidationException OR a 404 depending on region+account.
  if (/ValidationException|EndpointArn|EndpointName.*not.*exist|cannot.*be.*found/i.test(msg)) {
    return "endpoint_404";
  }
  // 4xx from the container (Pydantic / schema) — the exact symptom we are
  // closing in this PR.
  if (/ModelError|client error \(4\d\d\)|Input Validation|Field required|unprocessable/i.test(msg)) {
    return "schema_rejected";
  }
  if (/voyage_body_too_large/.test(msg)) {
    return "voyage_body_too_large";
  }
  if (name === "AbortError") return "other_runtime_error";
  return "other_runtime_error";
}

async function probe(): Promise<ProbeResult> {
  const args = parseArgs(process.argv.slice(2));
  const endpointFromArg = args.endpoint?.trim();
  if (!endpointFromArg && !isVoyageConfigured()) {
    return {
      ok: false,
      code: "endpoint_not_provisioned",
      message:
        "VOYAGE_SAGEMAKER_ENDPOINT is not set and --endpoint was not supplied. " +
        "Source .env.live (or pass --endpoint <name>) and re-run.",
    };
  }
  const endpoint = endpointFromArg ?? getVoyageEndpoint();

  // Mixed text + inline base64 image item. Each MultimodalItem produces
  // one embedding; we send two items (one text-only, one mixed) so the
  // response is verified to carry both back in order.
  const items: MultimodalItem[] = [
    [{ type: "text", text: "voyage multimodal probe — text only" }],
    [
      { type: "text", text: "voyage multimodal probe — text + inline 1x1 PNG" },
      { type: "image_base64", image_base64: ONE_BY_ONE_PNG },
    ],
  ];

  let body: string;
  try {
    body = buildVoyageRequestBody(items, "document");
  } catch (err) {
    return {
      ok: false,
      code: classifyError(err),
      message: err instanceof Error ? err.message : String(err),
    };
  }
  // Light pre-flight: confirm body shape before we even send it.
  if (!body.startsWith('{"inputs":[')) {
    return {
      ok: false,
      code: "other_runtime_error",
      message: `built body has unexpected shape: ${body.slice(0, 80)}…`,
    };
  }

  try {
    const result = await voyageGenerateEmbeddings(items, endpoint, "document");
    if (result.status === "error") {
      return {
        ok: false,
        code: classifyError(new Error(result.error)),
        message: result.error,
        raw: result.raw,
      };
    }
    const dim = result.embeddings[0]?.length ?? 0;
    try {
      assertExpectedEmbeddingDims(dim);
    } catch (err) {
      return {
        ok: false,
        code: "dim_mismatch",
        message: err instanceof Error ? err.message : String(err),
      };
    }
    if (result.embeddings.length !== items.length) {
      return {
        ok: false,
        code: "other_runtime_error",
        message: `expected ${items.length} embeddings, got ${result.embeddings.length}`,
      };
    }
    return {
      ok: true,
      dimensions: dim,
      modelReturned: result.model,
      code: "ok",
    };
  } catch (err) {
    return {
      ok: false,
      code: classifyError(err),
      message: err instanceof Error ? err.message : String(err),
    };
  }
}

const result = await probe();
console.log(JSON.stringify(result, null, 2));
if (!result.ok) {
  console.error(
    `\nprobe-voyage-multimodal: FAIL code=${result.code}` +
      (result.code === "schema_rejected"
        ? " — STOP. The deployed model package is not accepting the canonical " +
          "multimodal envelope. Set VOYAGE_MODEL_PACKAGE_ARN to a supported " +
          "voyage-multimodal-3 or voyage-multimodal-3.5 package before " +
          "shipping any consumer change."
        : "") +
      (result.code === "dim_mismatch"
        ? ` — Atlas index dim (${VOYAGE_EMBEDDING_DIMS}) does not match the live model output. ` +
          "Either re-seed indexes for the new dim or re-provision the endpoint with " +
          "voyage-multimodal-3 (1024-d)."
        : ""),
  );
  process.exit(FAILURE_EXIT[result.code]);
}
console.error(
  `probe-voyage-multimodal: OK — dim=${result.dimensions} model=${result.modelReturned}`,
);
process.exit(0);
