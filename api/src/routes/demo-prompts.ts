/**
 * `GET /demo-prompts` — serves `config/demo-prompts.yaml` to the UI so the
 * sidebar's "Try a prompt" buttons can come from a single source of truth
 * without having to bind-mount `config/` into the Streamlit container.
 *
 * Response shape:
 *   { groups: Array<{ title: string; prompts: Array<{ label: string; text: string }> }> }
 *
 * Missing or malformed file → `{ groups: [] }` (the UI hides the section).
 */

import fs from "node:fs";
import path from "node:path";
import { Hono } from "hono";
import { parse as parseYaml } from "yaml";
import { resolveConfigRoot } from "../lib/paths.ts";
import { logger } from "../lib/logger.ts";

export const demoPromptsRoutes = new Hono();

type Prompt = { label: string; text: string };
type Group = { title: string; prompts: Prompt[] };

let cached: { mtimeMs: number; payload: { groups: Group[] } } | undefined;

function loadDemoPrompts(): { groups: Group[] } {
  const file = path.join(resolveConfigRoot(), "demo-prompts.yaml");
  let stat: fs.Stats;
  try {
    stat = fs.statSync(file);
  } catch {
    return { groups: [] };
  }
  if (cached && cached.mtimeMs === stat.mtimeMs) {
    return cached.payload;
  }
  let raw: unknown;
  try {
    raw = parseYaml(fs.readFileSync(file, "utf8"));
  } catch (err) {
    logger.warn("demo-prompts.parse_failed", {
      file,
      error: err instanceof Error ? err.message : String(err),
    });
    return { groups: [] };
  }
  const rawGroups = (raw as { groups?: unknown })?.groups;
  if (!Array.isArray(rawGroups)) return { groups: [] };

  const groups: Group[] = [];
  for (const g of rawGroups) {
    if (!g || typeof g !== "object") continue;
    const title = String((g as { title?: unknown }).title ?? "").trim();
    const rawPrompts = (g as { prompts?: unknown }).prompts;
    if (!title || !Array.isArray(rawPrompts)) continue;
    const prompts: Prompt[] = [];
    for (const p of rawPrompts) {
      if (!p || typeof p !== "object") continue;
      const text = String((p as { text?: unknown }).text ?? "").trim();
      if (!text) continue;
      const label = String((p as { label?: unknown }).label ?? text).trim();
      prompts.push({ label, text });
    }
    if (prompts.length > 0) groups.push({ title, prompts });
  }
  const payload = { groups };
  cached = { mtimeMs: stat.mtimeMs, payload };
  return payload;
}

demoPromptsRoutes.get("/demo-prompts", (c) => c.json(loadDemoPrompts()));
