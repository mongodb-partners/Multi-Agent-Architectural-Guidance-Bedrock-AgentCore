/**
 * Seed all collections in dependency order:
 *   1. customers
 *   2. products
 *   3. troubleshooting_docs
 *   4. orders
 *   5. indexes (regular + Atlas vector search + TTL)
 *
 * Embeddings are NOT run here — they require live AWS credentials and are slow.
 * Run seed-embeddings.ts separately after this script.
 *
 * Usage:
 *   MONGODB_URI=mongodb+srv://user:pass@cluster.mongodb.net \
 *   MONGODB_DB=bedrock_agents \
 *   bun db-seeding/seed-all.ts
 *
 * Optional env:
 *   MEMORY_TTL_DAYS=90          — TTL for agent_memory_facts + chat_messages (default 90)
 *   EMBEDDING_DIMENSIONS=1024   — vector index dimensions (default 1024)
 *   VECTOR_SIMILARITY=cosine    — cosine | euclidean | dotProduct (default cosine)
 */

import { getConfig } from "./connect.ts";

// Validate env before spawning child scripts
getConfig();

const scripts = [
  "seed-customers.ts",
  "seed-products.ts",
  "seed-troubleshooting.ts",
  "seed-orders.ts",
  "seed-indexes.ts",
];

const dir = import.meta.dir;

console.log("━━━ Bedrock Multi-Agent — MongoDB seed ━━━\n");

for (const script of scripts) {
  console.log(`▶  ${script}`);
  const proc = Bun.spawn(["bun", `${dir}/${script}`], {
    stdout: "inherit",
    stderr: "inherit",
    env: process.env,
  });
  const exit = await proc.exited;
  if (exit !== 0) {
    console.error(`\n❌  ${script} exited with code ${exit}. Aborting.`);
    process.exit(exit);
  }
  console.log();
}

console.log("━━━ All seeds complete ━━━");
console.log("\nNext steps:");
console.log("  1. Run seed-embeddings.ts once AWS credentials are available:");
console.log("       AWS_REGION=us-east-1 MONGODB_URI=... bun db-seeding/seed-embeddings.ts");
console.log("  2. Verify Atlas vector search indexes are ACTIVE in the Atlas UI (can take a few minutes).");
console.log("  3. Source .env + .env.live (so AGENTCORE_ORCHESTRATOR_ARN is set) and smoke-test the API with:");
console.log("       curl -s http://localhost:3000/health | jq .dependencies");
