/**
 * voyage-print.ts — Single-shot CLI bridge between the TS SSOT
 * (`api/src/adapters/voyage-embedding.ts`) and every non-TS consumer
 * (bash deploy scripts, python smoke/probe scripts).
 *
 * This file re-exports SSOT outputs to stdout so no other language has to
 * hand-roll a Voyage body literal, hard-code the supported-model list, or
 * read `VOYAGE_*` env vars itself.
 *
 * Subcommands:
 *
 *   bun api/scripts/voyage-print.ts body "<text>" <inputType>
 *     -> canonical JSON envelope for a single-text-segment payload
 *
 *   bun api/scripts/voyage-print.ts models
 *     -> space-separated list of SUPPORTED_VOYAGE_MODELS
 *
 *   bun api/scripts/voyage-print.ts dims
 *     -> resolved embedding dim as a bare integer (getVoyageEmbeddingDims():
 *        VOYAGE_OUTPUT_DIM if set, else VOYAGE_DEFAULT_EMBEDDING_DIMS)
 *
 * Exit codes: 0 success, 1 usage error, 2 SSOT validation error.
 *
 * The bash SSOT (`deploy/scripts/_voyage-config.sh`) caches `models` and
 * `dims` outputs in process globals so each deploy-script invocation pays
 * the ~200ms Bun startup at most once per knob.
 *
 * Drift prevention: `api/tests/unit/voyage-ssot-guard.test.ts` asserts
 *   - bash `voyage_supported_models` matches `SUPPORTED_VOYAGE_MODELS`
 *   - bash `voyage_embedding_dims` matches `getVoyageEmbeddingDims()`
 *   - bash `voyage_canonical_body` matches `buildVoyageRequestBody`
 */

import {
  SUPPORTED_VOYAGE_MODELS,
  getVoyageEmbeddingDims,
  buildVoyageRequestBody,
  textToMultimodal,
  type VoyageInputType,
} from "../src/adapters/voyage-embedding.ts";

function usage(rc = 1): never {
  process.stderr.write(
    [
      "voyage-print.ts — print Voyage SSOT values for non-TS consumers",
      "",
      "Usage:",
      '  bun api/scripts/voyage-print.ts body "<text>" <query|document>',
      "  bun api/scripts/voyage-print.ts models",
      "  bun api/scripts/voyage-print.ts dims",
      "",
    ].join("\n"),
  );
  process.exit(rc);
}

function parseInputType(raw: string | undefined): VoyageInputType {
  const v = (raw ?? "").trim().toLowerCase();
  if (v === "query" || v === "document") return v;
  process.stderr.write(`voyage-print: input_type must be 'query' or 'document', got '${raw ?? ""}'\n`);
  process.exit(1);
}

const [cmd, ...rest] = process.argv.slice(2);

switch (cmd) {
  case "body": {
    const text = rest[0];
    const inputType = parseInputType(rest[1]);
    if (typeof text !== "string" || text.length === 0) {
      process.stderr.write("voyage-print body: <text> argument is required and must be non-empty\n");
      process.exit(1);
    }
    try {
      // Wrap text → one MultimodalItem (single text segment) → one-item batch.
      // The body builder is batched: `MultimodalItem[]`.
      process.stdout.write(buildVoyageRequestBody([textToMultimodal(text)], inputType));
    } catch (err) {
      process.stderr.write(`voyage-print body: ${err instanceof Error ? err.message : String(err)}\n`);
      process.exit(2);
    }
    break;
  }
  case "models": {
    process.stdout.write(SUPPORTED_VOYAGE_MODELS.join(" "));
    break;
  }
  case "dims": {
    try {
      process.stdout.write(String(getVoyageEmbeddingDims()));
    } catch (err) {
      process.stderr.write(`voyage-print dims: ${err instanceof Error ? err.message : String(err)}\n`);
      process.exit(2);
    }
    break;
  }
  case undefined:
  case "":
  case "-h":
  case "--help":
    usage(0);
  // eslint-disable-next-line no-fallthrough
  default:
    process.stderr.write(`voyage-print: unknown subcommand '${cmd}'\n`);
    usage(1);
}
