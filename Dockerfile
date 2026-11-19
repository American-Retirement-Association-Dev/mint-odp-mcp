# syntax=docker/dockerfile:1

FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-alpine
ENV NODE_ENV=production
# MintMCP hosted connectors expect MCP over HTTP at /mcp on port 8000 (override with PORT for other hosts).
ENV PORT=8000
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE 8000
# No secrets in the image. The ODP key and region arrive per request (X-ODP-* or MintMCP's X-MintMCP-Env-* headers)
# or as connector-wide ODP_API_KEY / ODP_REGION env vars set in MintMCP.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT:-8000}/health" || exit 1
ENTRYPOINT ["node", "dist/index.js"]
