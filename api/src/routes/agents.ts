import { Hono } from "hono";
import { getAgent, listAgents } from "../lib/config-scan.ts";

export const agentsRoutes = new Hono();

agentsRoutes.get("/agents", (c) => {
  return c.json({ agents: listAgents() });
});

agentsRoutes.get("/agents/:agentId", (c) => {
  const agentId = c.req.param("agentId");
  const agent = getAgent(agentId);
  if (!agent) {
    return c.json(
      {
        error: {
          code: "AGENT_NOT_FOUND",
          message: `No agent with id '${agentId}' exists.`,
          requestId: c.get("requestId") ?? "unknown",
        },
      },
      404,
    );
  }
  return c.json(agent);
});
