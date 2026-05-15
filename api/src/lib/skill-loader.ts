import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import { resolveConfigRoot } from "./paths.ts";
import { skillFrontmatterSchema } from "./schemas.ts";
import { logger } from "./logger.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type SkillDiscovery = {
  name: string;
  description: string;
  version?: string;
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function skillsRoot(): string {
  return path.join(resolveConfigRoot(), "skills");
}

function parseSkillFrontmatter(
  skillPath: string,
  dirName: string,
): { name: string; description: string; version?: string } | undefined {
  if (!fs.existsSync(skillPath)) return undefined;
  const raw = fs.readFileSync(skillPath, "utf8");
  const { data } = matter(raw);
  const parsed = skillFrontmatterSchema.safeParse(data);
  if (!parsed.success) {
    logger.warn("[skills] invalid frontmatter", { file: skillPath, errors: parsed.error.flatten() });
    return undefined;
  }
  const meta = parsed.data.metadata;
  return {
    name: parsed.data.name || dirName,
    description: parsed.data.description.replace(/\s+/g, " ").trim(),
    version: meta?.version != null ? String(meta.version) : undefined,
  };
}

// ---------------------------------------------------------------------------
// Phase 1 — Discovery index (name + description only, ~100 tokens each)
// ---------------------------------------------------------------------------

type DiscoveryCache = { value: SkillDiscovery[]; mtimeMs: number };
let skillDiscoveryCache: DiscoveryCache | null = null;

/** Invalidate skill discovery cache (for tests that modify skill directories). */
export function clearSkillDiscoveryCacheForTests(): void {
  skillDiscoveryCache = null;
}

/** Scan all SKILL.md files and return lightweight discovery records. Cached by skills dir mtime. */
export function listSkillDiscovery(): SkillDiscovery[] {
  const root = skillsRoot();
  if (!fs.existsSync(root)) return [];

  let dirMtime = -1;
  try { dirMtime = fs.statSync(root).mtimeMs; } catch { /* */ }
  if (skillDiscoveryCache && skillDiscoveryCache.mtimeMs === dirMtime) {
    return skillDiscoveryCache.value;
  }

  const dirs = fs.readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory());
  const out: SkillDiscovery[] = [];
  for (const d of dirs) {
    const fm = parseSkillFrontmatter(path.join(root, d.name, "SKILL.md"), d.name);
    if (fm) out.push(fm);
  }
  const sorted = out.sort((a, b) => a.name.localeCompare(b.name));
  skillDiscoveryCache = { value: sorted, mtimeMs: dirMtime };
  return sorted;
}

// ---------------------------------------------------------------------------
// Phase 2 — Full SKILL.md body (loaded on activation)
//
// Cached by file mtime so specialist agents (which pre-activate every turn
// via SkillRegistry.activateAll) don't re-read disk on every chat. The
// discovery index above already had this pattern; the body cache mirrors it.
// ---------------------------------------------------------------------------

type SkillBodyCacheEntry = { mtimeMs: number; body: string | undefined };
const skillBodyCache = new Map<string, SkillBodyCacheEntry>();

/** Load the markdown body (after frontmatter) of a single skill. */
export function loadSkillInstructions(skillName: string): string | undefined {
  const skillPath = path.join(skillsRoot(), skillName, "SKILL.md");
  if (!fs.existsSync(skillPath)) return undefined;
  let mtimeMs = -1;
  try {
    mtimeMs = fs.statSync(skillPath).mtimeMs;
  } catch {
    /* fall through and re-read */
  }
  const cached = skillBodyCache.get(skillPath);
  if (cached && cached.mtimeMs === mtimeMs) return cached.body;

  const raw = fs.readFileSync(skillPath, "utf8");
  const { content } = matter(raw);
  const body = content.trim() || undefined;
  skillBodyCache.set(skillPath, { mtimeMs, body });
  return body;
}

/** Test helper: drop the SKILL.md body cache. */
export function clearSkillInstructionsCacheForTests(): void {
  skillBodyCache.clear();
}

// ---------------------------------------------------------------------------
// Phase 3 — On-demand resources (references/, scripts/)
// ---------------------------------------------------------------------------

/**
 * Resolve an absolute path to a file under `config/skills/<skillName>/`,
 * with traversal checks. Returns the path (for dynamic `import()`) without reading content.
 */
