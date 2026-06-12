/**
 * Architecture-guard tests that fail CI if Voyage knowledge OR the
 * canonical embedding dimension leak outside the SSOT.
 *
 * The SSOT files are:
 *   - api/src/adapters/voyage-embedding.ts  (TS SSOT)
 *   - api/scripts/voyage-print.ts            (one-shot bridge to non-TS consumers)
 *   - deploy/scripts/_voyage-config.sh       (bash SSOT)
 *
 * Anything outside these three files that:
 *   - reads `process.env.VOYAGE_*`
 *   - emits a literal multimodal body envelope
 *   - imports `buildVoyageRequestBody` outside the allowlist
 *   - declares its own `EMBEDDING_DIMENSIONS=1024` literal
 *   - has bash supported-model / dim values that differ from the TS SSOT
 *   - hardcodes a Terraform `EMBEDDING_DIMENSIONS = "<n>"` numeric literal
 *     instead of deriving it from `var.voyage_output_dim`, or whose
 *     `voyage_output_dim` default differs from VOYAGE_DEFAULT_EMBEDDING_DIMS
 * is a regression. These tests light up so the fix happens in the same PR.
 *
 * Companion bash-side guard: `pf_check_voyage_ssot_only_source` in
 * `deploy/scripts/_preflight-checks.sh --self-test`.
 */

import { describe, expect, test } from "bun:test";
import { execSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import {
  SUPPORTED_VOYAGE_MODELS,
  VOYAGE_DEFAULT_EMBEDDING_DIMS,
  getVoyageEmbeddingDims,
} from "../../src/adapters/voyage-embedding.ts";

const REPO_ROOT = path.resolve(import.meta.dir, "../../..");

// ---------------------------------------------------------------------------
// Filesystem walker — no glob dependency. Skips node_modules, dist, .git,
// uploads, terraform .terraform caches, and lockfiles.
// ---------------------------------------------------------------------------

const SKIP_DIRS = new Set([
  "node_modules",
  "dist",
  ".git",
  ".venv",
  "venv",
  ".bun",
  "terraform.tfstate.d",
  ".terraform",
]);

function walk(dir: string, predicate: (rel: string) => boolean, acc: string[] = []): string[] {
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return acc;
  }
  for (const name of entries) {
    if (SKIP_DIRS.has(name)) continue;
    const full = path.join(dir, name);
    let stat;
    try {
      stat = statSync(full);
    } catch {
      continue;
    }
    if (stat.isDirectory()) {
      walk(full, predicate, acc);
    } else if (stat.isFile()) {
      const rel = path.relative(REPO_ROOT, full).replace(/\\/g, "/");
      if (predicate(rel)) acc.push(rel);
    }
  }
  return acc;
}

const TS_FILES = walk(REPO_ROOT, (rel) => rel.endsWith(".ts") && !rel.endsWith(".d.ts"));
const SH_FILES = walk(REPO_ROOT, (rel) => rel.endsWith(".sh"));

function read(rel: string): string {
  return readFileSync(path.join(REPO_ROOT, rel), "utf8");
}

// ---------------------------------------------------------------------------
// Allowlists
// ---------------------------------------------------------------------------

const ENV_READER_ALLOWLIST = [
  "api/src/adapters/voyage-embedding.ts",
];

const BODY_LITERAL_ALLOWLIST = [
  "api/src/adapters/voyage-embedding.ts",
  "api/scripts/voyage-print.ts",
  // Test files contain expected-body literals to assert on; allowed.
  "api/tests/unit/voyage-embedding-request.test.ts",
  "api/tests/unit/voyage-preflight-body-parity.test.ts",
  "api/tests/unit/voyage-ssot-guard.test.ts",
];

const BUILD_BODY_IMPORTER_ALLOWLIST = [
  "api/src/adapters/voyage-embedding.ts",
  "api/src/lib/embed-query.ts",
  "api/scripts/voyage-print.ts",
  "db-seeding/seed-embeddings.ts",
  "db-seeding/reembed-mismatched.ts",
  "db-seeding/probe-voyage-multimodal.ts",
  "api/tests/unit/voyage-embedding-request.test.ts",
  "api/tests/unit/voyage-preflight-body-parity.test.ts",
  "api/tests/unit/voyage-ssot-guard.test.ts",
];

// ---------------------------------------------------------------------------
// (a) No process.env.VOYAGE_* outside the TS SSOT
// ---------------------------------------------------------------------------

