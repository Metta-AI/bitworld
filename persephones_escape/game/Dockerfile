FROM node:22-slim

WORKDIR /app/persephones_escape
COPY persephones_escape/package.json persephones_escape/package-lock.json ./
RUN npm ci
COPY persephones_escape/ ./
COPY common/ /app/common/

EXPOSE 8080
CMD ["npx", "tsx", "server.ts"]
