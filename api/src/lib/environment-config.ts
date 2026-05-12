import fs from "node:fs";
import path from "node:path";
import YAML from "yaml";
import { z } from "zod";
import { logger } from "./logger.ts";
import { resolveConfigRoot } from "./paths.ts";

const environmentYamlSchema = z.object({
  api: z
    .object({
      port: z.number().int().positive().optional(),
      corsOrigins: z.array(z.string()).optional(),
    })
    .optional(),
});

export type EnvironmentYamlDefaults = z.infer<typeof environmentYamlSchema>;

let cached: EnvironmentYamlDefaults | null | undefined;

/** Test hook — clears memoized YAML parse (api/tests/unit). */
export function resetEnvironmentYamlCacheForTests(): void {
  cached = undefined;
}

function loadFromDisk(): EnvironmentYamlDefaults | null {
  const file = path.join(resolveConfigRoot(), "environment.yaml");
  if (!fs.existsSync(file)) {
    return null;
  }
  try {
    const raw = fs.readFileSync(file, "utf8");
    const parsed: unknown = YAML.parse(raw);
    const out = environmentYamlSchema.safeParse(parsed);
    if (!out.success) {
      logger.warn("[environment-config] environment.yaml failed validation; ignoring file", {
        issues: out.error.issues,
      });
      return null;
    }
    return out.data;
  } catch (e) {
    logger.warn("[environment-config] failed to read environment.yaml; ignoring file", {
      error: e instanceof Error ? e.message : String(e),
    });
    return null;
  }
}

/** Parsed `config/environment.yaml` (null if missing or invalid). Memoized per process. */
export function getEnvironmentYamlDefaults(): EnvironmentYamlDefaults | null {
  if (cached === undefined) {
    cached = loadFromDisk();
  }
  return cached;
}

const DEFAULT_CORS_ORIGINS = ["http://localhost:8501", "http://127.0.0.1:8501"];

/**
 * Listen port: `PORT` / `API_PORT` override `config/environment.yaml` `api.port`, then 3000.
 */
export function resolveApiListenPort(env: NodeJS.ProcessEnv = process.env): number {
  const fromEnv = env.PORT ?? env.API_PORT;
  if (fromEnv !== undefined && String(fromEnv).trim() !== "") {
    const n = Number(fromEnv);
    if (!Number.isNaN(n) && n > 0) {
      return n;
    }
  }
  const yaml = getEnvironmentYamlDefaults();
  const p = yaml?.api?.port;
  if (p !== undefined) {
    return p;
  }
  return 3000;
}

/**
 * CORS allowlist: `CORS_ORIGINS` (comma-separated) overrides `api.corsOrigins` from YAML,
 * then built-in Streamlit defaults.
 */
export function resolveCorsOrigins(env: NodeJS.ProcessEnv = process.env): string[] {
  const raw = env.CORS_ORIGINS?.trim();
  if (raw) {
    return raw.split(",").map((s) => s.trim()).filter(Boolean);
  }
  const fromYaml = getEnvironmentYamlDefaults()?.api?.corsOrigins;
  if (fromYaml?.length) {
    return [...fromYaml];
  }
  return [...DEFAULT_CORS_ORIGINS];
}
