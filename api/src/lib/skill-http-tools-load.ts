import fs from "node:fs";
import path from "node:path";
import { resolveConfigRoot } from "./paths.ts";
import { expandEnvTemplate } from "./http-tools-load.ts";
import {
  skillHttpToolsFileSchema,
  type HttpToolDefinition,
} from "./http-tools-schema.ts";

const RESERVED_LOCAL_TOOL_NAMES = new Set([
  "activate_skill",
  "read_skill_resource",
  "run_skill_script",
  "mongodb_query",
  "mongodb_vector_search",
  "bedrock_kb_retrieve",
  "generate_embedding",
]);

function skillsRoot(): string {
  return path.join(resolveConfigRoot(), "skills");
}

const cache = new Map<string, { mtimeMs: number; tools: HttpToolDefinition[] }>();

function skillHttpToolsPath(skillName: string): string {
  return path.join(skillsRoot(), skillName, "http-tools.json");
}

/**
 * Parse `skillFolder/toolLocalName` using the agent's allowed skill ids (longest match first).
 * Local name must not contain `/`.
 */
export function parseSkillScopedHttpToolName(
  fullName: string,
  allowedSkillIds: ReadonlySet<string>,
): { skillName: string; localToolName: string } | null {
  const candidates = [...allowedSkillIds].sort((a, b) => b.length - a.length);
  for (const sid of candidates) {
    const prefix = `${sid}/`;
    if (fullName.startsWith(prefix)) {
      const rest = fullName.slice(prefix.length);
      if (rest.length > 0 && !rest.includes("/")) {
        return { skillName: sid, localToolName: rest };
      }
    }
  }
  return null;
}

/**
 * Load `config/skills/<skillName>/http-tools.json` (cached by mtime).
 */
export function loadSkillHttpToolsDefinitions(skillName: string, force = false): HttpToolDefinition[] {
  const file = skillHttpToolsPath(skillName);
  if (!force) {
    const hit = cache.get(skillName);
    if (hit) {
      try {
        const st = fs.statSync(file);
        if (st.mtimeMs === hit.mtimeMs) return hit.tools;
      } catch {
        cache.delete(skillName);
      }
    }
  }

  if (!fs.existsSync(file)) {
    cache.set(skillName, { mtimeMs: 0, tools: [] });
    return [];
  }

  let raw: string;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    cache.set(skillName, { mtimeMs: 0, tools: [] });
    return [];
  }

  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch (e) {
    console.warn(`[skill-http-tools] invalid JSON in ${file}:`, e);
    cache.set(skillName, { mtimeMs: 0, tools: [] });
    return [];
  }

  const parsed = skillHttpToolsFileSchema.safeParse(json);
  if (!parsed.success) {
    console.warn(`[skill-http-tools] schema errors in ${file}:`, parsed.error.flatten());
    cache.set(skillName, { mtimeMs: 0, tools: [] });
    return [];
  }

  const seen = new Set<string>();
  const tools: HttpToolDefinition[] = [];
  for (const t of parsed.data.tools) {
    const n = t.name.trim();
    if (RESERVED_LOCAL_TOOL_NAMES.has(n)) {
      console.warn(`[skill-http-tools] skipping reserved local name "${n}" in ${file}`);
      continue;
    }
    if (seen.has(n)) {
      console.warn(`[skill-http-tools] duplicate "${n}" in ${file} — keeping first`);
      continue;
    }
    seen.add(n);
    tools.push(t);
  }

  let mtimeMs = 0;
  try {
    mtimeMs = fs.statSync(file).mtimeMs;
  } catch {
    /* ignore */
  }
  cache.set(skillName, { mtimeMs, tools });
  return tools;
}

export function findSkillHttpToolDefinition(
  skillName: string,
  localToolName: string,
): HttpToolDefinition | undefined {
  return loadSkillHttpToolsDefinitions(skillName).find((d) => d.name === localToolName);
}

/** For GET /http-tools: list all skill-scoped tools (folder names on disk). */
export function listAllSkillHttpToolDescriptors(): {
  skillName: string;
  tools: {
    localName: string;
    description: string;
    method: string;
    urlConfigured: boolean;
    headerKeys: string[];
    passThroughBody: boolean;
    parameterNames: string[];
  }[];
}[] {
  const root = skillsRoot();
  if (!fs.existsSync(root)) return [];
  const out: {
    skillName: string;
    tools: {
      localName: string;
      description: string;
      method: string;
      urlConfigured: boolean;
      headerKeys: string[];
      passThroughBody: boolean;
      parameterNames: string[];
    }[];
  }[] = [];
  for (const ent of fs.readdirSync(root, { withFileTypes: true })) {
    if (!ent.isDirectory()) continue;
    const skillName = ent.name;
    const defs = loadSkillHttpToolsDefinitions(skillName, true);
    if (defs.length === 0) continue;
    out.push({
      skillName,
      tools: defs.map((d) => ({
        localName: d.name,
        description: d.description,
        method: d.method,
        urlConfigured: Boolean(expandEnvTemplate(d.url).trim()),
        headerKeys: d.headers ? Object.keys(d.headers) : [],
        passThroughBody: Boolean(d.passThroughBody),
        parameterNames: d.parameters?.map((p) => p.name) ?? [],
      })),
    });
  }
  return out.sort((a, b) => a.skillName.localeCompare(b.skillName));
}

export function resetSkillHttpToolsCacheForTests(): void {
  cache.clear();
}
