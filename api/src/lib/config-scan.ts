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
type VersionedCache<T> = { value: T; version: string };

/** Cache for individual agent file parse results, keyed by absolute path. */
const agentDetailCache = new Map<string, FileCache<AgentDetail | null>>();
const agentPersonaCache = new Map<string, FileCache<string | undefined>>();

/** Cache for the agents directory listing. */
let agentListCache: VersionedCache<AgentListItem[]> | null = null;

/**
 * Cache for the post-`withDynamicHandoffs` orchestrator object.
 * Keyed on the agents directory version string (which encodes the mtime of
 * every `.agent.md` file) so the cached reference is invalidated whenever any
 * agent file changes. Storing the final object here means successive calls to
 * `getAgent("orchestrator")` return the SAME reference as long as nothing has
 * changed — required for the template cache's identity check in
 * `create-strands-agent.ts`.
 */
let orchestratorWithHandoffsCache: VersionedCache<AgentDetail> | null = null;

function fileMtimeMs(filePath: string): number {
  try {
    return fs.statSync(filePath).mtimeMs;
  } catch {
    return -1;
  }
}

function agentsDirVersion(dirPath: string): string {
  try {
    return fs
      .readdirSync(dirPath)
      .filter((f) => f.endsWith(".agent.md"))
      .sort()
      .map((file) => `${file}:${fileMtimeMs(path.join(dirPath, file))}`)
      .join("|");
  } catch {
    return "";
  }
}

/** Invalidate all config caches after a config refresh. */
export function clearConfigCache(): void {
  agentDetailCache.clear();
  agentPersonaCache.clear();
  agentListCache = null;
  orchestratorWithHandoffsCache = null;
}

/** Invalidate all config caches (used by tests that write new agent files). */
export const clearConfigCacheForTests = clearConfigCache;

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

function isOrchestrator(agentId: string): boolean {
  return agentId === "orchestrator";
}

function handoffPromptForAgent(agent: AgentDetail): string {
  const parts = [agent.description.trim()];
  if (agent.skills.length > 0) parts.push(`Skills: ${agent.skills.join(", ")}.`);
  if (agent.tools.length > 0) parts.push(`Tools: ${agent.tools.join(", ")}.`);
  const personaExcerpt = loadAgentPersona(agent.id)?.replace(/\s+/g, " ").trim().slice(0, 1000);
  if (personaExcerpt) parts.push(`Instructions excerpt: ${personaExcerpt}`);
  return parts.filter(Boolean).join(" ");
}

function dynamicHandoffsForOrchestrator(orchestratorId = "orchestrator"): AgentDetail["handoffs"] {
  return listAgents()
    .filter((agent) => agent.id !== orchestratorId)
    .map((agent) => getAgent(agent.id))
    .filter((agent): agent is AgentDetail => Boolean(agent))
    .map((agent) => ({
      label: agent.name,
      agent: agent.id,
      prompt: handoffPromptForAgent(agent),
    }));
}

function withDynamicHandoffs(detail: AgentDetail): AgentDetail {
  if (!isOrchestrator(detail.id)) return detail;
  return {
    ...detail,
    handoffs: dynamicHandoffsForOrchestrator(detail.id),
  };
}

function withDynamicSpecialistRoster(agentId: string, persona: string | undefined): string | undefined {
  if (!isOrchestrator(agentId) || !persona) return persona;
  const handoffs = dynamicHandoffsForOrchestrator(agentId);
  if (handoffs.length === 0) return persona;

  const roster = handoffs
    .map((h) => `- **${h.agent}** (${h.label}): ${h.prompt ?? ""}`.trim())
    .join("\n");
  return (
    `${persona}\n\n` +
    `## Available specialist agents (generated from config/agents)\n\n` +
    `Route only to one of these current specialist agent IDs. This roster is generated ` +
    `at runtime from \`config/agents/*.agent.md\`, so newly added specialists are ` +
    `available without editing this file.\n\n${roster}`
  );
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export function listAgents(): AgentListItem[] {
  const dir = agentsDir();
  if (!fs.existsSync(dir)) return [];

  const currentVersion = agentsDirVersion(dir);
  if (agentListCache && agentListCache.version === currentVersion) {
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
  agentListCache = { value: sorted, version: currentVersion };
  logger.debug("[agents] list cache refreshed", { count: sorted.length });
  return sorted;
}

export function getAgent(agentId: string): AgentDetail | undefined {
  const target = resolveAgentFile(agentId);
  if (!target) return undefined;

  const currentMtime = fileMtimeMs(target);
  const cached = agentDetailCache.get(target);
  // Refresh the base detail cache when the file mtime changes.
  // For the orchestrator we also maintain a *separate* post-handoffs cache keyed
  // on the full agents-directory version string (all file mtimes) so that a
  // non-orchestrator agent changing its file also invalidates the orchestrator's
  // cached handoffs — without requiring the orchestrator file itself to change.
  // This gives downstream callers (notably create-strands-agent.ts's templateCache
  // which uses object identity to detect stale agent config) a stable reference.
  const detailCacheHit = cached && cached.mtimeMs === currentMtime;
  if (!detailCacheHit) {
    const detail = parseAgentDetail(target);
    agentDetailCache.set(target, { value: detail, mtimeMs: currentMtime });
    if (detail) logger.debug("[agents] detail cache refreshed", { agentId });
    // Invalidate the orchestrator post-handoffs cache whenever the base detail
    // is refreshed (orchestrator itself changed or a new file triggered a reload).
    if (isOrchestrator(agentId)) orchestratorWithHandoffsCache = null;
  }

  const detail = agentDetailCache.get(target)?.value;
  if (!detail) return undefined;

  if (!isOrchestrator(agentId)) return detail;

  // For the orchestrator, `withDynamicHandoffs` creates a new object on every
  // call. Cache the result keyed on the agents directory version so the
  // template cache (`create-strands-agent.ts`) gets a stable reference.
  const dirVersion = agentsDirVersion(agentsDir());
  if (orchestratorWithHandoffsCache && orchestratorWithHandoffsCache.version === dirVersion) {
    return orchestratorWithHandoffsCache.value;
  }
  const withHandoffs = withDynamicHandoffs(detail);
  orchestratorWithHandoffsCache = { value: withHandoffs, version: dirVersion };
  return withHandoffs;
}

/** Persona (markdown body after YAML frontmatter), cached by file mtime. */
export function loadAgentPersona(agentId: string): string | undefined {
  const target = resolveAgentFile(agentId);
  if (!target) return undefined;

  const currentMtime = fileMtimeMs(target);
  const cached = agentPersonaCache.get(target);
  if (cached && cached.mtimeMs === currentMtime) {
    return withDynamicSpecialistRoster(agentId, cached.value);
  }

  const raw = fs.readFileSync(target, "utf8");
  const { content } = matter(raw);
  const persona = content.trim() || undefined;
  agentPersonaCache.set(target, { value: persona, mtimeMs: currentMtime });
  return withDynamicSpecialistRoster(agentId, persona);
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