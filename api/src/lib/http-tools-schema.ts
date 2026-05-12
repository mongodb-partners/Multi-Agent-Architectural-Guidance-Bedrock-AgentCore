import { z } from "zod";

export const httpToolParameterSchema = z.object({
  name: z.string().min(1),
  type: z.enum(["string", "number", "boolean", "object"]),
  description: z.string(),
  required: z.boolean().default(true),
});

export type HttpToolParameter = z.infer<typeof httpToolParameterSchema>;

export const httpToolDefinitionSchema = z
  .object({
    name: z
      .string()
      .min(1)
      .regex(/^[a-z][a-z0-9_]*$/i, "Use letters, numbers, underscores; start with a letter"),
    description: z.string().min(1),
    method: z.enum(["GET", "POST", "PUT", "PATCH", "DELETE"]).default("POST"),
    /** URL with optional `${ENV_VAR}` placeholders (expanded from process.env). */
    url: z.string().min(1),
    headers: z.record(z.string(), z.string()).optional(),
    timeoutMs: z.number().int().positive().max(120_000).optional().default(30_000),
    /** Named parameters → Zod object schema for the model. */
    parameters: z.array(httpToolParameterSchema).optional(),
    /** If true, tool input is a single JSON object forwarded as the request body (POST/PUT/PATCH). */
    passThroughBody: z.boolean().optional(),
  })
  .superRefine((d, ctx) => {
    const n = d.parameters?.length ?? 0;
    if (n > 0 && d.passThroughBody) {
      ctx.addIssue({
        code: "custom",
        message: "Use either parameters[] or passThroughBody, not both",
        path: ["passThroughBody"],
      });
    }
    if (n === 0 && !d.passThroughBody) {
      ctx.addIssue({
        code: "custom",
        message: "Define parameters[] or set passThroughBody: true",
        path: ["parameters"],
      });
    }
  });

export type HttpToolDefinition = z.infer<typeof httpToolDefinitionSchema>;

export const httpToolsFileSchema = z.object({
  security: z
    .object({
      /** If set, request URL hostname must equal or end with one of these (SSRF mitigation). */
      allowedHostSuffixes: z.array(z.string().min(1)).optional(),
      allowedHosts: z.array(z.string().min(1)).optional(),
    })
    .optional(),
  tools: z.array(httpToolDefinitionSchema).default([]),
});

export type HttpToolsFile = z.infer<typeof httpToolsFileSchema>;

/** Per-skill file: `config/skills/<skill>/http-tools.json` (no top-level security; use root `http-tools.json` for SSRF allowlist). */
export const skillHttpToolsFileSchema = z.object({
  tools: z.array(httpToolDefinitionSchema).default([]),
});

export type SkillHttpToolsFile = z.infer<typeof skillHttpToolsFileSchema>;
