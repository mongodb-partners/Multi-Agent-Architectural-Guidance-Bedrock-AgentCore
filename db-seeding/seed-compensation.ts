/**
 * Seed: compensation_data collection  (career-coach agent — compensation workflow)
 *
 * Upserts compensation benchmarks keyed by `benchmarkId`.
 * Safe to re-run (idempotent on `benchmarkId`).
 *
 * The `embedding` field is NOT written here — it is backfilled by
 * seed-embeddings.ts from the `embeddingText` field on each document.
 *
 * All figures are ILLUSTRATIVE demo data (USD, annual). They are not real
 * market data and must not be presented as authoritative outside this demo.
 *
 * Schema: config/skills/career-coach/references/collections-schema.md
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-compensation.ts
 */

import { connect } from "./connect.ts";

type Band = { p25: number; p50: number; p75: number; p90: number };

type Benchmark = {
  benchmarkId: string;
  role: string;
  seniority: "junior" | "mid" | "senior" | "staff";
  region: "us-west" | "us-south" | "us-east" | "us-central" | "remote-us" | "emea" | "apac";
  locationLabel: string;
  currency: string;
  asOf: string;
  baseSalary: Band;
  totalComp: Band;
  benefits: string[];
  equityNote: string;
  sampleSize: number;
  embeddingText: string;
  updatedAt: Date;
};

const STD_BENEFITS = [
  "401k match up to 6%",
  "Health / dental / vision",
  "20 days PTO",
  "Remote work stipend",
];

const B = (role: string, seniority: string, region: string, location: string) =>
  `${role} ${seniority} compensation salary ${location} ${region} base total comp benefits equity`;

