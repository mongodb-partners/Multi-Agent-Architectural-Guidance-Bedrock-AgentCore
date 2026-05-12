import { z } from "zod";

export const agentHandoffSchema = z.object({
  label: z.string(),
  agent: z.string(),
  prompt: z.string().optional(),
});

/** Frontmatter for config agents: `.agent.md` files (subset enforced at runtime). */
export const agentFrontmatterSchema = z.object({
  name: z.string().min(1),
  description: z.string(),
  id: z.string().min(1),
  skills: z.array(z.string()).default([]),
  tools: z.array(z.string()).default([]),
  model: z.string().optional(),
  maxTokens: z.coerce.number().int().positive().default(4096),
  temperature: z.coerce.number().min(0).max(2).default(0.7),
  memory: z
    .object({
      shortTerm: z.boolean().optional(),
      longTerm: z.boolean().optional(),
      longTermCollection: z.string().optional(),
    })
    .optional(),
  handoffs: z.array(agentHandoffSchema).default([]),
});

export type AgentFrontmatter = z.infer<typeof agentFrontmatterSchema>;

/** Frontmatter for each skill's SKILL.md under config/skills. */
export const skillFrontmatterSchema = z.object({
  name: z.string().min(1),
  description: z.string(),
  metadata: z.record(z.string(), z.unknown()).optional(),
});

export type SkillFrontmatter = z.infer<typeof skillFrontmatterSchema>;
