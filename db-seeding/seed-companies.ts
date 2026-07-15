/**
 * Seed: companies collection  (company-intel agent)
 *
 * Upserts company research profiles keyed by `companyId`.
 * Safe to re-run (idempotent on `companyId`).
 *
 * Company names align with the job-match demo data and demo-prompts
 * (Lumen Retail, Vertex Commerce, Cloudpeak Systems) so a candidate can be
 * matched to a job and then research the hiring company in the same session.
 *
 * The `embedding` field is NOT written here — it is backfilled by
 * seed-embeddings.ts from the `embeddingText` field on each document.
 *
 * All culture/sentiment content is ILLUSTRATIVE demo data.
 *
 * Schema: config/skills/company-intel/references/collections-schema.md
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-companies.ts
 */

import { connect } from "./connect.ts";

type Company = {
  companyId: string;
  name: string;
  industry: string;
  stage: string;
  foundedYear: number;
  headcount: string;
  fundingTotal: string | null;
  headquarters: string;
  description: string;
  embeddingText: string;
  cultureSignals: string[];
  engineeringPractices: string[];
  sentimentSummary: string;
  pros: string[];
  cons: string[];
  sentimentScore: number;
  asOf: string;
  updatedAt: Date;
};

const COMPANIES: Company[] = [
  {
    companyId: "co-lumen-retail",
    name: "Lumen Retail",
    industry: "Retail / E-commerce",
    stage: "Series C",
    foundedYear: 2014,
    headcount: "1,000–5,000",
    fundingTotal: "$310M",
    headquarters: "Austin, TX",
    description:
      "Lumen Retail is a mid-to-late-stage e-commerce company building search, recommendations, " +
      "and personalization for a large online marketplace. Engineering is organized around " +
      "product-aligned teams with a growing ML/search function.",
    embeddingText:
      "Lumen Retail e-commerce retail Series C Austin Texas search recommendations personalization " +
      "machine learning remote-friendly mentorship fast release cadence trunk-based development on-call",
    cultureSignals: ["Remote-friendly", "Strong mentorship", "Fast release cadence", "Data-driven decisions"],
    engineeringPractices: ["Trunk-based development", "On-call rotation (1 week / 6)", "RFC design reviews", "Weekly ship demos"],
    sentimentSummary:
      "Engineers praise autonomy, modern tooling, and clear growth paths. Some note high pace " +
      "and long hours during peak retail seasons (Q4). Mentorship and onboarding are frequently called out as strengths.",
    pros: ["Modern stack", "Growth opportunities", "Good mentorship", "Remote-friendly"],
    cons: ["Seasonal crunch (Q4)", "Rapidly changing priorities"],
    sentimentScore: 4.1,
    asOf: "2026-01-01",
    updatedAt: new Date("2026-01-01"),
  },
  {
    companyId: "co-vertex-commerce",
    name: "Vertex Commerce",
    industry: "E-commerce / Payments",
    stage: "Series B",
    foundedYear: 2017,
    headcount: "201–500",
    fundingTotal: "$95M",
    headquarters: "Remote-first (US)",
    description:
      "Vertex Commerce builds high-throughput commerce and payments infrastructure. " +
      "The engineering culture is backend-heavy with a strong emphasis on reliability, " +
      "TypeScript/Node.js services, and MongoDB-backed data platforms.",
    embeddingText:
      "Vertex Commerce e-commerce payments Series B remote-first backend TypeScript Node.js MongoDB " +
      "high throughput reliability microservices API design engineering rigor async culture",
    cultureSignals: ["Remote-first", "Async-friendly", "High engineering rigor", "Ownership culture"],
    engineeringPractices: ["Microservices (Node.js/TypeScript)", "Design reviews for all services", "Blameless post-mortems", "Heavy automated testing"],
    sentimentSummary:
      "Employees value the remote-first, async culture and the technical bar. A few mention that " +
      "the high rigor can slow shipping, and that being fully remote requires strong self-direction. " +
      "Compensation is seen as competitive for a Series B company.",
    pros: ["True remote-first", "Strong engineering culture", "Competitive pay for stage", "Good work-life balance"],
    cons: ["Process can slow delivery", "Requires self-direction", "Smaller brand recognition"],
    sentimentScore: 4.3,
    asOf: "2026-01-01",
    updatedAt: new Date("2026-01-01"),
  },
  {
    companyId: "co-cloudpeak-systems",
    name: "Cloudpeak Systems",
    industry: "Cloud Infrastructure / DevTools",
    stage: "Series D",
    foundedYear: 2011,
    headcount: "1,000–5,000",
    fundingTotal: "$480M",
    headquarters: "Seattle, WA",
    description:
      "Cloudpeak Systems provides cloud infrastructure and developer tooling. " +
      "A more established engineering org with mature platform teams, strong on-call " +
      "discipline, and a broad microservices estate spanning several languages.",
    embeddingText:
      "Cloudpeak Systems cloud infrastructure developer tools Series D Seattle Washington platform teams " +
      "microservices reliability on-call discipline mature engineering GraphQL REST Docker CI/CD",
    cultureSignals: ["Established / stable", "Strong platform teams", "Structured career ladder", "In-office hybrid"],
    engineeringPractices: ["Mature CI/CD", "Formal on-call with SLOs", "Architecture review board", "Polyglot microservices"],
    sentimentSummary:
      "Engineers cite stability, strong benefits, and a clear promotion ladder. Some describe the " +
      "environment as slower-moving and more process-heavy than a startup, with hybrid in-office " +
      "expectations. Good fit for those who value structure and depth over pace.",
    pros: ["Stability & strong benefits", "Clear promotion ladder", "Deep technical problems", "Good mentorship for platform work"],
    cons: ["Slower-moving / process-heavy", "Hybrid in-office expectation", "Larger-org bureaucracy"],
    sentimentScore: 3.9,
    asOf: "2026-01-01",
    updatedAt: new Date("2026-01-01"),
  },
  {
    companyId: "co-northwind-analytics",
    name: "Northwind Analytics",
    industry: "Data / Analytics SaaS",
    stage: "Series A",
    foundedYear: 2020,
    headcount: "51–200",
    fundingTotal: "$28M",
    headquarters: "Remote-first (US)",
    description:
      "Northwind Analytics builds a data-analytics SaaS platform for mid-market companies. " +
      "Early-stage, fast-moving, with a small but senior engineering team and a strong data-science bent.",
    embeddingText:
      "Northwind Analytics data analytics SaaS Series A remote-first early stage startup senior team " +
      "data science Python SQL experimentation fast-moving high ownership equity-heavy",
    cultureSignals: ["Early-stage startup", "High ownership", "Flat structure", "Data-science-driven"],
    engineeringPractices: ["Ship-fast culture", "Lightweight reviews", "Data-informed roadmap", "Small on-call team"],
    sentimentSummary:
      "Team members enjoy high ownership, direct impact, and equity upside. The trade-off is the " +
      "typical early-stage volatility: shifting priorities, lean headcount, and less formal process. " +
      "Best suited to engineers who thrive with ambiguity.",
    pros: ["High impact & ownership", "Meaningful equity", "Flat, fast structure", "Senior peers"],
    cons: ["Early-stage volatility", "Lean headcount / wide scope", "Less structure & mentorship"],
    sentimentScore: 4.0,
    asOf: "2026-01-01",
    updatedAt: new Date("2026-01-01"),
  },
];

const { client, db } = await connect();
const col = db.collection("companies");
let upserted = 0;

for (const doc of COMPANIES) {
  const res = await col.updateOne({ companyId: doc.companyId }, { $set: doc }, { upsert: true });
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  companies: ${upserted} upserted / ${COMPANIES.length} total`);
await client.close();
