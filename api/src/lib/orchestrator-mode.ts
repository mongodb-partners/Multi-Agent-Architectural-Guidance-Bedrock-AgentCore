/**
 * Whether the orchestrator runtime should run Strands Swarm
 * (orchestrator + specialists in one container) for this turn.
 *
 * Swarm is the default orchestrator behavior; set ORCHESTRATOR_MODE to
 * anything other than "swarm" to fall back to single-agent routing
 * (the orchestrator runtime then performs InvokeAgentRuntime against the
 * specialist runtime ARN itself).
 */
export function useOrchestratorSwarm(
  agentId: string,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  if (agentId !== "orchestrator") return false;
  const mode = env.ORCHESTRATOR_MODE?.trim().toLowerCase();
  return mode === undefined || mode === "" || mode === "swarm";
}
