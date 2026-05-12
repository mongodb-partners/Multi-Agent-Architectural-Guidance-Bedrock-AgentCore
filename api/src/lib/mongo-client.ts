import { MongoClient, type Db } from "mongodb";

let client: MongoClient | undefined;
let dbPromise: Promise<Db> | undefined;

export async function getMongoDb(): Promise<Db | null> {
  const uri = process.env.MONGODB_URI?.trim();
  if (!uri) return null;

  if (!client) {
    client = new MongoClient(uri);
  }

  if (!dbPromise) {
    const name = process.env.MONGODB_DB?.trim() || "bedrock_agents";
    dbPromise = client.connect().then((c) => c.db(name));
  }

  try {
    return await dbPromise;
  } catch {
    dbPromise = undefined;
    throw new Error("MongoDB connection failed (check MONGODB_URI and network).");
  }
}

export function resetMongoClientForTests(): void {
  client = undefined;
  dbPromise = undefined;
}
