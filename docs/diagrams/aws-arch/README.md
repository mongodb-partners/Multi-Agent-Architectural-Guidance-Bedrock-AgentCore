# AWS Architecture Diagrams

Open any `.drawio` file at [app.diagrams.net](https://app.diagrams.net) → `File → Open from → Device`.

Read them in order — each one zooms into a specific concern.

| # | File | What it explains | Start here if you want to… |
|---|---|---|---|
| 01 | [`01-big-picture.drawio`](01-big-picture.drawio) | The entire system in one slide — user to DB and back | Explain the system to anyone new in 60 seconds |
| 02 | [`02-vpc-networking.drawio`](02-vpc-networking.drawio) | VPC layout, subnets, security groups, PrivateLink, Route 53 | Understand why MongoDB is secure + how traffic flows |
| 03 | [`03-agentcore-runtimes.drawio`](03-agentcore-runtimes.drawio) | The 4 AgentCore Runtimes, how the same code becomes 4 agents, IAM | Understand agent isolation + S3 code artifact model |
| 04 | [`04-request-sequence.drawio`](04-request-sequence.drawio) | Every single API call, in order, for one chat message | Debug a failing request or explain latency |
| 05 | [`05-lambda-mcp-tools.drawio`](05-lambda-mcp-tools.drawio) | The Lambda function internals — 3 tools, MongoDB connection, PrivateLink | Understand how data is fetched from Atlas |
| 06 | [`06-memory-and-sessions.drawio`](06-memory-and-sessions.drawio) | Short-term vs long-term memory, backends, which agents use what | Understand why the system "remembers" things |
| 07 | [`07-iam-and-security.drawio`](07-iam-and-security.drawio) | Every IAM role, its trust, its permissions, Cognito JWT flow | Security review or permission troubleshooting |

---

## How to open in draw.io

1. Go to [app.diagrams.net](https://app.diagrams.net)
2. Click **File → Open from → Device**
3. Select the `.drawio` file
4. Zoom, edit, export as PNG/PDF as needed

Or use the VS Code [draw.io extension](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio) to open them inline.

---

## Colour coding used across all diagrams

| Colour | Means |
|---|---|
| Blue | User-facing / frontend |
| Yellow | EC2 compute + configuration |
| Light blue | AgentCore runtimes |
| Light green | Specialist agents + MongoDB data |
| Orange | Lambda |
| Purple | Memory / identity |
| Dark green | MongoDB Atlas + Bedrock models |
| Red border | Security / IAM |
| Dashed border | Parked or optional component |
