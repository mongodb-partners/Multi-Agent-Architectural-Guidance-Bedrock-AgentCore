/**
 * Architecture-guard tests that fail CI if the Atlas project IP access list
 * regresses to a public-internet path.
 *
 * Security requirement: Atlas must be reachable only from where it was created
 * (the operator / deploy machine) or the peered VPC — NEVER 0.0.0.0/0.
 *
 * These tests statically scan the Terraform so a future edit that reintroduces
 * `cidr_block = "0.0.0.0/0"` on an `mongodbatlas_project_ip_access_list` (or
 * drops the operator-IP wiring) lights up in the same PR.
 *
 * Companion live-Atlas guard: `pf_check_atlas_no_public_ip_access_list` in
 * `deploy/scripts/_preflight-checks.sh` (project-post-apply + local-post-apply).
 */

import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const REPO_ROOT = path.resolve(import.meta.dir, "../../..");

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

function read(rel: string): string {
  return readFileSync(path.join(REPO_ROOT, rel), "utf8");
}

const TF_FILES = walk(REPO_ROOT, (rel) => rel.endsWith(".tf"));

/**
 * Extract the body of each `mongodbatlas_project_ip_access_list` resource block
 * from a .tf file. Brace-balanced so we don't bleed into the next resource.
 */
function ipAccessListBlocks(src: string): string[] {
  const blocks: string[] = [];
  const marker = /resource\s+"mongodbatlas_project_ip_access_list"\s+"[^"]+"\s*\{/g;
  let m: RegExpExecArray | null;
  while ((m = marker.exec(src)) !== null) {
    let depth = 1;
    let i = m.index + m[0].length;
    const start = i;
    while (i < src.length && depth > 0) {
      const ch = src[i];
      if (ch === "{") depth++;
      else if (ch === "}") depth--;
      i++;
    }
    blocks.push(src.slice(start, i - 1));
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// (a) No mongodbatlas_project_ip_access_list anywhere may use 0.0.0.0/0
// ---------------------------------------------------------------------------

describe("Atlas IP access list — never 0.0.0.0/0", () => {
  test("no mongodbatlas_project_ip_access_list block references 0.0.0.0/0", () => {
    const offenders: string[] = [];
    for (const rel of TF_FILES) {
      const blocks = ipAccessListBlocks(read(rel));
      for (const body of blocks) {
        if (/0\.0\.0\.0\/[01]\b/.test(body)) offenders.push(rel);
      }
    }
    expect(
      [...new Set(offenders)],
      "Atlas IP access list must never be opened to 0.0.0.0/0 (or 0.0.0.0/1)",
    ).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// (b) mongodb-atlas module scopes per mode + exposes operator_ip_cidr
// ---------------------------------------------------------------------------

describe("mongodb-atlas module — scoped IP access list", () => {
  const MAIN = "deploy/terraform/modules/mongodb-atlas/main.tf";
  const VARS = "deploy/terraform/modules/mongodb-atlas/variables.tf";

  test("privatelink entry uses var.operator_ip_cidr", () => {
    const src = read(MAIN);
    const blocks = ipAccessListBlocks(src);
    const hasOperator = blocks.some(
      (b) => /var\.operator_ip_cidr/.test(b) && /network_mode\s*==\s*"privatelink"/.test(b),
    );
    expect(hasOperator, `${MAIN} must scope the privatelink entry to var.operator_ip_cidr`).toBe(true);
  });

  test("peering entry uses var.vpc_cidr", () => {
    const src = read(MAIN);
    const blocks = ipAccessListBlocks(src);
    const hasPeering = blocks.some(
      (b) => /var\.vpc_cidr/.test(b) && /network_mode\s*==\s*"peering"/.test(b),
    );
    expect(hasPeering, `${MAIN} must scope the peering entry to var.vpc_cidr`).toBe(true);
  });

  test("module declares operator_ip_cidr variable", () => {
    expect(/variable\s+"operator_ip_cidr"/.test(read(VARS))).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// (c) Every env that uses the module forwards operator_ip_cidr
// ---------------------------------------------------------------------------

describe("envs forward operator_ip_cidr to mongodb-atlas", () => {
  const ENVS = [
    "deploy/terraform/envs/ec2/main.tf",
    "deploy/terraform/envs/local/main.tf",
  ];
  for (const rel of ENVS) {
    test(`${rel} passes operator_ip_cidr into the mongodb_atlas module`, () => {
      const src = read(rel);
      // Locate the mongodb_atlas module block and assert it sets operator_ip_cidr.
      const m = src.match(/module\s+"mongodb_atlas"\s*\{[\s\S]*?\n\}/);
      expect(m, `${rel} must declare module "mongodb_atlas"`).not.toBeNull();
      expect(
        /operator_ip_cidr\s*=\s*var\.operator_ip_cidr/.test(m![0]),
        `${rel} module "mongodb_atlas" must set operator_ip_cidr = var.operator_ip_cidr`,
      ).toBe(true);
    });

    const varsRel = rel.replace("main.tf", "variables.tf");
    test(`${varsRel} declares operator_ip_cidr variable`, () => {
      expect(/variable\s+"operator_ip_cidr"/.test(read(varsRel))).toBe(true);
    });
  }
});

// ---------------------------------------------------------------------------
// (d) Atlas caps access-list comments at 80 chars (INVALID_NETWORK_PERMISSION_COMMENT)
// ---------------------------------------------------------------------------

describe("Atlas IP access list — comment length", () => {
  // The Atlas API rejects an access-list comment longer than 80 characters with
  // HTTP 400 INVALID_NETWORK_PERMISSION_COMMENT, which hard-fails terraform apply.
  // Guard every comment literal so an over-long comment is caught before deploy.
  const ATLAS_COMMENT_MAX = 80;
  test("no access-list comment exceeds 80 characters", () => {
    const offenders: string[] = [];
    for (const rel of TF_FILES) {
      for (const body of ipAccessListBlocks(read(rel))) {
        const m = body.match(/comment\s*=\s*"([^"]*)"/);
        if (m && m[1].length > ATLAS_COMMENT_MAX) {
          offenders.push(`${rel}: "${m[1]}" (${m[1].length} chars)`);
        }
      }
    }
    expect(offenders, `Atlas access-list comments must be <= ${ATLAS_COMMENT_MAX} chars`).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// (e) Live-Atlas preflight guard exists and is wired into post-apply profiles
// ---------------------------------------------------------------------------

describe("preflight guards the live Atlas access list", () => {
  const PF = "deploy/scripts/_preflight-checks.sh";

  test("pf_check_atlas_no_public_ip_access_list is defined", () => {
    expect(/pf_check_atlas_no_public_ip_access_list\s*\(\)\s*\{/.test(read(PF))).toBe(true);
  });

  test("registered in project-post-apply and local-post-apply profiles", () => {
    const src = read(PF);
    // Anchor the closing paren to the start of a line so inline parens inside
    // comments within the array body don't truncate the match.
    const post = src.match(/PREFLIGHT_PROFILE_project_post_apply=\(([\s\S]*?)\n\)/);
    const local = src.match(/PREFLIGHT_PROFILE_local_post_apply=\(([\s\S]*?)\n\)/);
    expect(post?.[1].includes("pf_check_atlas_no_public_ip_access_list")).toBe(true);
    expect(local?.[1].includes("pf_check_atlas_no_public_ip_access_list")).toBe(true);
  });
});
