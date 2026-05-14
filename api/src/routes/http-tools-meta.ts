import { Hono } from "hono";
import { expandEnvTemplate, loadHttpToolsFile } from "../lib/http-tools-load.ts";
import { listAllSkillHttpToolDescriptors } from "../lib/skill-http-tools-load.ts";

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
      parameterNames: t.parameters?.map((p) => p.name) ?? [],
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