const BENCHMARKS: Benchmark[] = [
  // ── Machine Learning Engineer ────────────────────────────────────────────
  {
    benchmarkId: "comp-ml-engineer-mid-us-south",
    role: "Machine Learning Engineer",
    seniority: "mid",
    region: "us-south",
    locationLabel: "Austin, TX (US South)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 128000, p50: 142000, p75: 158000, p90: 172000 },
    totalComp: { p25: 145000, p50: 168000, p75: 190000, p90: 214000 },
    benefits: STD_BENEFITS,
    equityNote: "Typical RSU grant 0.03%–0.08% vesting over 4 years for this level.",
    sampleSize: 118,
    embeddingText: B("Machine Learning Engineer", "mid", "us-south", "Austin TX"),
    updatedAt: new Date("2026-01-01"),
  },
  {
    benchmarkId: "comp-ml-engineer-senior-us-south",
    role: "Machine Learning Engineer",
    seniority: "senior",
    region: "us-south",
    locationLabel: "Austin, TX (US South)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 150000, p50: 168000, p75: 185000, p90: 205000 },
    totalComp: { p25: 175000, p50: 200000, p75: 232000, p90: 268000 },
    benefits: STD_BENEFITS,
    equityNote: "Typical RSU grant 0.05%–0.12% vesting over 4 years for this level.",
    sampleSize: 142,
    embeddingText: B("Machine Learning Engineer", "senior", "us-south", "Austin TX"),
    updatedAt: new Date("2026-01-01"),
  },
  {
    benchmarkId: "comp-ml-engineer-senior-us-west",
    role: "Machine Learning Engineer",
    seniority: "senior",
    region: "us-west",
    locationLabel: "San Francisco Bay Area (US West)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 180000, p50: 205000, p75: 228000, p90: 250000 },
    totalComp: { p25: 220000, p50: 265000, p75: 310000, p90: 360000 },
    benefits: STD_BENEFITS,
    equityNote: "Typical RSU grant 0.06%–0.15% vesting over 4 years; larger at pre-IPO firms.",
    sampleSize: 205,
    embeddingText: B("Machine Learning Engineer", "senior", "us-west", "San Francisco Bay Area"),
    updatedAt: new Date("2026-01-01"),
  },
  // ── Senior Backend Engineer ──────────────────────────────────────────────
  {
    benchmarkId: "comp-backend-engineer-senior-us-south",
    role: "Senior Backend Engineer",
    seniority: "senior",
    region: "us-south",
    locationLabel: "Austin, TX (US South)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 145000, p50: 162000, p75: 178000, p90: 195000 },
    totalComp: { p25: 165000, p50: 190000, p75: 218000, p90: 248000 },
    benefits: STD_BENEFITS,
    equityNote: "Typical RSU grant 0.04%–0.10% vesting over 4 years for this level.",
    sampleSize: 176,
    embeddingText: B("Senior Backend Engineer", "senior", "us-south", "Austin TX"),
    updatedAt: new Date("2026-01-01"),
  },
  {
    benchmarkId: "comp-backend-engineer-mid-remote-us",
    role: "Backend Engineer",
    seniority: "mid",
    region: "remote-us",
    locationLabel: "Remote (US-wide)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 118000, p50: 132000, p75: 146000, p90: 160000 },
    totalComp: { p25: 130000, p50: 150000, p75: 170000, p90: 192000 },
    benefits: STD_BENEFITS,
    equityNote: "Typical RSU grant 0.02%–0.06% vesting over 4 years for this level.",
    sampleSize: 240,
    embeddingText: B("Backend Engineer", "mid", "remote-us", "Remote US"),
    updatedAt: new Date("2026-01-01"),
  },
  // ── Staff Software Engineer ──────────────────────────────────────────────
  {
    benchmarkId: "comp-staff-engineer-staff-us-west",
    role: "Staff Software Engineer",
    seniority: "staff",
    region: "us-west",
    locationLabel: "San Francisco Bay Area (US West)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 215000, p50: 240000, p75: 265000, p90: 290000 },
    totalComp: { p25: 300000, p50: 360000, p75: 430000, p90: 520000 },
    benefits: STD_BENEFITS,
    equityNote: "Equity is the majority of the delta at this level: 0.1%–0.3% or large RSU refreshers.",
    sampleSize: 96,
    embeddingText: B("Staff Software Engineer", "staff", "us-west", "San Francisco Bay Area"),
    updatedAt: new Date("2026-01-01"),
  },
  {
    benchmarkId: "comp-staff-engineer-staff-us-east",
    role: "Staff Software Engineer",
    seniority: "staff",
    region: "us-east",
    locationLabel: "New York, NY (US East)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 205000, p50: 228000, p75: 252000, p90: 278000 },
    totalComp: { p25: 285000, p50: 340000, p75: 405000, p90: 480000 },
    benefits: STD_BENEFITS,
    equityNote: "Equity 0.08%–0.25% vesting over 4 years; refreshers common at this level.",
    sampleSize: 88,
    embeddingText: B("Staff Software Engineer", "staff", "us-east", "New York NY"),
    updatedAt: new Date("2026-01-01"),
  },
  // ── Data Scientist ───────────────────────────────────────────────────────
  {
    benchmarkId: "comp-data-scientist-mid-us-south",
    role: "Data Scientist",
    seniority: "mid",
    region: "us-south",
    locationLabel: "Austin, TX (US South)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 120000, p50: 135000, p75: 150000, p90: 165000 },
    totalComp: { p25: 135000, p50: 155000, p75: 178000, p90: 200000 },
    benefits: STD_BENEFITS,
    equityNote: "Typical RSU grant 0.02%–0.07% vesting over 4 years for this level.",
    sampleSize: 132,
    embeddingText: B("Data Scientist", "mid", "us-south", "Austin TX"),
    updatedAt: new Date("2026-01-01"),
  },
  {
    benchmarkId: "comp-data-scientist-senior-remote-us",
    role: "Data Scientist",
    seniority: "senior",
    region: "remote-us",
    locationLabel: "Remote (US-wide)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 148000, p50: 165000, p75: 182000, p90: 200000 },
    totalComp: { p25: 170000, p50: 195000, p75: 224000, p90: 255000 },
    benefits: STD_BENEFITS,
    equityNote: "Typical RSU grant 0.04%–0.09% vesting over 4 years for this level.",
    sampleSize: 154,
    embeddingText: B("Data Scientist", "senior", "remote-us", "Remote US"),
    updatedAt: new Date("2026-01-01"),
  },
  // ── Engineering Manager ──────────────────────────────────────────────────
  {
    benchmarkId: "comp-engineering-manager-senior-us-west",
    role: "Engineering Manager",
    seniority: "senior",
    region: "us-west",
    locationLabel: "San Francisco Bay Area (US West)",
    currency: "USD",
    asOf: "2026-01-01",
    baseSalary: { p25: 195000, p50: 218000, p75: 242000, p90: 268000 },
    totalComp: { p25: 260000, p50: 315000, p75: 375000, p90: 445000 },
    benefits: STD_BENEFITS,
    equityNote: "Equity 0.08%–0.2% vesting over 4 years; scope-dependent refreshers.",
    sampleSize: 74,
    embeddingText: B("Engineering Manager", "senior", "us-west", "San Francisco Bay Area"),
    updatedAt: new Date("2026-01-01"),
  },
  {
    benchmarkId: "comp-engineering-manager-senior-emea",
    role: "Engineering Manager",
    seniority: "senior",
    region: "emea",
    locationLabel: "London, UK (EMEA)",
    currency: "GBP",
    asOf: "2026-01-01",
    baseSalary: { p25: 105000, p50: 120000, p75: 135000, p90: 150000 },
    totalComp: { p25: 125000, p50: 148000, p75: 172000, p90: 200000 },
    benefits: ["Pension match up to 8%", "Private health", "25 days holiday", "Remote stipend"],
    equityNote: "Equity typically 0.03%–0.1%; cash-heavier than US West comps.",
    sampleSize: 61,
    embeddingText: B("Engineering Manager", "senior", "emea", "London UK"),
    updatedAt: new Date("2026-01-01"),
  },
];

const { client, db } = await connect();
const col = db.collection("compensation_data");
let upserted = 0;

for (const doc of BENCHMARKS) {
  const res = await col.updateOne({ benchmarkId: doc.benchmarkId }, { $set: doc }, { upsert: true });
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  compensation_data: ${upserted} upserted / ${BENCHMARKS.length} total`);
await client.close();
