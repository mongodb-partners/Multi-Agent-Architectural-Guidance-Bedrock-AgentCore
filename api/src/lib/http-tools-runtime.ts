import { tool, type JSONValue, type Tool } from "@strands-agents/sdk";
import { z } from "zod";
import { expandEnvTemplate, loadHttpToolsFile } from "./http-tools-load.ts";
import type { HttpToolDefinition, HttpToolParameter, HttpToolsFile } from "./http-tools-schema.ts";
import type { SkillRegistry } from "./skill-loader.ts";
import { resetSkillHttpToolsCacheForTests } from "./skill-http-tools-load.ts";
import { currentTrace } from "./trace-context.ts";

/** When `HTTP_TOOLS_MOCK=1`, HTTP tools return a mock payload without calling the network. */
export function isHttpToolsMockMode(): boolean {
  const v = process.env.HTTP_TOOLS_MOCK?.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

function paramToZod(p: HttpToolParameter): z.ZodTypeAny {
  const desc = p.description;
  let base: z.ZodTypeAny;
  switch (p.type) {
    case "string":
      base = z.string();
      break;
    case "number":
      base = z.number();
      break;
    case "boolean":
      base = z.boolean();
      break;
    case "object":
      base = z.record(z.string(), z.unknown());
      break;
    default:
      base = z.unknown();
  }
  base = base.describe(desc);
  return p.required ? base : base.optional();
}

function buildInputSchema(def: HttpToolDefinition): z.ZodObject<Record<string, z.ZodTypeAny>> {
  if (def.passThroughBody) {
    return z.object({
      body: z
        .record(z.string(), z.unknown())
        .describe("JSON object sent as the HTTP request body to the Lambda URL"),
    });
  }
  const shape: Record<string, z.ZodTypeAny> = {};
  for (const p of def.parameters ?? []) {
    shape[p.name] = paramToZod(p);
  }
  return z.object(shape);
}

function assertUrlAllowed(urlStr: string, file: HttpToolsFile): void {
  const sec = file.security;
  if (!sec?.allowedHostSuffixes?.length && !sec?.allowedHosts?.length) return;
  let host: string;
  try {
    host = new URL(urlStr).hostname;
  } catch {
    throw new Error("invalid_url");
  }
  const exact = sec.allowedHosts ?? [];
  if (exact.some((h) => h === host)) return;
  const suf = sec.allowedHostSuffixes ?? [];
  if (suf.some((s) => host === s || host.endsWith(s))) return;
  throw new Error(`host_not_allowed:${host}`);
}

function redactHeaders(h: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of h.entries()) {
    const lower = k.toLowerCase();
    if (lower === "authorization" || lower === "x-api-key" || lower.includes("token")) {
      out[k] = "<redacted>";
    } else {
      out[k] = v;
    }
  }
  return out;
}

async function runHttpCall(
  def: HttpToolDefinition,
  file: HttpToolsFile,
  flatInput: Record<string, unknown>,
  toolLabel: string,
): Promise<JSONValue> {
  const trace = currentTrace();

  if (isHttpToolsMockMode()) {
    trace?.event("tool.http", {
      url: def.url,
      method: def.method,
      body: flatInput,
      responseSnippet: "[mock]",
    });
    return {
      status: "ok",
      source: "http_tool_mock",
      tool: toolLabel,
      method: def.method,
      received: flatInput as JSONValue,
      hint: "Set HTTP_TOOLS_MOCK=0 and real Lambda URL env vars to call the endpoint.",
    };
  }

  const expandedUrl = expandEnvTemplate(def.url).trim();
  if (!expandedUrl) {
    trace?.event("tool.http", {
      url: def.url,
      method: def.method,
      blocked: "url_not_configured",
    });
    return {
      status: "error",
      code: "url_not_configured",
      tool: toolLabel,
      hint: "Expand env placeholders in the http-tools.json url (e.g. ${MY_LAMBDA_URL}).",
    };
  }

  try {
    assertUrlAllowed(expandedUrl, file);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    trace?.event("tool.http", {
      url: expandedUrl,
      method: def.method,
      blocked: "host_not_allowed",
      errorMessage: msg,
    });
    return {
      status: "error",
      code: "ssrf_blocked",
      tool: toolLabel,
      message: msg,
      hint: "Add hostname to security.allowedHosts or security.allowedHostSuffixes in config/http-tools.json (repo root).",
    };
  }

  const headers = new Headers();
  for (const [k, v] of Object.entries(def.headers ?? {})) {
    const expanded = expandEnvTemplate(v);
    if (expanded) headers.set(k, expanded);
  }

  const timeoutMs = def.timeoutMs ?? 30_000;
  const signal = AbortSignal.timeout(timeoutMs);

  const method = def.method;
  let requestUrl = expandedUrl;
  let body: string | undefined;

  if (method === "GET" || method === "DELETE") {
    const u = new URL(expandedUrl);
    for (const [k, v] of Object.entries(flatInput)) {
      if (v === undefined || v === null) continue;
      if (typeof v === "object") {
        u.searchParams.set(k, JSON.stringify(v));
      } else {
        u.searchParams.set(k, String(v));
      }
    }
    requestUrl = u.toString();
  } else {
    if (!headers.has("Content-Type")) {
      headers.set("Content-Type", "application/json");
    }
    body = JSON.stringify(flatInput);
  }

  let res: Response;
  try {
    res = await fetch(requestUrl, { method, headers, body, signal });
  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    const errClass = e instanceof Error ? e.constructor.name : "Error";
    trace?.event("tool.http", {
      url: requestUrl,
      method,
      headers: redactHeaders(headers),
      body: flatInput,
      errorClass: errClass,
      errorMessage: errMsg,
    });
    return {
      status: "error",
      code: "fetch_failed",
      tool: toolLabel,
      message: errMsg,
    };
  }

  const text = await res.text();
  let parsedBody: unknown = text;
  try {
    parsedBody = text ? JSON.parse(text) : null;
  } catch {
    /* keep raw text */
  }

  trace?.event("tool.http", {
    url: requestUrl,
    method,
    headers: redactHeaders(headers),
    body: flatInput,
    status: res.status,
    responseBytes: text.length,
    responseSnippet: text.slice(0, 200),
  });

  return {
    status: res.ok ? "ok" : "error",
    httpStatus: res.status,
    tool: toolLabel,
    body: parsedBody as JSONValue,
  };
}

