# Stage 1: base
FROM node:24-alpine AS base
WORKDIR /app
RUN apk add --no-cache openssl curl

# Stage 2: deps (install all deps for build)
FROM base AS deps
COPY package*.json ./
RUN npm ci --frozen-lockfile

# Stage 3: builder
FROM deps AS builder
COPY . .
RUN npm run build
RUN npx prisma generate

# Stage 4: runner (prod deps only)
FROM base AS runner
ENV NODE_ENV=production

COPY package*.json ./
# Copy schema before npm ci so prisma postinstall can generate client
COPY prisma ./prisma
RUN npm ci --frozen-lockfile --omit=dev

# Override with builder-generated Prisma artifacts (ensures exact same client)
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma/client ./node_modules/@prisma/client

COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["/entrypoint.sh"]
