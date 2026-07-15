FROM node:20-alpine

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@10.33.4 --activate
RUN apk add --no-cache docker-cli

COPY package.json pnpm-lock.yaml* ./

RUN pnpm install --frozen-lockfile || pnpm install

COPY . .

EXPOSE 3555

CMD ["pnpm", "start"]