function normalizeInput(def: HttpToolDefinition, input: Record<string, unknown>): Record<string, unknown> {
  if (def.passThroughBody) {
    const b = input.body;
    if (b && typeof b === "object" && !Array.isArray(b)) return b as Record<string, unknown>;
    return {};
  }
  return input;
}

export function makeHttpConfigTool(def: HttpToolDefinition, file: HttpToolsFile): Tool {
  const inputSchema = buildInputSchema(def);
  return tool({
    name: def.name,
    description: def.description,
    inputSchema,
    callback: async (input): Promise<JSONValue> => {
      const flat = normalizeInput(def, input as Record<string, unknown>);
      return runHttpCall(def, file, flat, def.name);
    },
  });
}

/**
 * HTTP tool defined under `config/skills/<skill>/http-tools.json`.
 * Same gates as `read_skill_resource` / `run_skill_script`: skill on agent + activated.
 * Strands tool name is `skillFolder/localName` (e.g. `order-management/notify_customer`).
 */
export function makeSkillHttpConfigTool(
  strandsToolName: string,
  skillName: string,
  def: HttpToolDefinition,
  registry: SkillRegistry,
): Tool {
  const inputSchema = buildInputSchema(def);
  const securityFile = loadHttpToolsFile();
  return tool({
    name: strandsToolName,
    description: `[Skill: ${skillName}] ${def.description}`,
    inputSchema,
    callback: async (input): Promise<JSONValue> => {
      if (!registry.allowedSkills.has(skillName)) {
        return {
          ok: false,
          error: "skill_not_allowed_for_agent",
          skillName,
          tool: strandsToolName,
          hint: "This agent's .agent.md skills list does not include that skill.",
        } as JSONValue;
      }
      if (!registry.isSkillActivated(skillName)) {
        return {
          ok: false,
          error: "skill_not_activated",
          skillName,
          tool: strandsToolName,
          hint: "Call activate_skill first (or use a specialist agent that pre-loads skills).",
        } as JSONValue;
      }
      const flat = normalizeInput(def, input as Record<string, unknown>);
      return runHttpCall(def, securityFile, flat, strandsToolName);
    },
  });
}

/** Map tool name → Strands Tool for all entries in http-tools.json. */
export function buildHttpToolsMap(): Map<string, Tool> {
  const file = loadHttpToolsFile();
  const map = new Map<string, Tool>();
  for (const def of file.tools) {
    map.set(def.name, makeHttpConfigTool(def, file));
  }
  return map;
}

let toolMapCache: Map<string, Tool> | null = null;

export function getHttpToolsMap(): Map<string, Tool> {
  if (!toolMapCache) {
    toolMapCache = buildHttpToolsMap();
  }
  return toolMapCache;
}

/** Reload http-tools.json from disk (e.g. after deploy). */
export function refreshHttpToolsMap(): void {
  loadHttpToolsFile(true);
  resetSkillHttpToolsCacheForTests();
  toolMapCache = buildHttpToolsMap();
}

/** Tests: drop cached tool map. */
export function resetHttpToolsMapCacheForTests(): void {
  toolMapCache = null;
}
