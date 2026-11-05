# Node 24 LTS (supported until 2028-04-30). Pinned to an exact patch release
# and index digest so a rebuild can't silently change the runtime; bump both
# together. https://github.com/nodejs/Release/blob/main/schedule.json
FROM node:24.22.2-alpine3.24@sha256:8a32c8cf649a49915a66e81e7a609223c708d0adabf288ee3f4077d765542f85

WORKDIR /app

COPY package*.json ./

# npm ci: install exactly what package-lock.json pins (fails if the two
# disagree); --omit=dev keeps dev dependencies out of the runtime image.
RUN npm ci --omit=dev && npm cache clean --force

COPY . .

EXPOSE 3000

CMD ["node", "index.js"]
