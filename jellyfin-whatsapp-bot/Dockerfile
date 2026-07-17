FROM node:20-alpine

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@10.33.4 --activate

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./

RUN pnpm install --prod --frozen-lockfile

COPY src/ ./src/

EXPOSE 3555

CMD ["pnpm", "start"]
