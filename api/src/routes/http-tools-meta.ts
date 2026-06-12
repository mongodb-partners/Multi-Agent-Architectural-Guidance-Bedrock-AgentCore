import { Hono } from "hono";
import { z } from "zod";
import { expandEnvTemplate, loadHttpToolsFile } from "../lib/http-tools-load.ts";
import { listAllSkillHttpToolDescriptors } from "../lib/skill-http-tools-load.ts";
import { HttpToolNotFoundError, invokeHttpToolByName } from "../lib/http-tools-runtime.ts";

export const httpToolsMetaRoutes = new Hono();

/**
 * List config-defined HTTP tools (REST endpoints). No secrets returned.
 * Includes root `http-tools.json` and per-skill `config/skills/<skill>/http-tools.json`.
 */
httpToolsMetaRoutes.get("/http-tools", (c) => {
  const file = loadHttpToolsFile(true);
  const globalTools = file.tools.map((t) => {
    const expanded = expandEnvTemplate(t.url).trim();
    return {
      scope: "global" as const,
      name: t.name,
      description: t.description,
      method: t.method,
      urlConfigured: Boolean(expanded),
      headerKeys: t.headers ? Object.keys(t.headers) : [],
      passThroughBody: Boolean(t.passThroughBody),
      timeoutMs: t.timeoutMs,
      parameterNames: t.parameters?.map((p) => p.name) ?? [],
      parameters: (t.parameters ?? []).map((p) => ({
        name: p.name,
        type: p.type,
        description: p.description,
        required: p.required,
      })),
    };
  });

  const skillGroups = listAllSkillHttpToolDescriptors();
  const skillTools = skillGroups.flatMap((g) =>
    g.tools.map((t) => ({
      scope: "skill" as const,
      skillName: g.skillName,
      name: `${g.skillName}/${t.localName}`,
      localName: t.localName,
      description: t.description,
      method: t.method,
      urlConfigured: t.urlConfigured,
      headerKeys: t.headerKeys,
      passThroughBody: t.passThroughBody,
      parameterNames: t.parameterNames,
    })),
  );

  return c.json({
    globalTools,
    skillTools,
    tools: [...globalTools, ...skillTools],
    security: file.security
      ? {
          allowedHostSuffixes: file.security.allowedHostSuffixes ?? [],
          allowedHosts: file.security.allowedHosts ?? [],
        }
      : null,
  });
});

/**
 * Directly invoke a configured global HTTP tool — no LLM/agent in the loop.
 * Powers the UI Debug page ("HTTP Tool Test"). Request body: `{ "input": { ... } }`
 * (or the raw param object). The SSRF allowlist + mock-mode gates still apply.
 * Returns the resolved URL so the caller can confirm which endpoint was hit.
 */
httpToolsMetaRoutes.post("/http-tools/:name/invoke", async (c) => {
  const name = c.req.param("name");

  let body: unknown = {};
  try {
    body = await c.req.json();
  } catch {
    body = {};
  }
  const input =
    body && typeof body === "object" && body !== null && "input" in (body as Record<string, unknown>)
      ? (body as Record<string, unknown>).input
      : body;

  try {
    const out = await invokeHttpToolByName(name, (input ?? {}) as Record<string, unknown>);
    return c.json(out);
  } catch (e) {
    if (e instanceof HttpToolNotFoundError) {
      return c.json({ error: "tool_not_found", name }, 404);
    }
    if (e instanceof z.ZodError) {
      return c.json({ error: "invalid_input", issues: e.issues }, 400);
    }
    const message = e instanceof Error ? e.message : String(e);
    return c.json({ error: "invoke_failed", message }, 500);
  }
});
