# High-Level Technical Approach

## At A Glance

This proof-of-concept is a **configuration-driven multi-agent platform** for client demos. It shows how domain-specific AI assistants can be assembled from reusable platform components rather than hard-coded workflows.

The core building blocks are:
- A BunJs/Hono/Typescript API
- A Streamlit user interface
- AWS Cognito authentication for secure user sign-in and API access control
- The Strands Agents SDK for orchestration
- Bedrock AgentCore SDK for production runtime, gateway, and sandboxed execution
- MongoDB-backed tools for data access, memory, and retrieval
- PrivateLink-based connectivity for secure database access

The architectural goal is to support multiple specialist agents while keeping the platform modular, understandable, and easy to extend.

## Config-First Extension Model

The design is intentionally **config-first**.

- Agent personas are defined in `.agent.md` files using the **VS Code custom agents format**, which provides a clear, markdown-based structure for describing agent identity, behavior, tools, and routing rules.
- Domain knowledge is packaged in `SKILL.md` files using the **Agent Skills standard** (`agentskills.io`), an open format for expressing reusable domain instructions, references, and supporting assets; when a skill requires technical execution, the corresponding `scripts/` files should be included as part of the skill package.
- System behavior is shaped primarily through declarative configuration instead of application code.
- In this project, the delivered agent set includes an **Orchestrator** plus three specialists: **Order Management**, **Product Recommendation**, and **Troubleshooting**.

This gives the platform a strong extension model: specialist behaviors can be added or refined through controlled markdown changes rather than repeated code customization. From an architectural perspective, that improves readability and maintainability, while making it easier to onboard new domain use cases on top of the same core platform and base tools.

## Platform Interaction Model

At a high level, the platform works as follows:

- User requests flow from the Streamlit interface to the BunJs/Hono API over SSE.
- The API invokes Strands agents whose personas, skills, and routing behavior are defined through markdown configuration.
- Agents use MongoDB-backed tools for operational data access, retrieval, and conversational continuity.
- Session context and memory enable the system to support multi-turn interactions across specialist agents.

This creates a clear separation between the user experience layer, the orchestration layer, and the underlying data and tool layer.

