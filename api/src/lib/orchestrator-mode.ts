import { chatMode } from "./runtime-defaults.ts";

/**
 * Whether POST /chat should run Strands Swarm (orchestrator + specialists).
 * Requires live mode; stub streaming stays single-path.
 */
export function useOrchestratorSwarm(
  agentId: string,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  // In AgentCore Runtime mode, orchestrator routing happens in-runtime (not swarm).
  if (env.AGENTCORE_ORCHESTRATOR_ARN?.trim()) return false;

  return (
    agentId === "orchestrator" &&
    env.ORCHESTRATOR_MODE === "swarm" &&
    chatMode(env) === "live"
  );
}
