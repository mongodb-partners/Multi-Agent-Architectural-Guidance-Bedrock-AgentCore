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
the multimodal-only migration. `setup-voyage-marketplace.sh` and
`pf_check_voyage_marketplace_model_matches_arn` both refuse non-multimodal
models at preflight.

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
| TypeScript | [`api/src/adapters/voyage-embedding.ts`](../../api/src/adapters/voyage-embedding.ts) | `SUPPORTED_VOYAGE_MODELS`, `VOYAGE_EMBEDDING_DIMS`, `buildVoyageRequestBody`, `textToMultimodal`, `multimodalItemSchema`, env getters (`isVoyageConfigured`, `getVoyageEndpoint`, `getVoyageModelName`), assertions (`assertSupportedVoyageModel`, `assertExpectedEmbeddingDims`), and the `voyageGenerateEmbedding(s)` HTTP client. |
| CLI bridge | [`api/scripts/voyage-print.ts`](../../api/scripts/voyage-print.ts) | `bun api/scripts/voyage-print.ts body <text> [query\|document]` → canonical JSON body. `models` and `dims` subcommands print the supported list / dim. |
| Bash | [`deploy/scripts/_voyage-config.sh`](../../deploy/scripts/_voyage-config.sh) | `voyage_canonical_body`, `voyage_supported_models`, `voyage_embedding_dims`, `voyage_model_family`, `voyage_assert_multimodal_or_die`. Cached per-shell so the bun shell-out runs once per invocation. |

The bash + Python sides MUST shell out to `voyage-print.ts` — they never
hand-roll the body. The SSOT guard test enforces this.

---

## Configuration matrix

| Knob | Meaning | Source |
|---|---|---|
| `EMBEDDINGS_PROVIDER` | `voyage` or `titan`. Mandatory at API boot. | `.env` |
| `VOYAGE_MARKETPLACE_MODEL` | `voyage-multimodal-3` or `voyage-multimodal-3.5`. | `.env` (set by `setup-voyage-marketplace.sh`) |
| `VOYAGE_MODEL_PACKAGE_ARN` | Region+subscription-scoped Marketplace ARN. | `.env` (discovered) |
| `VOYAGE_INSTANCE_TYPE` | Default `ml.g6.xlarge`. Must be GPU. | `.env` |
| `TF_VAR_voyage_endpoint_name_suffix` | Default `voyage-multimodal-3`. | `.env` |
| `VOYAGE_SAGEMAKER_ENDPOINT` | Resolved endpoint name (written by Terraform). | `.env.live` |
| `VOYAGE_EMBEDDING_DIMS` | 1024. Code constant — there is no env override. | `api/src/adapters/voyage-embedding.ts` |

There is **no** `VOYAGE_REQUEST_FORMAT` and **no** `VOYAGE_OUTPUT_DIM`. Both
were removed in the multimodal-only migration. The CI guard test lights up
if either reappears in `deploy/`.

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
./deploy/scripts/setup-voyage-marketplace.sh --model voyage-multimodal-3
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
