# Build context is the repo root: docker build -f apps/server/Dockerfile .
FROM node:24.20.0-slim AS build
WORKDIR /app
RUN corepack enable

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.base.json ./
COPY packages/protocol/package.json packages/protocol/package.json
COPY apps/server/package.json apps/server/package.json
RUN pnpm install --frozen-lockfile

COPY packages/protocol packages/protocol
COPY apps/server apps/server
RUN pnpm build && pnpm --filter @wadjet/server deploy --prod /deploy

FROM node:24.20.0-slim
WORKDIR /app

COPY --from=build --chown=node:node /deploy ./
RUN mkdir -p /data && chown node:node /data

USER node
ENV NODE_ENV=production \
    WADJET_DATA_DIR=/data \
    PORT=8787
VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/node.js"]
