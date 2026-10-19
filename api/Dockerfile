# FreshCart API image
FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production
# Dependencies first: this layer is reused until package*.json changes.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src ./src
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
USER node
EXPOSE 3000
# Used by Docker/Compose/Swarm. Kubernetes IGNORES this and uses its own probes.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/healthz >/dev/null || exit 1
# Exec form: node is PID 1 and receives SIGTERM directly (graceful drain).
CMD ["node", "src/server.js"]
