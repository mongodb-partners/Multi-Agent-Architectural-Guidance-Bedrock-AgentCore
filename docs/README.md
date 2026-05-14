# Documentation Index

Welcome. This is a **proof-of-concept multi-agent customer-support system** running on AWS Bedrock AgentCore with MongoDB Atlas. Pick the door that matches what you want to do.

---

## What is this project, in one paragraph

A user types a question (e.g. *"Where is my order ORD-1234?"* or *"My device shows error PWR-001"*) into a Streamlit web UI. A small API receives the question and hands it to an **orchestrator AI agent** running on Amazon Bedrock AgentCore. The orchestrator reads the question, decides which **specialist agent** should answer it (one of: order-management, troubleshooting, product-recommendation), and forwards the question to that specialist. The specialist looks up data in **MongoDB Atlas** through a **Lambda function** and replies. The reply streams back to the user. Memory of past conversations is kept in **AgentCore Memory** so agents remember what the user said in prior sessions.

Five AWS services are doing the heavy lifting: Bedrock (the AI model), AgentCore (hosts the agents), Lambda (executes database tools), MongoDB Atlas (the data), and EC2 (runs the web API and UI).

---

## Pick a door

| If you want to… | Read |
|---|---|
| Understand the **system at a glance** | [architecture.md](architecture.md) |
| See the **frozen, accepted design** for the POC | [FROZEN_E2E_DESIGN.md](FROZEN_E2E_DESIGN.md) |
| **Deploy** the system to AWS yourself | [deployment-guide.md](deployment-guide.md) |
| Understand every **environment variable** and config knob | [configuration-guide.md](configuration-guide.md) |
| Call the API or stream chat events | [api-reference.md](api-reference.md) |
| Understand how the system **remembers things** | [memory-architecture.md](memory-architecture.md) |
| Know **what is shipped vs what is missing** vs the SoW | [gap-analysis.md](gap-analysis.md) |
| See the **AgentCore runtime topology** in detail | [agentcore-runtime-design.md](agentcore-runtime-design.md) |
| **Author a new agent** | [agent-authoring-guide.md](agent-authoring-guide.md) |
| **Author a new skill** | [skills-authoring-guide.md](skills-authoring-guide.md) |
| **Run the demo** locally | [demo-script.md](demo-script.md) |
| See **estimated AWS costs** | [estimate.md](estimate.md) |

---

## Architecture diagrams (draw.io)

Editable diagrams live in [`diagrams/`](diagrams/). Open them at [app.diagrams.net](https://app.diagrams.net) (`File → Open → from device`).

| Diagram | What it shows |
|---|---|
| [`01-aws-infrastructure.drawio`](diagrams/01-aws-infrastructure.drawio) | Every AWS resource and how they connect (VPC, EC2, AgentCore runtimes, Lambda, Atlas, supporting services) |
| [`02-request-flow.drawio`](diagrams/02-request-flow.drawio) | A user question travelling through the system, end to end, with every API call labeled |
| [`03-memory-architecture.drawio`](diagrams/03-memory-architecture.drawio) | Short-term and long-term memory — where they live, when they fire |
| [`04-deployment-pipeline.drawio`](diagrams/04-deployment-pipeline.drawio) | The 13 phases of `deploy.sh` and the quick-update path |

The same diagrams are rendered inline (as Mermaid) in [architecture.md](architecture.md) and [memory-architecture.md](memory-architecture.md) so you can read the docs without opening draw.io.

---

## How to run this code

There is one runtime topology: the Hono API is a thin proxy in front of a deployed AgentCore Orchestrator runtime, which then invokes the specialist runtimes. Mongo tool calls go through the dedicated MongoDB MCP AgentCore Runtime; the AgentCore Gateway remains available for non-Mongo tools.

`AGENTCORE_ORCHESTRATOR_ARN` is asserted at startup, so the API will not boot without a deployed orchestrator runtime to point at — locally or on EC2. EC2 mode is what gets provisioned when you run `deploy/scripts/deploy.sh`.

---

## Authoritative source files

When in doubt, code beats docs. Authoritative files for each major concern:

| Concern | File |
|---|---|
| Frozen architectural decisions | [`docs/FROZEN_E2E_DESIGN.md`](FROZEN_E2E_DESIGN.md) |
| Request routing logic | [`api/src/routes/chat.ts`](../api/src/routes/chat.ts) |
| AgentCore invocation | [`api/src/adapters/agentcore-runtime.ts`](../api/src/adapters/agentcore-runtime.ts) |
| Long-term memory | [`api/src/lib/long-term-memory.ts`](../api/src/lib/long-term-memory.ts) |
| Deployment | [`deploy/scripts/deploy.sh`](../deploy/scripts/deploy.sh) |
| Infrastructure | [`deploy/terraform/envs/ec2/main.tf`](../deploy/terraform/envs/ec2/main.tf) |
| MongoDB MCP runtime | [`mcp-runtimes/mongodb-mcp/`](../mcp-runtimes/mongodb-mcp/) |

---

*Last refreshed: 2026-05-01. If a doc here looks stale, fix it — the goal is to keep this folder current with the deployed system, not historical.*