describe("voyage SSOT — env reads confined to adapter", () => {
  test("no process.env.VOYAGE_* outside api/src/adapters/voyage-embedding.ts", () => {
    const re = /process\.env\.VOYAGE_[A-Z0-9_]+/;
    const hits = TS_FILES.filter((rel) => {
      if (ENV_READER_ALLOWLIST.includes(rel)) return false;
      // Tests that intentionally override VOYAGE_* env vars are fine —
      // they read via process.env to save+restore, which is the pattern.
      if (rel.startsWith("api/tests/")) return false;
      return re.test(read(rel));
    });
    expect(hits).toEqual([]);
  });

  test("no process.env.EMBEDDING_DIMENSIONS in TS source (must use getVoyageEmbeddingDims())", () => {
    const re = /process\.env\.EMBEDDING_DIMENSIONS/;
    const hits = TS_FILES.filter((rel) => {
      if (rel.startsWith("api/tests/")) return false;
      return re.test(read(rel));
    });
    expect(hits).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// (b) No hand-rolled multimodal body literal outside the SSOT
// ---------------------------------------------------------------------------

describe("voyage SSOT — body literal confined to adapter + one-shot", () => {
  test('no `"inputs":[{"content"` literal outside the SSOT allowlist', () => {
    const re = /"inputs"\s*:\s*\[\s*\{\s*"content"/;
    const hits = TS_FILES.filter((rel) => {
      if (BODY_LITERAL_ALLOWLIST.includes(rel)) return false;
      return re.test(read(rel));
    });
    expect(hits).toEqual([]);
  });

  test("no Python literal `'inputs':[{'content'` outside the probe (handled by voyage-print shellout)", () => {
    // Python uses single quotes after json.dumps round-trip in our scripts;
    // anything left in py files signals a hand-roll we missed.
    const pyFiles = walk(REPO_ROOT, (rel) => rel.endsWith(".py"));
    const re = /['"]inputs['"]\s*:\s*\[\s*\{\s*['"]content['"]/;
    const hits = pyFiles.filter((rel) => re.test(read(rel)));
    expect(hits).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// (c) buildVoyageRequestBody imports confined to allowlist
// ---------------------------------------------------------------------------

describe("voyage SSOT — buildVoyageRequestBody importers", () => {
  test("buildVoyageRequestBody is imported only from the allowlist", () => {
    const re = /import\s*\{[^}]*\bbuildVoyageRequestBody\b/;
    const hits = TS_FILES.filter((rel) => {
      if (BUILD_BODY_IMPORTER_ALLOWLIST.includes(rel)) return false;
      return re.test(read(rel));
    });
    expect(hits).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// (d, e) bash <-> TS parity for models + dims
// ---------------------------------------------------------------------------

describe("voyage SSOT — bash <-> TS parity", () => {
  test("bash voyage_supported_models matches SUPPORTED_VOYAGE_MODELS", () => {
    const bashOut = execSync(
      "bash -c 'source deploy/scripts/_voyage-config.sh && voyage_supported_models'",
      { cwd: REPO_ROOT },
    ).toString();
    expect(bashOut.trim().split(/\s+/).sort()).toEqual([...SUPPORTED_VOYAGE_MODELS].sort());
  });

  test("bash voyage_embedding_dims matches getVoyageEmbeddingDims()", () => {
    // No VOYAGE_OUTPUT_DIM in the test env → both resolve to the default.
    const bashOut = execSync(
      "bash -c 'unset VOYAGE_OUTPUT_DIM; source deploy/scripts/_voyage-config.sh && voyage_embedding_dims'",
      { cwd: REPO_ROOT },
    ).toString();
    expect(Number(bashOut.trim())).toBe(getVoyageEmbeddingDims());
  });

  test("bash voyage_canonical_body matches buildVoyageRequestBody byte-for-byte", () => {
    const bashOut = execSync(
      `bash -c 'source deploy/scripts/_voyage-config.sh && voyage_canonical_body "preflight ping" document'`,
      { cwd: REPO_ROOT },
    ).toString();
    // Import here so the test crashes loudly (rather than silently
    // matching '') if the body builder regression-deletes the function.
    const { buildVoyageRequestBody, textToMultimodal } =
      require("../../src/adapters/voyage-embedding.ts") as typeof import("../../src/adapters/voyage-embedding.ts");
    const tsOut = buildVoyageRequestBody([textToMultimodal("preflight ping")], "document");
    expect(bashOut).toBe(tsOut);
  });
});

// ---------------------------------------------------------------------------
// (f) Terraform <-> TS parity for the embedding-dim default.
// The dim is now configurable via VOYAGE_OUTPUT_DIM: the seed null_resource
// passes `EMBEDDING_DIMENSIONS = tostring(var.voyage_output_dim)`, and the
// `voyage_output_dim` variable default is what must stay in lockstep with the
// TS default (Terraform can't shell out to voyage-print.ts to resolve it).
// ---------------------------------------------------------------------------

describe("voyage SSOT — terraform <-> TS parity for embedding dim", () => {
  // Variable declarations live in the env's variables.tf; the seed
  // null_resource wiring lives in main.tf.
  const TF_ENVS = [
    {
      vars: "deploy/terraform/envs/ec2/variables.tf",
      main: "deploy/terraform/envs/ec2/main.tf",
    },
    {
      vars: "deploy/terraform/envs/local/variables.tf",
      main: "deploy/terraform/envs/local/main.tf",
    },
  ];

  for (const { vars, main } of TF_ENVS) {
    test(`${vars} declares variable "voyage_output_dim" default = ${VOYAGE_DEFAULT_EMBEDDING_DIMS}`, () => {
      const src = read(vars);
      const m = src.match(
        /variable\s+"voyage_output_dim"\s*\{[^}]*?\bdefault\s*=\s*(\d+)/s,
      );
      expect(
        m,
        `${vars} must declare a voyage_output_dim variable with a numeric default (TF can't shell out; the default is pinned by guard test)`,
      ).not.toBeNull();
      expect(Number(m![1])).toBe(VOYAGE_DEFAULT_EMBEDDING_DIMS);
    });

    test(`${main} wires EMBEDDING_DIMENSIONS to var.voyage_output_dim (not a hardcoded literal)`, () => {
      const src = read(main);
      // Must derive from the variable, never a bare numeric literal.
      expect(
        /EMBEDDING_DIMENSIONS\s*=\s*tostring\(var\.voyage_output_dim\)/.test(src),
        `${main} must set EMBEDDING_DIMENSIONS = tostring(var.voyage_output_dim)`,
      ).toBe(true);
      expect(
        /EMBEDDING_DIMENSIONS\s*=\s*"\d+"/.test(src),
        `${main} must NOT hardcode EMBEDDING_DIMENSIONS to a numeric literal`,
      ).toBe(false);
      // And the seeder must receive VOYAGE_OUTPUT_DIM so getVoyageEmbeddingDims() agrees.
      expect(
        /VOYAGE_OUTPUT_DIM\s*=\s*tostring\(var\.voyage_output_dim\)/.test(src),
        `${main} must pass VOYAGE_OUTPUT_DIM = tostring(var.voyage_output_dim) to the seed null_resource`,
      ).toBe(true);
    });

    test(`${main} carries the SSOT-pin comment near the wiring`, () => {
      const src = read(main);
      const ok =
        /VOYAGE_DEFAULT_EMBEDDING_DIMS/.test(src) ||
        /voyage-embedding\.ts/.test(src);
      expect(
        ok,
        `${main} should mention VOYAGE_DEFAULT_EMBEDDING_DIMS or voyage-embedding.ts near the wiring`,
      ).toBe(true);
    });
  }
});

// ---------------------------------------------------------------------------
// (g) No stale ${EMBEDDING_DIMENSIONS:-1024} fallback in deploy/
// ---------------------------------------------------------------------------

describe("voyage SSOT — deploy/ scripts must not hand-roll EMBEDDING_DIMENSIONS", () => {
  test("no `${EMBEDDING_DIMENSIONS:-1024}` fallback in deploy/", () => {
    const deployShFiles = SH_FILES.filter((rel) => rel.startsWith("deploy/"));
    const re = /\$\{EMBEDDING_DIMENSIONS:-1024\}/;
    const hits = deployShFiles.filter((rel) => re.test(read(rel)));
    expect(hits).toEqual([]);
  });

  // `_preflight-checks.sh` is the bash mirror of THIS test file — it greps
  // for the same patterns and so legitimately contains them as string
  // literals inside `pf_check_voyage_ssot_only_source`. Exclude it from the
  // grep-style guards below; the bash function itself self-tests via
  // `bash deploy/scripts/_preflight-checks.sh --self-test`.
  const PREFLIGHT_PATH = "deploy/scripts/_preflight-checks.sh";

  test("no `EMBEDDING_DIMENSIONS=1024` literal in deploy/ shell scripts", () => {
    const deployShFiles = SH_FILES.filter(
      (rel) => rel.startsWith("deploy/") && rel !== PREFLIGHT_PATH,
    );
    const re = /\bEMBEDDING_DIMENSIONS=["']?1024["']?\b/;
    const hits = deployShFiles.filter((rel) => re.test(read(rel)));
    expect(hits).toEqual([]);
  });

  test("no stale VOYAGE_REQUEST_FORMAT references in deploy/ shell scripts", () => {
    const deployShFiles = SH_FILES.filter(
      (rel) => rel.startsWith("deploy/") && rel !== PREFLIGHT_PATH,
    );
    const re = /VOYAGE_REQUEST_FORMAT/;
    const hits = deployShFiles.filter((rel) => re.test(read(rel)));
    expect(hits).toEqual([]);
  });

  test("VOYAGE_OUTPUT_DIM appears in deploy shell scripts only as controlled env pass-through", () => {
    const deployShFiles = SH_FILES.filter(
      (rel) => rel.startsWith("deploy/") && rel !== PREFLIGHT_PATH,
    );
    const allowedPassThrough = new Set([
      "deploy/scripts/deploy-local.sh",
      "deploy/scripts/deploy-project.sh",
      "deploy/scripts/_agents-common.sh",
      "deploy/scripts/_env-live.sh",
    ]);
    const re = /VOYAGE_OUTPUT_DIM/;
    const hits = deployShFiles.filter((rel) => {
      if (!re.test(read(rel))) return false;
      return !allowedPassThrough.has(rel);
    });
    expect(hits).toEqual([]);
  });
});
