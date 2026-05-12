/**
 * Shared MongoDB connection helper for seed scripts.
 *
 * Reads MONGODB_URI and MONGODB_DB from the environment.
 * Call `connect()` at the start of each script and `client.close()` at the end.
 */

import { MongoClient } from "mongodb";

export function getConfig() {
  const uri = process.env.MONGODB_URI?.trim();
  if (!uri) {
    console.error("❌  MONGODB_URI is not set. Export it before running seed scripts.");
    process.exit(1);
  }
  const db = (process.env.MONGODB_DB ?? "bedrock_agents").trim();
  return { uri, db };
}

export async function connect() {
  const { uri, db } = getConfig();
  const client = new MongoClient(uri, { appName: "bedrock-agents-seed" });
  await client.connect();
  console.log(`✅  Connected to MongoDB (db: ${db})`);
  return { client, db: client.db(db) };
}
