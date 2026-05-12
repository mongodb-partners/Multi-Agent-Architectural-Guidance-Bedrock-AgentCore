import { Hono } from "hono";
import { listSkills } from "../lib/config-scan.ts";

export const skillsRoutes = new Hono();

skillsRoutes.get("/skills", (c) => {
  return c.json({ skills: listSkills() });
});
