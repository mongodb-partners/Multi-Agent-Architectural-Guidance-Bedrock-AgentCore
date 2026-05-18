import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Hono } from "hono";
import { z } from "zod";
import { setAgentcoreSpecialistArnOverrides } from "../adapters/agentcore-runtime.ts";
import { clearAgentClassifierCache } from "../lib/agent-classifier.ts";
import { clearAgentTemplateCache, warmAgentCache } from "../lib/create-strands-agent.ts";
import { clearConfigCache, listAgents } from "../lib/config-scan.ts";
import { refreshHttpToolsMap } from "../lib/http-tools-runtime.ts";
import { logger } from "../lib/logger.ts";
import { setConfigRootOverride } from "../lib/paths.ts";
import { clearSkillCaches } from "../lib/skill-loader.ts";

const refreshSchema = z.object({
  files: z.record(z.string(), z.string()),
  specialistArns: z.record(z.string(), z.string()),
});

const MAX_FILE_COUNT = 500;
const MAX_TOTAL_BYTES = 8_000_000;

export const agentConfigRefreshRoutes = new Hono();

function assertRefreshToken(actual: string | undefined): { ok: true } | { ok: false; status: 403 | 503; code: string } {
  const expected = process.env.AGENT_CONFIG_REFRESH_TOKEN?.trim();
  if (!expected) {
    return { ok: false, status: 503, code: "REFRESH_DISABLED" };
  }
  if (!actual || actual !== expected) {
    return { ok: false, status: 403, code: "FORBIDDEN" };
  }
  return { ok: true };
}

function validateRelativeConfigPath(relPath: string): string {
  if (!relPath || relPath.includes("\0") || path.isAbsolute(relPath)) {
    throw new Error(`invalid config path: ${relPath}`);
  }
  const normalized = relPath.replace(/\\/g, "/").replace(/^\/+/, "");
  const parsed = path.posix.normalize(normalized);
  if (parsed === "." || parsed.startsWith("../") || parsed.includes("/../")) {
    throw new Error(`path traversal blocked: ${relPath}`);
  }
  const allowed =
    parsed.startsWith("agents/") ||
    parsed.startsWith("skills/") ||
    parsed === "http-tools.json" ||
    parsed === "environment.yaml" ||
    parsed === "demo-prompts.yaml";
  if (!allowed) {
    throw new Error(`unsupported config path: ${relPath}`);
  }
  return parsed;
}

function writeRuntimeConfigSnapshot(files: Record<string, string>): { root: string; fileCount: number; totalBytes: number } {
  const entries = Object.entries(files);
  if (entries.length > MAX_FILE_COUNT) {
    throw new Error(`too many config files: ${entries.length}`);
  }

  const stamp = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
  const root = path.join(os.tmpdir(), "multiagent-config-snapshots", stamp);
  fs.mkdirSync(root, { recursive: true });

  let totalBytes = 0;
  for (const [rawRelPath, content] of entries) {
    const relPath = validateRelativeConfigPath(rawRelPath);
    const bytes = Buffer.byteLength(content, "utf8");
    totalBytes += bytes;
    if (totalBytes > MAX_TOTAL_BYTES) {
      throw new Error(`config snapshot too large: ${totalBytes} bytes`);
    }
    const dest = path.join(root, relPath);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, content, "utf8");
  }

  return { root, fileCount: entries.length, totalBytes };
}

agentConfigRefreshRoutes.post("/internal/agents/refresh", async (c) => {
  const tokenCheck = assertRefreshToken(c.req.header("X-Agent-Config-Refresh-Token"));
  if (!tokenCheck.ok) {
    return c.json(
      {
        error: {
          code: tokenCheck.code,
          message: tokenCheck.code === "REFRESH_DISABLED"
            ? "Agent config refresh is not enabled on this API process."
            : "Agent config refresh token is invalid.",
          requestId: c.get("requestId"),
        },
      },
      tokenCheck.status,
    );
  }

  let parsed: z.infer<typeof refreshSchema>;
  try {
    parsed = refreshSchema.parse(await c.req.json());
  } catch (err) {
    return c.json(
      {
        error: {
          code: "INVALID_REQUEST",
          message: err instanceof Error ? err.message : "Invalid refresh payload.",
          requestId: c.get("requestId"),
        },
      },
      400,
    );
  }

  try {
    const snapshot = writeRuntimeConfigSnapshot(parsed.files);
    setAgentcoreSpecialistArnOverrides(parsed.specialistArns);
    setConfigRootOverride(snapshot.root);
    clearConfigCache();
    clearSkillCaches();
    clearAgentClassifierCache();
    clearAgentTemplateCache();
    refreshHttpToolsMap();
    await warmAgentCache();

    const agents = listAgents();
    logger.info("[agents] runtime config refreshed", {
      requestId: c.get("requestId"),
      userId: c.get("jwtPayload")?.sub,
      configRoot: snapshot.root,
      fileCount: snapshot.fileCount,
      totalBytes: snapshot.totalBytes,
      agentCount: agents.length,
      specialistCount: Object.keys(parsed.specialistArns).length,
    });

    return c.json({
      ok: true,
      configRoot: snapshot.root,
      fileCount: snapshot.fileCount,
      agents,
      specialistIds: Object.keys(parsed.specialistArns).sort(),
    });
  } catch (err) {
    logger.error("[agents] runtime config refresh failed", {
      requestId: c.get("requestId"),
      error: err instanceof Error ? err.message : String(err),
    });
    return c.json(
      {
        error: {
          code: "REFRESH_FAILED",
          message: err instanceof Error ? err.message : "Agent config refresh failed.",
          requestId: c.get("requestId"),
        },
      },
      500,
    );
  }
});
