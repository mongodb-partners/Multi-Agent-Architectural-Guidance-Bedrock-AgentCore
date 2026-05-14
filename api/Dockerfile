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

RUN chown -R bun:bun /app
USER bun

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD bun -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1))"

CMD ["bun", "run", "src/index.ts"]
