# Server image for Fly.io (or any Docker host). Build from the repository root:
#   docker build -t haleys-pancreas .
# Fly.io picks this file up automatically when you run `fly deploy` in this folder.

FROM node:22-alpine AS build
WORKDIR /app
COPY server/package.json server/package-lock.json server/tsconfig.json ./
RUN npm ci
COPY server/src ./src
RUN npm run build && npm prune --omit=dev

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production \
    DATA_DIR=/data \
    PORT=8080
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
EXPOSE 8080
# Runs as root because Fly volumes are mounted owned by root, and the server saves /data/state.json.
CMD ["node", "dist/index.js"]
