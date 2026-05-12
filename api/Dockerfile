# Hono API (Bun) — build from **repository root**:
#   docker build -f api/Dockerfile -t multi-agent-api:local .
#
# Layout in the image: /app = api package root; /app/config
# matches resolveConfigRoot().

FROM oven/bun:1 AS runtime

WORKDIR /app

ENV NODE_ENV=production \
    PORT=3000

COPY api/package.json api/bun.lock ./
RUN bun install --frozen-lockfile --production

COPY api/tsconfig.json ./
COPY api/src ./src
COPY config ./config

# Shared MongoDB MCP guards — imported by api/src/adapters/mongo-data.ts via
# `../../../lambda/mongodb-mcp/guards.mjs`. Going up 3 levels from
# `/app/src/adapters/` lands at the filesystem ROOT (`/`), not `/app`, because
# the source-tree layout assumes `api/` is one level under repo root but the
# image flattens that. Copy to `/lambda/mongodb-mcp/` (outside /app) so the
# relative path resolves the same way at runtime as it does in source.
COPY lambda/mongodb-mcp/guards.mjs /lambda/mongodb-mcp/guards.mjs
COPY lambda/mongodb-mcp/guards.d.mts /lambda/mongodb-mcp/guards.d.mts

RUN chown -R bun:bun /app /lambda
USER bun

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD bun -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1))"

CMD ["bun", "run", "src/index.ts"]
