# Node 24 LTS (supported until 2028-04-30). Pinned to an exact patch release
# so the Node version only changes through a PR; no digest, so a rebuild still
# picks up the Alpine security fixes Docker re-publishes under this tag.
# https://github.com/nodejs/Release/blob/main/schedule.json
FROM node:24.22.2-alpine

WORKDIR /app

COPY package*.json ./

# npm ci: install exactly what package-lock.json pins (fails if the two
# disagree); --omit=dev keeps dev dependencies out of the runtime image.
RUN npm ci --omit=dev && npm cache clean --force

COPY . .

# The base image's built-in unprivileged user (uid/gid 1000). App files stay
# root-owned and read-only to it; the Deployment's securityContext pins the
# same uid and enforces runAsNonRoot (PLAT-512).
USER node

EXPOSE 3000

CMD ["node", "index.js"]
