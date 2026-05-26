/**
 * Schema-drift guard between the runtime adapter and the deploy-time preflight.
 *
 * `pf_check_voyage_endpoint_live_smoke` in deploy/scripts/_preflight-checks.sh
 * invokes the live SageMaker endpoint with a hand-written JSON body for both
 * supported request formats (multimodal + legacy). Those literal strings MUST
 * stay byte-identical to what `buildVoyageRequestBody("preflight ping",
 * "document", <fmt>)` produces — otherwise the preflight would lie:
 *
 *   - Endpoint accepts preflight body but rejects runtime body
 *     → deploy passes, every embed call fails at seed-embeddings / API mirror
 *       with the same Pydantic "Field required" 400 we already burned on.
 *   - Endpoint rejects preflight body but accepts runtime body
 *     → false-positive preflight fail; operator bisects ARN family and finds
 *       no real bug.
 *
 * This test extracts the two body literals from the shell file by regex and
 * asserts they exactly equal the adapter's output for the canonical preflight
 * probe ("preflight ping", input_type="document", VOYAGE_OUTPUT_DIM=1024).
 *
 * When buildVoyageRequestBody changes (new field, renamed field, default flip)
 * this test fails first — fix `_preflight-checks.sh` in the same commit.
 */

import { describe, expect, test, beforeAll, afterAll } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { buildVoyageRequestBody } from "../../src/adapters/voyage-embedding.ts";

const REPO_ROOT = path.resolve(import.meta.dir, "../../..");
const PREFLIGHT_FILE = path.join(REPO_ROOT, "deploy/scripts/_preflight-checks.sh");

const PROBE_TEXT = "preflight ping" as const;

describe("voyage preflight body parity (deploy-time vs runtime)", () => {
  let preflightSrc = "";
  const savedOutputDim = process.env.VOYAGE_OUTPUT_DIM;

  beforeAll(() => {
    preflightSrc = readFileSync(PREFLIGHT_FILE, "utf8");
    // Lock VOYAGE_OUTPUT_DIM=1024 — preflight hard-codes 1024 because that
    // is the only dimension wire-compatible with the Atlas vector index sized
    // for Bedrock Titan v2. If someone bumps the runtime default the literal
    // in the shell file MUST follow, and the assertion below will catch the
    // drift even before that happens (the preflight string itself is checked
    // for `"output_dimension":1024`).
    process.env.VOYAGE_OUTPUT_DIM = "1024";
  });

  afterAll(() => {
    if (savedOutputDim === undefined) {
      delete process.env.VOYAGE_OUTPUT_DIM;
    } else {
      process.env.VOYAGE_OUTPUT_DIM = savedOutputDim;
    }
  });

  test("preflight smoke check defines literal bodies for both formats", () => {
    // Sanity: the function still lives in the shell file and still uses
    // single-quoted literals for both branches.
    expect(preflightSrc).toContain("pf_check_voyage_endpoint_live_smoke()");
    expect(preflightSrc).toMatch(/body='\{"input":\[/);
    expect(preflightSrc).toMatch(/body='\{"inputs":\[/);
  });

  test("multimodal body in preflight matches buildVoyageRequestBody output", () => {
    // Extract the multimodal branch literal. The function is shaped:
    //   if [[ "$fmt" == "legacy" ]]; then
    //     body='{"input":[...]...}'
    //   else
    //     body='{"inputs":[...]...}'
    //   fi
    const mm = preflightSrc.match(/body='(\{"inputs":\[[^']+\})'/);
    expect(mm).not.toBeNull();
    const preflightMultimodal = mm![1];

    const runtimeMultimodal = buildVoyageRequestBody(PROBE_TEXT, "document", "multimodal");
    expect(preflightMultimodal).toBe(runtimeMultimodal);
  });

  test("legacy body in preflight matches buildVoyageRequestBody output", () => {
    const lg = preflightSrc.match(/body='(\{"input":\[[^']+\})'/);
    expect(lg).not.toBeNull();
    const preflightLegacy = lg![1];

    const runtimeLegacy = buildVoyageRequestBody(PROBE_TEXT, "document", "legacy");
    expect(preflightLegacy).toBe(runtimeLegacy);
  });

  test("preflight schema-drift error message still reflects current envelope", () => {
    // The operator-facing diagnostic in the failure path hard-codes the field
    // names ('input' vs 'inputs'). If buildVoyageRequestBody ever introduces
    // a third envelope, the schema_diag block must be updated to match.
    expect(preflightSrc).toContain("sent 'inputs', expected 'input'");
    expect(preflightSrc).toContain("sent 'input', expected 'inputs'");
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
 *
 * If this test starts failing the message at the bottom of the assertion is
 * the entire fix: import from `../api/src/adapters/voyage-embedding.ts` and
 * delete the local copy.
 */
describe("voyage request envelope has a single source of truth", () => {
  const SEEDERS = [
    "db-seeding/seed-embeddings.ts",
    "db-seeding/reembed-mismatched.ts",
  ] as const;

  for (const rel of SEEDERS) {
    test(`${rel} imports buildVoyageRequestBody and has no local copy`, () => {
      const src = readFileSync(path.join(REPO_ROOT, rel), "utf8");

      // Must import from the canonical api adapter.
      const importRe =
        /import\s*\{\s*buildVoyageRequestBody\s*\}\s*from\s*["']\.\.\/api\/src\/adapters\/voyage-embedding\.ts["']/;
      expect(src).toMatch(importRe);

      // Must NOT define a local function named buildVoyageBody.
      expect(src).not.toMatch(/function\s+buildVoyageBody\s*\(/);

      // The canonical fields ('inputs' wrapped in 'content', 'output_encoding')
      // must not appear as object-literal keys outside of strings / imports.
      // We do a coarse check: the field-name patterns the local copy used
      // ('input_type:' and 'output_encoding:' as object keys) should be gone.
      // Comments / doc strings that mention these names are fine because the
      // regex requires the literal followed by a colon-and-value.
      expect(src).not.toMatch(/\boutput_encoding\s*:\s*null\b/);
      expect(src).not.toMatch(/\binput_type\s*:\s*"(query|document)"/);
    });
  }
});

