import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import { resolveConfigRoot } from "./paths.ts";
import { listSkillDiscovery } from "./skill-loader.ts";
import { agentFrontmatterSchema } from "./schemas.ts";
import { logger } from "./logger.ts";

export type AgentListItem = {
  id: string;
  name: string;
  description: string;
};

export type AgentDetail = AgentListItem & {
  skills: string[];
  tools: string[];
  model: string;
  maxTokens: number;
  temperature: number;
  handoffs: { label: string; agent: string; prompt?: string }[];
  memory?: { shortTerm?: boolean; longTerm?: boolean; longTermCollection?: string };
};

export type SkillListItem = {
  name: string;
  description: string;
  version?: string;
  tags: string[];
};

// ---------------------------------------------------------------------------
// Mtime-based file cache
//
// On each request we do one fs.statSync per file rather than a full
// readFileSync + parse. Cache entries are invalidated when the file's mtime
// changes. The directory listing (listAgents) also tracks the directory mtime
// so that adding/removing .agent.md files invalidates the list cache.
// ---------------------------------------------------------------------------

type FileCache<T> = { value: T; mtimeMs: number };

/** Cache for individual agent file parse results, keyed by absolute path. */
const agentDetailCache = new Map<string, FileCache<AgentDetail | null>>();
const agentPersonaCache = new Map<string, FileCache<string | undefined>>();

/** Cache for the agents directory listing. */
let agentListCache: FileCache<AgentListItem[]> | null = null;

function fileMtimeMs(filePath: string): number {
  try {
    return fs.statSync(filePath).mtimeMs;
  } catch {
    return -1;
  }
}

function dirMtimeMs(dirPath: string): number {
  try {
    return fs.statSync(dirPath).mtimeMs;
  } catch {
    return -1;
  }
}

/** Invalidate all config caches (used by tests that write new agent files). */
export function clearConfigCacheForTests(): void {
  agentDetailCache.clear();
  agentPersonaCache.clear();
  agentListCache = null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function agentsDir(): string {
  return path.join(resolveConfigRoot(), "agents");
}

function resolveAgentFile(agentId: string): string | undefined {
  const dir = agentsDir();
  if (!fs.existsSync(dir)) return undefined;
  const exact = path.join(dir, `${agentId}.agent.md`);
  if (fs.existsSync(exact)) return exact;
  const alt = fs
    .readdirSync(dir)
    .find((f) => f.endsWith(".agent.md") && f.startsWith(agentId));
  if (alt) {
    const full = path.join(dir, alt);
    return fs.existsSync(full) ? full : undefined;
  }
  return undefined;
}

function parseAgentDetail(filePath: string): AgentDetail | null {
  const raw = fs.readFileSync(filePath, "utf8");
  const { data } = matter(raw);
  const parsed = agentFrontmatterSchema.safeParse(data);
  if (!parsed.success) {
    logger.warn("[agents] invalid frontmatter", { file: filePath, errors: parsed.error.flatten() });
    return null;
  }
  const fm = parsed.data;
  return {
    id: fm.id,
    name: fm.name,
    description: fm.description,
    skills: fm.skills,
    tools: fm.tools,
    model: fm.model ?? "",
    maxTokens: fm.maxTokens,
    temperature: fm.temperature,
    handoffs: fm.handoffs,
    memory: fm.memory,
  };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export function listAgents(): AgentListItem[] {
  const dir = agentsDir();
  if (!fs.existsSync(dir)) return [];

  const currentMtime = dirMtimeMs(dir);
  if (agentListCache && agentListCache.mtimeMs === currentMtime) {
    return agentListCache.value;
  }

  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".agent.md"));
  const out: AgentListItem[] = [];
  for (const file of files) {
    const full = path.join(dir, file);
    const detail = parseAgentDetail(full);
    if (detail) out.push({ id: detail.id, name: detail.name, description: detail.description });
  }
  const sorted = out.sort((a, b) => a.id.localeCompare(b.id));
  agentListCache = { value: sorted, mtimeMs: currentMtime };
  logger.debug("[agents] list cache refreshed", { count: sorted.length });
  return sorted;
}

export function getAgent(agentId: string): AgentDetail | undefined {
  const target = resolveAgentFile(agentId);
  if (!target) return undefined;

  const currentMtime = fileMtimeMs(target);
  const cached = agentDetailCache.get(target);
  if (cached && cached.mtimeMs === currentMtime) {
    return cached.value ?? undefined;
  }

  const detail = parseAgentDetail(target);
  agentDetailCache.set(target, { value: detail, mtimeMs: currentMtime });
  if (detail) logger.debug("[agents] detail cache refreshed", { agentId });
  return detail ?? undefined;
}

/** Persona (markdown body after YAML frontmatter), cached by file mtime. */
export function loadAgentPersona(agentId: string): string | undefined {
  const target = resolveAgentFile(agentId);
  if (!target) return undefined;

  const currentMtime = fileMtimeMs(target);
  const cached = agentPersonaCache.get(target);
  if (cached && cached.mtimeMs === currentMtime) {
    return cached.value;
  }

  const raw = fs.readFileSync(target, "utf8");
  const { content } = matter(raw);
  const persona = content.trim() || undefined;
  agentPersonaCache.set(target, { value: persona, mtimeMs: currentMtime });
  return persona;
}

export function listSkills(): SkillListItem[] {
  return listSkillDiscovery()
    .map((s) => ({
      name: s.name,
      description: s.description,
      version: s.version,
      tags: [] as string[],
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}
