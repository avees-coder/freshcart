# FreshCart storefront image: build with Node, serve with nginx.
# ---- stage 1: build the static site with Vite ----
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG APP_VERSION=dev
ENV VITE_APP_VERSION=${APP_VERSION}
RUN npm run build

# ---- stage 2: serve it (no Node, no source, no build tools at runtime) ----
FROM nginx:1.30-alpine
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY nginx/15-resolver.envsh /docker-entrypoint.d/15-resolver.envsh
RUN chmod +x /docker-entrypoint.d/15-resolver.envsh
COPY --from=build /app/dist /usr/share/nginx/html
# Defaults suit Compose and Swarm; Kubernetes overrides API_HOST with the FQDN.
ENV API_HOST=api API_PORT=3000
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1/healthz >/dev/null || exit 1
