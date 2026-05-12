import type { SkillDiscovery } from "./skill-loader.ts";

// ---------------------------------------------------------------------------
// Phase 1 — Discovery section (compact, ~100 tokens per skill)
// ---------------------------------------------------------------------------

/**
 * Append a compact skill discovery index to a base prompt.
 * Used for the orchestrator and any agent that needs to know what skills exist
 * before deciding which to activate.
 */
export function withSkillDiscoverySection(
  basePrompt: string,
  discoveries: SkillDiscovery[],
): string {
  if (discoveries.length === 0) return basePrompt;
  const lines = discoveries
    .map((d) => `- **${d.name}**: ${d.description}`)
    .join("\n");
  return (
    `${basePrompt}\n\n` +
    `## Available skills (discovery index)\n\n` +
    `Use \`activate_skill\` to load full instructions before answering domain questions.\n\n` +
    `${lines}`
  );
}

// ---------------------------------------------------------------------------
// Phase 2 — Activated skill blocks (full SKILL.md body)
// ---------------------------------------------------------------------------

/**
 * Append activated skill instruction blocks to a base prompt.
 * Called after Phase 1 when the agent (or the framework) has activated skills.
 */
export function withActivatedSkills(
  basePrompt: string,
  activatedBlocks: { name: string; body: string }[],
): string {
  if (activatedBlocks.length === 0) return basePrompt;
  const blocks = activatedBlocks
    .map((s) => `### Skill: ${s.name}\n\n${s.body.trim()}`)
    .join("\n\n---\n\n");
  return `${basePrompt}\n\n## Activated skill instructions\n\n${blocks}`;
}

// ---------------------------------------------------------------------------
// Combined builder — used by run-chat-stream
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Phase 5 — Long-term memory context
// ---------------------------------------------------------------------------

/**
 * Prepend a long-term memory context block to the system prompt.
 * Placed before skills so the agent sees user context early.
 */
export function withLongTermMemory(basePrompt: string, memoryContext: string): string {
  if (!memoryContext.trim()) return basePrompt;
  return (
    `${basePrompt}\n\n` +
    `## Context from previous sessions and user profile\n\n` +
    `The following context can include prior conversation facts and authenticated user details. ` +
    `Use it to personalize your response and avoid asking for information already provided.\n\n` +
    `${memoryContext.trim()}`
  );
}

// ---------------------------------------------------------------------------
// Combined builder — used by run-chat-stream and create-strands-agent
// ---------------------------------------------------------------------------

/**
 * Build the full system prompt for an agent turn.
 *
 * @param persona       - Markdown body from the .agent.md file.
 * @param discoveries   - Phase 1: compact discovery records (always included).
 * @param activated     - Phase 2: full skill bodies already activated this turn.
 * @param memoryContext - Phase 5: long-term memory context string (optional).
 */
export function buildSystemPrompt(
  persona: string,
  discoveries: SkillDiscovery[],
  activated: { name: string; body: string }[],
  memoryContext?: string,
): string {
  const base = persona.trim() || "You are a helpful assistant.";
  let prompt = base;
  if (memoryContext?.trim()) {
    prompt = withLongTermMemory(prompt, memoryContext);
  }
  if (discoveries.length > 0) {
    prompt = withSkillDiscoverySection(prompt, discoveries);
  }
  if (activated.length > 0) {
    prompt = withActivatedSkills(prompt, activated);
  }
  return prompt;
}
