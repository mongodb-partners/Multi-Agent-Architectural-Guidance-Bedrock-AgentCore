/**
 * Gate G1-agentcore-memory (ACTION_PLAN): Bun can load `@aws-sdk/client-bedrock-agentcore`.
 *
 * - Always (no network): constructs `BedrockAgentCoreClient` — proves import + init on Bun.
 * - Optional live check: set `AGENTCORE_MEMORY_ID`, `AGENTCORE_ACTOR_ID`, `AWS_REGION` (or default
 *   us-east-1), and credentials; script calls `ListSessionsCommand` once and prints session count.
 */
import {
  BedrockAgentCoreClient,
  ListSessionsCommand,
} from "@aws-sdk/client-bedrock-agentcore";

const region = process.env.AWS_REGION ?? "us-east-1";
const client = new BedrockAgentCoreClient({ region });
console.log("validate-agentcore-memory: BedrockAgentCoreClient constructed OK (region=%s)", region);

const memoryId = process.env.AGENTCORE_MEMORY_ID?.trim();
const actorId = process.env.AGENTCORE_ACTOR_ID?.trim();

if (!memoryId || !actorId) {
  console.log(
    "validate-agentcore-memory: skip live ListSessions (set AGENTCORE_MEMORY_ID + AGENTCORE_ACTOR_ID to exercise API)",
  );
  process.exit(0);
}

try {
  const out = await client.send(
    new ListSessionsCommand({
      memoryId,
      actorId,
      maxResults: 5,
    }),
  );
  const n = out.sessionSummaries?.length ?? 0;
  console.log("validate-agentcore-memory: ListSessions OK (%d summaries in page)", n);
} catch (e) {
  console.error(
    "validate-agentcore-memory: ListSessions failed",
    e instanceof Error ? e.message : e,
  );
  process.exit(1);
}
