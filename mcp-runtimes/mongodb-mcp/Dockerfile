# mongodb-mcp — AgentCore Runtime container hosting an MCP server for the
# MongoDB tool surface (mongodb_query, mongodb_vector_search, mongodb_aggregate).
#
# Per AgentCore Runtime contract for MCP servers:
#   - ARM64 image (linux/arm64)
#   - Streamable-HTTP transport on 0.0.0.0:8000/mcp
#
# Build context = `mcp-runtimes/mongodb-mcp/`. Tool implementations
# (handlers / guards / tracing / diagnostics) live in `src/vendor/` — that
# directory is the canonical home for the MongoDB MCP tool semantics. The
# legacy `lambda/mongodb-mcp/` Lambda host has been deleted (CLIENT_REVIEW
# Phase 7e); rolling back means restoring it from git history and re-pointing
# the AgentCore Gateway target back to a Lambda variant.

# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM --platform=linux/arm64 node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --no-audit --no-fund

COPY tsconfig.json ./
COPY src/server.ts  src/server.ts
COPY src/schemas.ts src/schemas.ts
COPY src/index.ts   src/index.ts
COPY src/vendor     src/vendor
COPY src/lib        src/lib

RUN npx tsc

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM --platform=linux/arm64 node:20-alpine

WORKDIR /app

ENV NODE_ENV=production \
    PORT=8000 \
    HOST=0.0.0.0

COPY --from=builder /app/package.json /app/package-lock.json* ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/src/vendor ./dist/vendor

EXPOSE 8000

# Run as non-root for defense in depth.
RUN addgroup -S mcp && adduser -S mcp -G mcp && chown -R mcp:mcp /app
USER mcp

CMD ["node", "dist/index.js"]
