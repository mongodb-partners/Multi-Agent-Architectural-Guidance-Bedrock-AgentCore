import { BedrockModel, type Model } from "@strands-agents/sdk";
import type { AgentDetail } from "../lib/config-scan.ts";

/** Resolve the Bedrock model for an agent. Throws if the agent's .agent.md has no model: field. */
export function resolveModel(agentConfig: AgentDetail): Model {
  const modelId = agentConfig.model?.trim();
  if (!modelId) {
    throw new Error(
      `Agent '${agentConfig.id}' has no model configured. Add a 'model:' field to ${agentConfig.id}.agent.md.`,
    );
  }

  const region = process.env.AWS_REGION?.trim();
  return new BedrockModel({
    modelId,
    maxTokens: agentConfig.maxTokens,
    temperature: agentConfig.temperature,
    ...(region ? { region } : {}),
  });
}
