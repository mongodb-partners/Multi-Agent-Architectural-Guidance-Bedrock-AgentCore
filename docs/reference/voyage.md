# Voyage AI integration reference

This is the single-page reference for everything Voyage-related in the repo:
supported models, request envelope, embedding dimension, configuration knobs,
and the SSOT files that own each piece of knowledge.

If you're touching Voyage in any way (TS adapter, deploy script, Python smoke,
Terraform), read this page first.

---

## Supported models

| Model | Endpoint suffix | Output dim |
|---|---|---|
| `voyage-multimodal-3`   | `voyage-multimodal-3-${ENVIRONMENT}`   | 1024 |
| `voyage-multimodal-3.5` | `voyage-multimodal-3.5-${ENVIRONMENT}` | 1024 |

Text-only Voyage listings (`voyage-3`, `voyage-3-lite`, `voyage-3-large`,
`voyage-3-5-lite`, `voyage-4` family, `voyage-code-*`, `voyage-large-2`,
`voyage-multilingual-2`, `voyage-finance-2`, `voyage-law-2`) are **not
supported**. The legacy `{ "input": [...] }` request branch was deleted in
the multimodal-only migration. Deploy preflight refuses non-multimodal models
through `pf_check_voyage_marketplace_model_matches_arn`.

If you need text-only embeddings, switch `EMBEDDINGS_PROVIDER=titan`
(Bedrock Titan, no SageMaker provisioning, no Marketplace subscription).

---

## Canonical request envelope

The runtime + every preflight, smoke, and seed script all build their request
body the same way:

```ts
import {
  buildVoyageRequestBody,
  textToMultimodal,
} from "api/src/adapters/voyage-embedding.ts";

const body = buildVoyageRequestBody(
  [textToMultimodal("hello world")],
  "query", // or "document"
);
```

The emitted JSON is:

```json
{
  "inputs": [{ "content": [{ "type": "text", "text": "hello world" }] }],
  "input_type": "query",
  "truncation": true,
  "output_encoding": null
}
```

For mixed text + image inputs:

```ts
const body = buildVoyageRequestBody(
  [
    {
      content: [
        { type: "text", text: "what's in this product photo?" },
        { type: "image_url", image_url: "https://cdn.example/p.jpg" },
      ],
    },
  ],
  "document",
);
```

`image_url` is a plain HTTPS string (Voyage SDK reality). `image_base64` is a
data URI with the `data:image/<png|jpeg|webp>;base64,` prefix preserved.

---

## Single Source of Truth (SSOT)

All Voyage-related knowledge lives in **exactly three files**. Anything else
that reads `process.env.VOYAGE_*`, hand-rolls the request body, or hard-codes
the dim literal is a regression — `api/tests/unit/voyage-ssot-guard.test.ts`
fails CI if you introduce one.

| Layer | File | Exports |
|---|---|---|
| TypeScript | [`api/src/adapters/voyage-embedding.ts`](../../api/src/adapters/voyage-embedding.ts) | `SUPPORTED_VOYAGE_MODELS`, `VOYAGE_DEFAULT_EMBEDDING_DIMS`, `getVoyageEmbeddingDims()` (the only `VOYAGE_OUTPUT_DIM` reader), `buildVoyageRequestBody`, `textToMultimodal`, `multimodalItemSchema`, env getters (`isVoyageConfigured`, `getVoyageEndpoint`, `getVoyageModelName`), assertions (`assertSupportedVoyageModel`, `assertExpectedEmbeddingDims`), and the `voyageGenerateEmbedding(s)` HTTP client. |
| CLI bridge | [`api/scripts/voyage-print.ts`](../../api/scripts/voyage-print.ts) | `bun api/scripts/voyage-print.ts body <text> [query\|document]` → canonical JSON body. `models` and `dims` subcommands print the supported list / dim. |
| Bash | [`deploy/scripts/_voyage-config.sh`](../../deploy/scripts/_voyage-config.sh) | `voyage_canonical_body`, `voyage_supported_models`, `voyage_embedding_dims`, `voyage_model_family`, `voyage_assert_multimodal_or_die`. Cached per-shell so the bun shell-out runs once per invocation. |

The bash + Python sides MUST shell out to `voyage-print.ts` — they never
hand-roll the body. The SSOT guard test enforces this.

---

## Configuration matrix

