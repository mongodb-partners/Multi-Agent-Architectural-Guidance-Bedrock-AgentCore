/**
 * Schema-drift guard between the runtime adapter and the deploy-time preflight.
 *
 * `pf_check_voyage_endpoint_live_smoke` in `deploy/scripts/_preflight-checks.sh`
 * sends a probe body to the live SageMaker endpoint. After the multimodal-only
 * unification it sources `_voyage-config.sh` and calls
 * `voyage_canonical_body "preflight ping" document` — which shells out to
 * `api/scripts/voyage-print.ts`, which re-exports `buildVoyageRequestBody`.
 *
 * This test asserts byte-for-byte parity: the bash helper and the TS body
 * builder produce the same JSON envelope. There is no longer a hand-rolled
 * legacy literal in `_preflight-checks.sh` to diff against — that drift
 * surface is closed.
 *
 * When `buildVoyageRequestBody` changes (new field, renamed field, default
 * flip), this test stays green automatically because the bash side delegates
 * to the same builder. If somebody re-introduces a hand-rolled literal in
 * the shell file, `voyage-ssot-guard.test.ts` catches that separately.
 *
 * Note: `output_dimension` is only emitted when VOYAGE_OUTPUT_DIM resolves to
 * a non-default dim (voyage-multimodal-3.5 Matryoshka). The default path
 * (unset / 1024) stays byte-identical to the legacy envelope, which is what
 * these tests pin (they unset VOYAGE_OUTPUT_DIM for determinism).
 */

import { describe, expect, test } from "bun:test";
import { execSync } from "node:child_process";
import path from "node:path";
import {
  buildVoyageRequestBody,
  textToMultimodal,
} from "../../src/adapters/voyage-embedding.ts";

const REPO_ROOT = path.resolve(import.meta.dir, "../../..");
const PROBE_TEXT = "preflight ping" as const;

describe("voyage preflight body parity (deploy-time vs runtime)", () => {
  test("voyage_canonical_body matches buildVoyageRequestBody byte-for-byte", () => {
    const bashOut = execSync(
      `bash -c 'unset VOYAGE_OUTPUT_DIM; source deploy/scripts/_voyage-config.sh && voyage_canonical_body "${PROBE_TEXT}" document'`,
      { cwd: REPO_ROOT },
    ).toString();
    const savedDim = process.env.VOYAGE_OUTPUT_DIM;
    delete process.env.VOYAGE_OUTPUT_DIM;
    try {
      const tsOut = buildVoyageRequestBody([textToMultimodal(PROBE_TEXT)], "document");
      expect(bashOut).toBe(tsOut);
    } finally {
      if (savedDim === undefined) delete process.env.VOYAGE_OUTPUT_DIM;
      else process.env.VOYAGE_OUTPUT_DIM = savedDim;
    }
  });

  test("voyage_canonical_body uses the canonical multimodal shape, never a legacy text-only literal", () => {
    const bashOut = execSync(
      `bash -c 'unset VOYAGE_OUTPUT_DIM; source deploy/scripts/_voyage-config.sh && voyage_canonical_body "${PROBE_TEXT}" query'`,
      { cwd: REPO_ROOT },
    ).toString();
    expect(bashOut).toMatch(/^\{"inputs":\[/);
    expect(bashOut).not.toMatch(/"output_dimension"/);
    expect(bashOut).not.toMatch(/^\{"input":\[/);
  });
});

/**
 * No-duplicate-builder guard — `db-seeding/seed-embeddings.ts` and
 * `db-seeding/reembed-mismatched.ts` MUST import the canonical
 * `buildVoyageRequestBody` from the api adapter rather than carrying a
 * local copy. The historical local copies were the proximate cause of the
 * "Field required: input" 400 burn — and the recovery path
 * (reembed-mismatched.ts) silently inheriting the bug made it impossible to
 * fix without redeploying everything.
 */
describe("voyage request envelope has a single source of truth", () => {
  const SEEDERS = [
    "db-seeding/seed-embeddings.ts",
    "db-seeding/reembed-mismatched.ts",
  ] as const;

  for (const rel of SEEDERS) {
    test(`${rel} imports buildVoyageRequestBody from the SSOT adapter`, () => {
      const src = require("node:fs").readFileSync(path.join(REPO_ROOT, rel), "utf8") as string;
      const importRe =
        /import\s*\{[^}]*\bbuildVoyageRequestBody\b[^}]*\}\s*from\s*["']\.\.\/api\/src\/adapters\/voyage-embedding\.ts["']/;
      expect(src).toMatch(importRe);
      // No local builder function.
      expect(src).not.toMatch(/function\s+buildVoyageBody\s*\(/);
    });
  }
});
