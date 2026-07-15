/**
 * Seed: career_paths collection  (career-coach agent)
 *
 * Upserts documented role-progression paths keyed by `pathId`.
 * Safe to re-run (idempotent on `pathId`).
 *
 * The `embedding` field is NOT written here — it is backfilled by
 * seed-embeddings.ts from the `embeddingText` field on each document.
 *
 * Schema: config/skills/career-coach/references/collections-schema.md
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-career-paths.ts
 */

import { connect } from "./connect.ts";

type RequiredSkill = { skillId: string; name: string; importance: "core" | "important" | "nice"; note: string };
type Milestone = { order: number; title: string; skills: string[]; estimatedWeeks: number };

type CareerPath = {
  pathId: string;
  targetRole: string;
  fromRoles: string[];
  seniority: "junior" | "mid" | "senior" | "staff";
  description: string;
  embeddingText: string;
  requiredSkills: RequiredSkill[];
  milestones: Milestone[];
  updatedAt: Date;
};

const PATHS: CareerPath[] = [
  {
    pathId: "path-backend-to-ml-engineer",
    targetRole: "Machine Learning Engineer",
    fromRoles: ["Backend Engineer", "Full-Stack Engineer"],
    seniority: "mid",
    description:
      "Transition from a backend/full-stack engineering role into ML engineering. " +
      "Leverages existing software engineering strength (APIs, data modeling, production systems) " +
      "and layers on applied machine learning, model training, and retrieval/RAG systems. " +
      "Focuses on shipping ML in production rather than pure research.",
    embeddingText:
      "Machine Learning Engineer transition from backend full-stack engineer. " +
      "Python, machine learning fundamentals, PyTorch model training, vector search retrieval RAG. " +
      "Mid-level ML engineering, production ML systems, applied modeling.",
    requiredSkills: [
      { skillId: "skill-python", name: "python", importance: "core", note: "Primary language for ML tooling and pipelines" },
      { skillId: "skill-machine-learning", name: "machine learning", importance: "core", note: "Supervised/unsupervised fundamentals, evaluation, feature engineering" },
      { skillId: "skill-pytorch", name: "pytorch", importance: "important", note: "Model training and fine-tuning framework" },
      { skillId: "skill-vector-search", name: "vector search", importance: "nice", note: "For retrieval and RAG systems" },
    ],
    milestones: [
      { order: 1, title: "Foundations — Python for ML & core math", skills: ["skill-python", "skill-machine-learning"], estimatedWeeks: 8 },
      { order: 2, title: "Applied modeling with PyTorch", skills: ["skill-pytorch"], estimatedWeeks: 6 },
      { order: 3, title: "Production ML & retrieval systems", skills: ["skill-vector-search"], estimatedWeeks: 4 },
    ],
    updatedAt: new Date("2026-01-01"),
  },
  {
    pathId: "path-mid-to-senior-backend",
    targetRole: "Senior Backend Engineer",
    fromRoles: ["Backend Engineer", "Software Engineer"],
    seniority: "senior",
    description:
      "Progress from a mid-level backend engineer to a senior backend engineer. " +
      "Emphasizes distributed systems design, ownership of services end to end, " +
      "technical leadership within a team, and mentoring. The step up is less about new " +
      "languages and more about scope, judgment, and system-level thinking.",
    embeddingText:
      "Senior Backend Engineer progression from mid-level backend software engineer. " +
      "Distributed systems, system design, technical leadership, mentoring, service ownership, " +
      "scalability, observability, on-call maturity.",
    requiredSkills: [
      { skillId: "skill-system-design", name: "system design", importance: "core", note: "Design scalable, reliable distributed services" },
      { skillId: "skill-distributed-systems", name: "distributed systems", importance: "core", note: "Consistency, partitioning, fault tolerance" },
      { skillId: "skill-technical-leadership", name: "technical leadership", importance: "important", note: "Lead design reviews and drive cross-team decisions" },
      { skillId: "skill-mentoring", name: "mentoring", importance: "nice", note: "Grow junior engineers, run onboarding" },
    ],
    milestones: [
      { order: 1, title: "Deepen distributed systems & system design", skills: ["skill-system-design", "skill-distributed-systems"], estimatedWeeks: 10 },
      { order: 2, title: "Own a service end to end (design → on-call)", skills: ["skill-system-design"], estimatedWeeks: 8 },
      { order: 3, title: "Lead reviews and mentor", skills: ["skill-technical-leadership", "skill-mentoring"], estimatedWeeks: 6 },
    ],
    updatedAt: new Date("2026-01-01"),
  },
  {
    pathId: "path-senior-to-staff-engineer",
    targetRole: "Staff Software Engineer",
    fromRoles: ["Senior Software Engineer", "Senior Backend Engineer"],
    seniority: "staff",
    description:
      "Move from senior engineer to staff engineer. The transition is about organizational " +
      "impact: setting technical direction across multiple teams, driving ambiguous " +
      "cross-cutting initiatives, and multiplying the effectiveness of other engineers. " +
      "Deep technical skill is assumed; the differentiator is influence, strategy, and scope.",
    embeddingText:
      "Staff Software Engineer progression from senior engineer. " +
      "Technical strategy, cross-team influence, architecture at org scale, " +
      "driving ambiguous initiatives, technical writing, stakeholder alignment, force multiplier.",
    requiredSkills: [
      { skillId: "skill-technical-strategy", name: "technical strategy", importance: "core", note: "Set multi-quarter technical direction" },
      { skillId: "skill-cross-team-influence", name: "cross-team influence", importance: "core", note: "Align multiple teams without direct authority" },
      { skillId: "skill-architecture", name: "architecture", importance: "important", note: "Own architecture across a domain, not a single service" },
      { skillId: "skill-technical-writing", name: "technical writing", importance: "nice", note: "Write RFCs and strategy docs that move the org" },
    ],
    milestones: [
      { order: 1, title: "Own a cross-cutting architecture initiative", skills: ["skill-architecture", "skill-technical-strategy"], estimatedWeeks: 12 },
      { order: 2, title: "Drive alignment across teams via RFCs", skills: ["skill-cross-team-influence", "skill-technical-writing"], estimatedWeeks: 10 },
      { order: 3, title: "Establish technical direction for the domain", skills: ["skill-technical-strategy"], estimatedWeeks: 8 },
    ],
    updatedAt: new Date("2026-01-01"),
  },
  {
    pathId: "path-fullstack-to-data-scientist",
    targetRole: "Data Scientist",
    fromRoles: ["Full-Stack Engineer", "Backend Engineer", "Data Analyst"],
    seniority: "mid",
    description:
      "Transition from a software/full-stack engineering background into data science. " +
      "Builds on programming strength and adds statistics, experimentation, and modeling. " +
      "Suited to engineers who enjoy data modeling and want to move toward insight generation " +
      "and predictive modeling rather than pure application development.",
    embeddingText:
      "Data Scientist transition from full-stack backend engineer or data analyst. " +
      "Python, statistics, experimentation A/B testing, SQL, data visualization, " +
      "machine learning modeling, mid-level data science.",
    requiredSkills: [
      { skillId: "skill-python", name: "python", importance: "core", note: "pandas, numpy, scikit-learn ecosystem" },
      { skillId: "skill-statistics", name: "statistics", importance: "core", note: "Hypothesis testing, distributions, inference" },
      { skillId: "skill-experimentation", name: "experimentation", importance: "important", note: "A/B testing design and analysis" },
      { skillId: "skill-sql", name: "sql", importance: "important", note: "Query and shape analytical datasets" },
      { skillId: "skill-machine-learning", name: "machine learning", importance: "nice", note: "Predictive modeling fundamentals" },
    ],
    milestones: [
      { order: 1, title: "Statistics & Python for data", skills: ["skill-statistics", "skill-python"], estimatedWeeks: 8 },
      { order: 2, title: "Analytics engineering with SQL", skills: ["skill-sql"], estimatedWeeks: 4 },
      { order: 3, title: "Experimentation & modeling", skills: ["skill-experimentation", "skill-machine-learning"], estimatedWeeks: 8 },
    ],
    updatedAt: new Date("2026-01-01"),
  },
  {
    pathId: "path-engineer-to-engineering-manager",
    targetRole: "Engineering Manager",
    fromRoles: ["Senior Software Engineer", "Tech Lead"],
    seniority: "senior",
    description:
      "Move from an individual-contributor engineering role into engineering management. " +
      "The shift is fundamental: success is measured through the team, not personal output. " +
      "Focuses on people management, delivery, hiring, and stakeholder communication while " +
      "retaining enough technical depth to earn the team's trust.",
    embeddingText:
      "Engineering Manager transition from senior software engineer or tech lead. " +
      "People management, one-on-ones, performance feedback, hiring, delivery management, " +
      "stakeholder communication, team leadership.",
    requiredSkills: [
      { skillId: "skill-people-management", name: "people management", importance: "core", note: "1:1s, growth planning, performance feedback" },
      { skillId: "skill-delivery-management", name: "delivery management", importance: "core", note: "Planning, prioritization, predictable delivery" },
      { skillId: "skill-hiring", name: "hiring", importance: "important", note: "Interviewing, closing, building a team" },
      { skillId: "skill-stakeholder-communication", name: "stakeholder communication", importance: "important", note: "Translate between execs and engineers" },
    ],
    milestones: [
      { order: 1, title: "Foundations of people management", skills: ["skill-people-management"], estimatedWeeks: 6 },
      { order: 2, title: "Delivery & prioritization", skills: ["skill-delivery-management"], estimatedWeeks: 6 },
      { order: 3, title: "Hiring & stakeholder communication", skills: ["skill-hiring", "skill-stakeholder-communication"], estimatedWeeks: 6 },
    ],
    updatedAt: new Date("2026-01-01"),
  },
];

const { client, db } = await connect();
const col = db.collection("career_paths");
let upserted = 0;

for (const doc of PATHS) {
  const res = await col.updateOne({ pathId: doc.pathId }, { $set: doc }, { upsert: true });
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  career_paths: ${upserted} upserted / ${PATHS.length} total`);
await client.close();
