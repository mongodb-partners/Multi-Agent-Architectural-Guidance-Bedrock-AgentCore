/**
 * Seed: customers collection
 *
 * Upserts demo customer profiles. Safe to re-run (idempotent on `email`).
 * Run:  MONGODB_URI=... bun db-seeding/seed-customers.ts
 */

import { connect } from "./connect.ts";

const CUSTOMERS = [
  {
    email: "alex@example.com",
    name: "Alex Rivera",
    verified: true,
    tier: "standard",
    joinedAt: "2023-04-10",
    preferences: { contactMethod: "email", language: "en" },
  },
  {
    email: "blake@example.com",
    name: "Blake Chen",
    verified: true,
    tier: "standard",
    joinedAt: "2023-07-22",
    preferences: { contactMethod: "sms", language: "en" },
  },
  {
    email: "casey@example.com",
    name: "Casey Morgan",
    verified: true,
    tier: "premium",
    joinedAt: "2022-11-05",
    preferences: { contactMethod: "email", language: "en" },
  },
  {
    email: "dana@example.com",
    name: "Dana Patel",
    verified: true,
    tier: "premium",
    joinedAt: "2022-08-30",
    preferences: { contactMethod: "email", language: "en" },
  },
  {
    email: "eli@example.com",
    name: "Eli Santos",
    verified: false,
    tier: "standard",
    joinedAt: "2024-01-18",
    preferences: { contactMethod: "email", language: "en" },
  },
];

const { client, db } = await connect();
const col = db.collection("customers");
let upserted = 0;

for (const c of CUSTOMERS) {
  const res = await col.updateOne(
    { email: c.email },
    { $set: c },
    { upsert: true },
  );
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  customers: ${upserted} upserted / ${CUSTOMERS.length} total`);
await client.close();
