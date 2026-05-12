// Idempotent collection bootstrap for the Bedrock KB vector store.
// Required because mongodbatlas_search_index needs the collection to exist.
//
// Env: MONGODB_URI, MONGODB_DB, MONGODB_COLL

import { MongoClient } from "mongodb";

const uri  = process.env.MONGODB_URI;
const db   = process.env.MONGODB_DB;
const coll = process.env.MONGODB_COLL;

if (!uri || !db || !coll) {
  console.error("MONGODB_URI, MONGODB_DB, MONGODB_COLL all required");
  process.exit(1);
}

// Atlas propagates new DB users with eventual consistency — retry for up to 90s.
const MAX_ATTEMPTS = 18;
const RETRY_DELAY_MS = 5000;

for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
  const client = new MongoClient(uri, { serverSelectionTimeoutMS: 10000, connectTimeoutMS: 10000 });
  try {
    await client.connect();
    const database = client.db(db);
    const found = await database.listCollections({ name: coll }).toArray();
    if (found.length === 0) {
      await database.createCollection(coll);
      console.log(`created ${db}.${coll}`);
    } else {
      console.log(`${db}.${coll} already exists`);
    }
    await client.close();
    process.exit(0);
  } catch (err: any) {
    await client.close().catch(() => {});
    const isAuthErr = err?.code === 18 || err?.message?.includes("Authentication failed");
    const isConnErr = err?.name === "MongoServerSelectionError" || err?.message?.includes("ECONNREFUSED");
    if ((isAuthErr || isConnErr) && attempt < MAX_ATTEMPTS) {
      console.log(`attempt ${attempt}/${MAX_ATTEMPTS}: ${err.message} — retrying in ${RETRY_DELAY_MS / 1000}s`);
      await new Promise(r => setTimeout(r, RETRY_DELAY_MS));
    } else {
      console.error(`attempt ${attempt}/${MAX_ATTEMPTS} failed: ${err.message}`);
      process.exit(1);
    }
  }
}
