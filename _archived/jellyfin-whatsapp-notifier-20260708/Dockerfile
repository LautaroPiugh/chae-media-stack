FROM node:20-alpine

RUN apk add --no-cache git

RUN corepack enable && corepack prepare pnpm@9.15.0 --activate

WORKDIR /app

COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --no-frozen-lockfile

COPY src ./src

EXPOSE 3555

CMD ["node", "src/server.js"]