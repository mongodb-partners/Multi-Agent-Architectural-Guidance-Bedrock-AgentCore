/**
 * Gate G0-runtime (ACTION_PLAN): Bun can load Strands + AWS Bedrock client deps.
 * Does not call Bedrock (no network required).
 */
import { Agent } from "@strands-agents/sdk";

const agent = new Agent({
  model: "us.anthropic.claude-sonnet-4-6",
  systemPrompt: "Reply with exactly: ok",
  printer: false,
});

await agent.initialize();
console.log("validate-bun-compat: Strands Agent initialized on Bun OK");
