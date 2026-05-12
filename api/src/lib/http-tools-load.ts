import fs from "node:fs";
import path from "path";
import { resolveConfigRoot } from "./paths.ts";
import { httpToolsFileSchema, type HttpToolDefinition, type HttpToolsFile } from "./http-tools-schema.ts";

const RESERVED_TOOL_NAMES = new Set([
  "activate_skill",
  "read_skill_resource",
  "run_skill_script",
  "mongodb_query",
  "mongodb_vector_search",
  "bedrock_kb_retrieve",
  "generate_embedding",
]);

let cached: { mtimeMs: number; data: HttpToolsFile } | null = null;
let cachedPath: string | null = null;

function configPath(): string {
  const override = process.env.HTTP_TOOLS_CONFIG_PATH?.trim();
  if (override) return path.resolve(override);
  return path.join(resolveConfigRoot(), "http-tools.json");
}

function readFileIfExists(file: string): string | null {
  try {
    if (!fs.existsSync(file)) return null;
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

/** Replace `${VAR}` with `process.env.VAR` (missing → empty string). */
export function expandEnvTemplate(template: string): string {
  return template.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, key: string) => {
    return process.env[key]?.trim() ?? "";
  });
}

/**
 * Load and validate `config/http-tools.json` (or `HTTP_TOOLS_CONFIG_PATH`).
 * Caches by mtime unless `force` is true.
 */
export function loadHttpToolsFile(force = false): HttpToolsFile {
  const file = configPath();
  if (!force && cached && cachedPath === file) {
    try {
      const st = fs.statSync(file);
      if (st.mtimeMs === cached.mtimeMs) return cached.data;
    } catch {
      cached = null;
    }
  }

  const raw = readFileIfExists(file);
  if (!raw) {
    const empty: HttpToolsFile = { tools: [] };
    cached = { mtimeMs: 0, data: empty };
    cachedPath = file;
    return empty;
  }

  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch (e) {
    console.warn(`[http-tools] invalid JSON in ${file}:`, e);
    const empty: HttpToolsFile = { tools: [] };
    cached = { mtimeMs: 0, data: empty };
    cachedPath = file;
    return empty;
  }

  const parsed = httpToolsFileSchema.safeParse(json);
  if (!parsed.success) {
    console.warn(`[http-tools] schema errors in ${file}:`, parsed.error.flatten());
    const empty: HttpToolsFile = { tools: [] };
    cached = { mtimeMs: 0, data: empty };
    cachedPath = file;
    return empty;
  }

  const data = parsed.data;
  const seen = new Set<string>();
  const tools: HttpToolDefinition[] = [];
  for (const t of data.tools) {
    const n = t.name.trim();
    if (RESERVED_TOOL_NAMES.has(n)) {
      console.warn(`[http-tools] skipping reserved name "${n}" in ${file}`);
      continue;
    }
    if (seen.has(n)) {
      console.warn(`[http-tools] duplicate tool "${n}" in ${file} — keeping first`);
      continue;
    }
    seen.add(n);
    tools.push(t);
  }

  const normalized: HttpToolsFile = {
    security: data.security,
    tools,
  };

  let mtimeMs = 0;
  try {
    mtimeMs = fs.statSync(file).mtimeMs;
  } catch {
    /* ignore */
  }
  cached = { mtimeMs, data: normalized };
  cachedPath = file;
  return normalized;
}

export function listHttpToolDefinitions(): HttpToolDefinition[] {
  return loadHttpToolsFile().tools;
}

/** Test helper: clear load cache. */
export function resetHttpToolsLoadCacheForTests(): void {
  cached = null;
  cachedPath = null;
}
