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
 * The framework-canonical long-term memory recall rules.
 *
 * Exported so:
 *   - `withLongTermMemory` can inject them once, uniformly, for every agent
 *     whose `.agent.md` frontmatter sets `memory.longTerm: true`.
 *   - Unit tests can lock the block down so personas don't quietly drift
 *     back to copying these rules into their bodies.
 *
 * Keep this block tight (every line is sent on every turn). When updating
 * it, also run `bun test api/tests/unit/orchestrator-ltm-flag.test.ts`
 * which pins the contents.
 */
export const LONG_TERM_MEMORY_RECALL_RULES = `## Memory recall rules (framework-injected)

You have long-term memory injected just above (\`## Context from previous sessions and user profile\` and/or \`## Relevant prior context\`). It mixes LLM-curated facts about the user with replayed snippets of past conversations. Treat it as a trustworthy first source for personalization and recall.

1. **Use the context proactively.** If the user references something they said before — preferences, codenames, lists, accounts, recent decisions — look in the memory block FIRST. Answer directly from what is there. Reproduce lists in full when the user asks for them.
2. **Never deny having memory when the block is non-empty.** Do not say "I don't have access to previous conversations" or "I can't remember earlier sessions" — when memory is injected, you can and you should. If the specific detail is not in the block, say so honestly and offer to capture it now.
3. **Don't ask for information you already have.** If \`authenticatedEmail\`, preferences, or order IDs are visible in memory, use them silently instead of re-prompting.
4. **Don't make up details that aren't in memory.** Memory is the floor for recall, not a license to fabricate. Use tools or skill scripts for live data the way you normally do.
`;

/**
 * Prepend a long-term memory context block to the system prompt.
 * Placed before skills so the agent sees user context early.
 *
 * The context block is followed by the framework-canonical recall rules so
 * every memory-enabled agent gets the same instructions without each
 * `.agent.md` having to copy them. Removing the rules from personas is the
 * companion change.
 */
export function withLongTermMemory(basePrompt: string, memoryContext: string): string {
  if (!memoryContext.trim()) return basePrompt;
  return (
    `${basePrompt}\n\n` +
    `## Context from previous sessions and user profile\n\n` +
    `The following context can include prior conversation facts and authenticated user details. ` +
    `Use it to personalize your response and avoid asking for information already provided.\n\n` +
    `${memoryContext.trim()}\n\n` +
    `${LONG_TERM_MEMORY_RECALL_RULES}`
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