export function resolveSkillResourcePath(
  skillName: string,
  resourcePath: string,
): { ok: true; absolutePath: string } | { ok: false; error: string } {
  if (!skillName.trim() || resourcePath.includes("\0")) {
    return { ok: false, error: "invalid_input" };
  }
  const resolvedRoot = path.resolve(skillsRoot(), skillName);
  const normalized = resourcePath.replace(/^[/\\]+/, "");
  const resolvedFile = path.resolve(resolvedRoot, normalized);
  const rel = path.relative(resolvedRoot, resolvedFile);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    return { ok: false, error: "path_not_under_skill_directory" };
  }
  if (!fs.existsSync(resolvedFile) || !fs.statSync(resolvedFile).isFile()) {
    return { ok: false, error: "not_found" };
  }
  return { ok: true, absolutePath: resolvedFile };
}

/** Safe read of a file under `config/skills/<skillName>/`. */
export function readSkillResourceFile(
  skillName: string,
  resourcePath: string,
): { ok: true; content: string } | { ok: false; error: string } {
  if (!skillName.trim() || resourcePath.includes("\0")) {
    return { ok: false, error: "invalid_input" };
  }
  const resolvedRoot = path.resolve(skillsRoot(), skillName);
  const normalized = resourcePath.replace(/^[/\\]+/, "");
  const resolvedFile = path.resolve(resolvedRoot, normalized);
  const rel = path.relative(resolvedRoot, resolvedFile);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    return { ok: false, error: "path_not_under_skill_directory" };
  }
  if (!fs.existsSync(resolvedFile) || !fs.statSync(resolvedFile).isFile()) {
    return { ok: false, error: "not_found" };
  }
  const maxBytes = Number(process.env.SKILL_RESOURCE_MAX_BYTES ?? 500_000);
  const buf = fs.readFileSync(resolvedFile);
  if (buf.length > maxBytes) {
    return { ok: false, error: "file_too_large" };
  }
  return { ok: true, content: buf.toString("utf8") };
}

// ---------------------------------------------------------------------------
// SkillRegistry — shared mutable state for one chat turn
// ---------------------------------------------------------------------------

/**
 * Holds the state of skill loading for a single agent invocation.
 *
 * - Phase 1 (startup): discovery index built from `allowedSkills`.
 * - Phase 2 (on activate): full SKILL.md body loaded and stored.
 * - Phase 3 (on demand): `readSkillResourceFile` called by the tool.
 *
 * The registry is passed into the `activate_skill` tool callback so the tool
 * can mutate it at runtime, and the updated system prompt can be rebuilt.
 */
export class SkillRegistry {
  /** Names the agent is allowed to activate (from .agent.md `skills:`). */
  readonly allowedSkills: ReadonlySet<string>;

  /** Phase 1 discovery records for allowed skills. */
  readonly discoveries: SkillDiscovery[];

  /** Phase 2 activated bodies, keyed by skill name. */
  private readonly _activated = new Map<string, string>();

  constructor(allowedSkillNames: string[]) {
    this.allowedSkills = new Set(allowedSkillNames);
    this.discoveries = listSkillDiscovery().filter((d) =>
      this.allowedSkills.has(d.name),
    );
  }

  /** Activate a skill: load its full SKILL.md body (idempotent). */
  activate(skillName: string): { ok: true; body: string } | { ok: false; error: string } {
    if (!this.allowedSkills.has(skillName)) {
      return { ok: false, error: `skill '${skillName}' is not in this agent's skills list` };
    }
    if (this._activated.has(skillName)) {
      return { ok: true, body: this._activated.get(skillName)! };
    }
    const body = loadSkillInstructions(skillName);
    if (!body) {
      return { ok: false, error: `SKILL.md not found or empty for '${skillName}'` };
    }
    this._activated.set(skillName, body);
    return { ok: true, body };
  }

  /** All currently activated skill bodies (name + body). */
  get activatedBlocks(): { name: string; body: string }[] {
    return [...this._activated.entries()].map(([name, body]) => ({ name, body }));
  }

  /** True if any skills are activated. */
  get hasActivated(): boolean {
    return this._activated.size > 0;
  }

  /** Phase 2: full SKILL.md loaded for this skill (required before `read_skill_resource`). */
  isSkillActivated(skillName: string): boolean {
    return this._activated.has(skillName);
  }

  /** Pre-activate all allowed skills (used for specialist agents that always need their skill). */
  activateAll(): void {
    for (const name of this.allowedSkills) {
      this.activate(name);
    }
  }
}
