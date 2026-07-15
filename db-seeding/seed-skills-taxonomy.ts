/**
 * Seed: skills_taxonomy collection  (career-coach agent)
 *
 * Upserts individual skills with learning resources, keyed by `skillId`.
 * Covers every skillId referenced by career_paths (see seed-career-paths.ts).
 * Safe to re-run (idempotent on `skillId`).
 *
 * The `embedding` field is NOT written here — it is backfilled by
 * seed-embeddings.ts from the `embeddingText` field on each document.
 *
 * Schema: config/skills/career-coach/references/collections-schema.md
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-skills-taxonomy.ts
 */

import { connect } from "./connect.ts";

type Resource = { title: string; provider: string; url: string | null; estimatedHours: number };

type Skill = {
  skillId: string;
  name: string;
  category: string;
  description: string;
  prerequisites: string[];
  resourceType: "course" | "book" | "project" | "certification";
  resources: Resource[];
  embeddingText: string;
  updatedAt: Date;
};

const SKILLS: Skill[] = [
  {
    skillId: "skill-python",
    name: "python",
    category: "programming",
    description: "General-purpose language and de-facto standard for ML, data science, and scripting.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Python for Everybody", provider: "Internal L&D", url: "https://learn.example.com/python-everybody", estimatedHours: 25 },
      { title: "Fluent Python (book)", provider: "External", url: null, estimatedHours: 40 },
    ],
    embeddingText: "python programming language for machine learning data science scripting pandas numpy",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-machine-learning",
    name: "machine learning",
    category: "machine-learning",
    description: "Supervised and unsupervised learning fundamentals, model evaluation, and feature engineering.",
    prerequisites: ["skill-python", "skill-statistics"],
    resourceType: "course",
    resources: [
      { title: "Machine Learning Specialization", provider: "Internal L&D", url: "https://learn.example.com/ml-spec", estimatedHours: 60 },
      { title: "Hands-On Machine Learning (book)", provider: "External", url: null, estimatedHours: 45 },
    ],
    embeddingText: "machine learning supervised unsupervised model evaluation feature engineering scikit-learn",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-pytorch",
    name: "pytorch",
    category: "machine-learning",
    description: "Deep-learning framework for building, training, and fine-tuning neural networks.",
    prerequisites: ["skill-python", "skill-machine-learning"],
    resourceType: "course",
    resources: [
      { title: "PyTorch Fundamentals", provider: "Internal L&D", url: "https://learn.example.com/pytorch", estimatedHours: 20 },
      { title: "Deep Learning with PyTorch (book)", provider: "External", url: null, estimatedHours: 30 },
    ],
    embeddingText: "pytorch deep learning neural networks model training fine-tuning tensors autograd",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-vector-search",
    name: "vector search",
    category: "data",
    description: "Embedding-based semantic retrieval for RAG and recommendation systems.",
    prerequisites: ["skill-python"],
    resourceType: "project",
    resources: [
      { title: "Build a RAG pipeline with Atlas Vector Search", provider: "Internal L&D", url: "https://learn.example.com/rag-atlas", estimatedHours: 12 },
      { title: "Vector Databases in Production (article series)", provider: "External", url: "https://example.com/vector-db-series", estimatedHours: 6 },
    ],
    embeddingText: "vector search embeddings semantic retrieval RAG approximate nearest neighbor recommendation",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-system-design",
    name: "system design",
    category: "backend",
    description: "Designing scalable, reliable services: APIs, caching, queues, data stores, and trade-offs.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "System Design Primer", provider: "Internal L&D", url: "https://learn.example.com/system-design", estimatedHours: 30 },
      { title: "Designing Data-Intensive Applications (book)", provider: "External", url: null, estimatedHours: 50 },
    ],
    embeddingText: "system design scalability reliability APIs caching queues data stores load balancing trade-offs",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-distributed-systems",
    name: "distributed systems",
    category: "backend",
    description: "Consistency models, partitioning, replication, consensus, and fault tolerance.",
    prerequisites: ["skill-system-design"],
    resourceType: "course",
    resources: [
      { title: "Distributed Systems Course", provider: "Internal L&D", url: "https://learn.example.com/distributed", estimatedHours: 35 },
      { title: "MIT 6.824 lectures", provider: "External", url: "https://example.com/mit-6824", estimatedHours: 40 },
    ],
    embeddingText: "distributed systems consistency partitioning replication consensus fault tolerance CAP theorem",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-technical-leadership",
    name: "technical leadership",
    category: "leadership",
    description: "Leading design reviews, driving technical decisions, and setting quality bars across a team.",
    prerequisites: [],
    resourceType: "book",
    resources: [
      { title: "The Staff Engineer's Path (book)", provider: "External", url: null, estimatedHours: 15 },
      { title: "Leading design reviews (internal playbook)", provider: "Internal L&D", url: "https://learn.example.com/design-reviews", estimatedHours: 5 },
    ],
    embeddingText: "technical leadership design reviews decision making quality bar team influence direction",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-mentoring",
    name: "mentoring",
    category: "leadership",
    description: "Growing other engineers through coaching, onboarding, and constructive feedback.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Mentoring Engineers", provider: "Internal L&D", url: "https://learn.example.com/mentoring", estimatedHours: 6 },
    ],
    embeddingText: "mentoring coaching onboarding feedback growing engineers pairing knowledge sharing",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-technical-strategy",
    name: "technical strategy",
    category: "leadership",
    description: "Setting multi-quarter technical direction aligned to business goals.",
    prerequisites: ["skill-technical-leadership"],
    resourceType: "book",
    resources: [
      { title: "Technical strategy for staff+ engineers", provider: "Internal L&D", url: "https://learn.example.com/tech-strategy", estimatedHours: 10 },
      { title: "An Elegant Puzzle (book)", provider: "External", url: null, estimatedHours: 12 },
    ],
    embeddingText: "technical strategy roadmap direction business alignment multi-quarter planning prioritization",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-cross-team-influence",
    name: "cross-team influence",
    category: "leadership",
    description: "Aligning multiple teams and driving initiatives without direct authority.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Influence without authority", provider: "Internal L&D", url: "https://learn.example.com/influence", estimatedHours: 8 },
    ],
    embeddingText: "cross-team influence alignment stakeholders driving initiatives without authority negotiation buy-in",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-architecture",
    name: "architecture",
    category: "backend",
    description: "Owning architecture across a domain: boundaries, contracts, and evolution over time.",
    prerequisites: ["skill-system-design", "skill-distributed-systems"],
    resourceType: "course",
    resources: [
      { title: "Software Architecture in Practice", provider: "Internal L&D", url: "https://learn.example.com/architecture", estimatedHours: 25 },
    ],
    embeddingText: "software architecture domain boundaries service contracts evolution modularity design patterns",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-technical-writing",
    name: "technical writing",
    category: "communication",
    description: "Writing RFCs, design docs, and strategy documents that drive decisions.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Technical Writing for Engineers", provider: "Internal L&D", url: "https://learn.example.com/tech-writing", estimatedHours: 8 },
    ],
    embeddingText: "technical writing RFC design docs strategy documents clear communication documentation",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-statistics",
    name: "statistics",
    category: "data",
    description: "Descriptive and inferential statistics: distributions, hypothesis testing, and estimation.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Statistics for Data Science", provider: "Internal L&D", url: "https://learn.example.com/statistics", estimatedHours: 30 },
      { title: "Practical Statistics for Data Scientists (book)", provider: "External", url: null, estimatedHours: 25 },
    ],
    embeddingText: "statistics probability distributions hypothesis testing inference estimation confidence intervals",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-experimentation",
    name: "experimentation",
    category: "data",
    description: "Designing and analyzing A/B tests and controlled experiments.",
    prerequisites: ["skill-statistics"],
    resourceType: "course",
    resources: [
      { title: "A/B Testing & Experimentation", provider: "Internal L&D", url: "https://learn.example.com/ab-testing", estimatedHours: 15 },
    ],
    embeddingText: "experimentation A/B testing controlled experiments randomization power analysis causal inference",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-sql",
    name: "sql",
    category: "data",
    description: "Querying, joining, and shaping analytical datasets with SQL.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "SQL for Analytics", provider: "Internal L&D", url: "https://learn.example.com/sql-analytics", estimatedHours: 18 },
    ],
    embeddingText: "sql queries joins aggregation window functions analytical datasets data warehouse",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-people-management",
    name: "people management",
    category: "management",
    description: "Running 1:1s, growth planning, and performance feedback for direct reports.",
    prerequisites: [],
    resourceType: "book",
    resources: [
      { title: "The Manager's Path (book)", provider: "External", url: null, estimatedHours: 14 },
      { title: "First-time manager fundamentals", provider: "Internal L&D", url: "https://learn.example.com/first-manager", estimatedHours: 10 },
    ],
    embeddingText: "people management one-on-ones growth planning performance feedback direct reports coaching",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-delivery-management",
    name: "delivery management",
    category: "management",
    description: "Planning, prioritization, and predictable delivery of team commitments.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Agile delivery for engineering managers", provider: "Internal L&D", url: "https://learn.example.com/agile-delivery", estimatedHours: 8 },
    ],
    embeddingText: "delivery management planning prioritization estimation predictable delivery agile roadmap execution",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-hiring",
    name: "hiring",
    category: "management",
    description: "Interviewing, evaluating, and closing candidates to build a team.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Structured interviewing & hiring", provider: "Internal L&D", url: "https://learn.example.com/hiring", estimatedHours: 6 },
    ],
    embeddingText: "hiring interviewing candidate evaluation closing offers building a team structured interviews",
    updatedAt: new Date("2026-01-01"),
  },
  {
    skillId: "skill-stakeholder-communication",
    name: "stakeholder communication",
    category: "communication",
    description: "Translating between executives, product, and engineers to keep everyone aligned.",
    prerequisites: [],
    resourceType: "course",
    resources: [
      { title: "Communicating with stakeholders", provider: "Internal L&D", url: "https://learn.example.com/stakeholder-comms", estimatedHours: 6 },
    ],
    embeddingText: "stakeholder communication executive updates product alignment status reporting expectation management",
    updatedAt: new Date("2026-01-01"),
  },
];

const { client, db } = await connect();
const col = db.collection("skills_taxonomy");
let upserted = 0;

for (const doc of SKILLS) {
  const res = await col.updateOne({ skillId: doc.skillId }, { $set: doc }, { upsert: true });
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  skills_taxonomy: ${upserted} upserted / ${SKILLS.length} total`);
await client.close();