| Knob | Meaning | Source |
|---|---|---|
| `EMBEDDINGS_PROVIDER` | `voyage` or `titan`. Mandatory at API boot. | `.env` |
| `VOYAGE_MARKETPLACE_MODEL` | `voyage-multimodal-3` or `voyage-multimodal-3.5`. | `.env` |
| `VOYAGE_MODEL_PACKAGE_ARN` | Region+subscription-scoped Marketplace ARN. | `.env` |
| `VOYAGE_INSTANCE_TYPE` | Default `ml.g6.xlarge`. Must be GPU. | `.env` |
| `TF_VAR_voyage_endpoint_name_suffix` | Default `voyage-multimodal-3`. May be model-derived, including `voyage-multimodal-3.5`; deploy scripts and Terraform normalize invalid SageMaker name characters to hyphens before endpoint creation. | `.env` |
| `VOYAGE_SAGEMAKER_ENDPOINT` | Resolved endpoint name (written by Terraform). | `.env.live` |
| `VOYAGE_OUTPUT_DIM` | Embedding output dimension. Default `1024` (`VOYAGE_DEFAULT_EMBEDDING_DIMS`). Allowed: `256/512/1024/2048` — **only** `voyage-multimodal-3.5` emits non-1024 (`voyage-multimodal-3` is 1024-only). Read once in `getVoyageEmbeddingDims()`; bash/Python and deploy-time Terraform derivation use the same SSOT value. When non-default, `buildVoyageRequestBody` adds `output_dimension` to the SageMaker envelope. | `.env` |

There is **no** `VOYAGE_REQUEST_FORMAT` (removed in the multimodal-only
migration; the CI guard test lights up if it reappears in `deploy/`).
`VOYAGE_OUTPUT_DIM` is allowed in `.env`, Terraform `.tf` files, deploy
entrypoints that derive `var.voyage_output_dim`, and env-writer scripts that
pass it into API / AgentCore runtimes. Deploy shell logic must not parse or
validate it directly — use the `voyage_embedding_dims` SSOT bridge there.

**Changing the dim is not hot-swappable.** It re-sizes the Atlas vector index
(`db-seeding/seed-indexes.ts`) and requires re-embedding existing rows. The next
`deploy/scripts/_seed-embeddings.sh` run auto-detects the drift (SSM
`/<SHARED_VPC_NAME>/<region>/embeddings/dim` + an in-Mongo fingerprint) and
rewires; manual fallback is `bun db-seeding/reembed-mismatched.ts --apply`.

---

## Strands tool

The Strands SDK calls Voyage via `embed_multimodal_content`, defined in
[`api/src/lib/base-tools.ts`](../../api/src/lib/base-tools.ts). Its input
schema is a `z.discriminatedUnion("type", ...)` covering `text`, `image_url`,
and `image_base64` segments. This prevents the SDK from silently down-casting
to a flat `string[]` (which is exactly the 400-error path the multimodal-only
migration was built to close).

The legacy `generate_embedding` tool has been removed. `RESERVED_TOOL_NAMES`
in `api/src/lib/http-tools-load.ts` + `skill-http-tools-load.ts` lists
`embed_multimodal_content` instead.

---

## Provider switching

```bash
# Switch to Titan (Bedrock, text-only — no SageMaker)
sed -i '' 's/^export EMBEDDINGS_PROVIDER=.*/export EMBEDDINGS_PROVIDER="titan"/' .env
./deploy/deploy-api.sh
./deploy/deploy-agents.sh --auto-approve
# Backfill embeddings for the new provider:
bun db-seeding/reembed-mismatched.ts --apply

# Switch back to Voyage (multimodal)
# Set EMBEDDINGS_PROVIDER=voyage, VOYAGE_MODEL_PACKAGE_ARN, and
# VOYAGE_MARKETPLACE_MODEL in .env before redeploying shared.
./deploy/scripts/deploy-shared.sh --auto-approve   # provisions SageMaker
./deploy/deploy-api.sh
./deploy/deploy-agents.sh --auto-approve
bun db-seeding/reembed-mismatched.ts --apply
```

---

## Diagnostics

| Symptom | Likely cause | Where to look |
|---|---|---|
| `Input Validation Error: input Field required` | Endpoint is text-only despite a `voyage-multimodal-3` name | `pf_check_voyage_endpoint_live_smoke` + `pf_check_voyage_marketplace_model_matches_arn` |
| `dim mismatch (got N, expected 1024)` | Subscribed model emits different dim | `db-seeding/probe-voyage-multimodal.ts` |
| `titan_no_multimodal` thrown from `embedQueryText` | Caller passed an image while `EMBEDDINGS_PROVIDER=titan` | `api/src/lib/embed-query.ts` |
| Strands SDK splatted segments into `string[]` | Old `generate_embedding` tool name still referenced somewhere | grep for `generate_embedding`; replace with `embed_multimodal_content` |

Run the live multimodal probe to verify the deployed endpoint:

```bash
source .env && source .env.live
bun db-seeding/probe-voyage-multimodal.ts
```

---

## Related docs

- [`docs/reference/env-vars.md`](env-vars.md) — full env-var catalog
- [`docs/advanced/deploy-tweak-guide.md`](../advanced/deploy-tweak-guide.md) — embedding provider modes
- [`docs/status/debugging.md`](../status/debugging.md) — persistent pitfalls
- [`docs/deployment-preflight-checks.md`](../deployment-preflight-checks.md) — `pf_check_voyage_*` reference
