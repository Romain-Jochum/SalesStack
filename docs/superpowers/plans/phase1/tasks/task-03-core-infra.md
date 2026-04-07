# Task 03: Core Infrastructure

**Depends on:** 02.5
**Parallel with:** none
**Blocks:** 04, 13, 14
**Outputs:** `backend/src/core/db.ts`, `core/redis.ts`, `core/logger.ts`, `core/metrics.ts`, `core/queues.ts`, `core/config.ts`
**Verifies:** All infrastructure modules instantiate, environment validation triggers, DB + Redis connection stable
**Estimated context:** ~250 lines

## Intent

Create the six core singleton modules that every other module in the Sales Engine depends on. These provide database access (Prisma), Redis connectivity (ioredis), structured logging (Pino), Prometheus metrics collection (prom-client), BullMQ queue definitions, and startup environment validation. Getting these right and tested early means every subsequent task can import from `core/` with confidence.

## Prerequisites check

- Task 02.5 complete: `sales-db` and `sales-redis` containers running and healthy.
- Task 01 complete: all dependencies installed (`prisma`, `@prisma/client`, `ioredis`, `pino`, `prom-client`, `bullmq`).
- Task 02 complete: Prisma schema exists and migrations applied.
- `backend/.env` has `DATABASE_URL` and `REDIS_URL` set.

## Steps

### Step 3.1: Create `backend/src/core/logger.ts`

Logger must be created first since other modules import it.

```typescript
import pino from 'pino'

export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'debug',
  transport:
    process.env.NODE_ENV !== 'production'
      ? { target: 'pino-pretty', options: { colorize: true } }
      : undefined,
  formatters: {
    level(label: string) {
      return { level: label }
    },
  },
  timestamp: pino.stdTimeFunctions.isoTime,
})
```

### Step 3.2: Create `backend/src/core/db.ts`

Prisma singleton with connection lifecycle logging.

```typescript
import { PrismaClient } from '@prisma/client'
import { logger } from './logger'

export const db = new PrismaClient({
  log: [
    { emit: 'event', level: 'query' },
    { emit: 'event', level: 'error' },
    { emit: 'event', level: 'warn' },
  ],
})

db.$on('query', (e) => {
  logger.debug({ duration: e.duration, query: e.query }, 'prisma query')
})

db.$on('error', (e) => {
  logger.error({ message: e.message }, 'prisma error')
})

db.$on('warn', (e) => {
  logger.warn({ message: e.message }, 'prisma warning')
})

/** Call during graceful shutdown */
export async function disconnectDb(): Promise<void> {
  logger.info('Disconnecting from database')
  await db.$disconnect()
}
```

### Step 3.3: Create `backend/src/core/redis.ts`

ioredis singleton with reconnect strategy and lifecycle helpers.

```typescript
import Redis from 'ioredis'
import { logger } from './logger'

const redisUrl = process.env.REDIS_URL ?? 'redis://localhost:6379'

export const redis = new Redis(redisUrl, {
  maxRetriesPerRequest: null, // Required by BullMQ
  enableReadyCheck: true,
  retryStrategy(times: number) {
    const delay = Math.min(times * 200, 5000)
    logger.warn({ attempt: times, delay }, 'Redis reconnecting')
    return delay
  },
})

redis.on('connect', () => {
  logger.info('Redis connected')
})

redis.on('error', (err) => {
  logger.error({ err }, 'Redis error')
})

/** Call during graceful shutdown */
export async function disconnectRedis(): Promise<void> {
  logger.info('Disconnecting from Redis')
  await redis.quit()
}
```

### Step 3.4: Create `backend/src/core/metrics.ts`

Prometheus metrics registry with default metrics enabled.

```typescript
import client from 'prom-client'

export const register = client.register

// Collect default Node.js metrics (event loop lag, heap, GC, etc.)
client.collectDefaultMetrics({ register })

// HTTP request duration histogram
export const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'] as const,
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
})

// HTTP requests total counter
export const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'] as const,
})

// BullMQ job duration histogram
export const jobDuration = new client.Histogram({
  name: 'bullmq_job_duration_seconds',
  help: 'Duration of BullMQ job processing in seconds',
  labelNames: ['queue', 'job_name', 'status'] as const,
  buckets: [0.1, 0.5, 1, 5, 10, 30, 60, 120],
})

// BullMQ jobs total counter
export const jobsTotal = new client.Counter({
  name: 'bullmq_jobs_total',
  help: 'Total number of BullMQ jobs processed',
  labelNames: ['queue', 'job_name', 'status'] as const,
})
```

### Step 3.5: Create `backend/src/core/queues.ts`

BullMQ queue definitions. Queues are created here; workers consume them in `workers/index.ts` (Task 14).

```typescript
import { Queue } from 'bullmq'
import { redis } from './redis'
import { logger } from './logger'

const defaultOpts = {
  connection: redis,
  defaultJobOptions: {
    attempts: 3,
    backoff: { type: 'exponential' as const, delay: 1000 },
    removeOnComplete: { count: 1000 },
    removeOnFail: { count: 5000 },
  },
}

/** Queue for segment membership recalculation */
export const segmentQueue = new Queue('segment', defaultOpts)

/** Queue for webhook event processing */
export const webhookQueue = new Queue('webhook', defaultOpts)

logger.info(
  { queues: ['segment', 'webhook'] },
  'BullMQ queues initialized'
)

/** Call during graceful shutdown */
export async function closeQueues(): Promise<void> {
  logger.info('Closing BullMQ queues')
  await Promise.all([segmentQueue.close(), webhookQueue.close()])
}
```

### Step 3.6: Create `backend/src/core/config.ts` -- Startup Environment Validation

```typescript
import { logger } from './logger'

/**
 * Validates all required environment variables at startup.
 * Throws immediately if anything is missing or malformed.
 * Must be imported first in server.ts and workers/index.ts
 */
export function validateConfig(): void {
  const required = [
    'DATABASE_URL',
    'REDIS_URL',
  ]

  const optional = [
    'SENTRY_DSN',
    'NODE_ENV',
    'LOG_LEVEL',
    'PORT',
    'HOST',
    'WAHA_WEBHOOK_SECRET',
    'CAL_WEBHOOK_SECRET',
    'EMAIL_PROVIDER_WEBHOOK_SECRET',
  ]

  // Check required vars
  const missing: string[] = []
  for (const key of required) {
    if (!process.env[key]) {
      missing.push(key)
    }
  }

  if (missing.length > 0) {
    logger.error({ missing }, 'Required env vars missing')
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`)
  }

  // Validate DATABASE_URL format
  if (!process.env.DATABASE_URL?.startsWith('postgresql://')) {
    throw new Error('DATABASE_URL must be a valid PostgreSQL connection string')
  }

  // Validate REDIS_URL format
  if (!process.env.REDIS_URL?.startsWith('redis://')) {
    throw new Error('REDIS_URL must be a valid Redis connection string')
  }

  logger.info({ present: required.concat(optional.filter((k) => process.env[k])) }, 'Configuration validated')
}
```

### Step 3.7: Update server.ts and workers/index.ts (in later tasks)

When implementing Task 15 (server.ts) and Task 14 (workers/index.ts), add this import at the very top:

```typescript
import { validateConfig } from './core/config'

// Call immediately before any other initialization
validateConfig()
```

This step is a forward reference -- no action needed now.

### Step 3.8: Commit

```bash
git add backend/src/core/
git commit -m "feat: add core singletons + env validation (db, redis, logger, metrics, queues, config)"
```

## Phase C verification

See `shared/phase-c-template.md` for the general pattern.

Since this task produces infrastructure modules (not API endpoints), Phase C focuses on module instantiation and connectivity:

- [ ] **Config validation throws on missing env vars:** Temporarily unset `DATABASE_URL` and call `validateConfig()` -- confirm it throws `Missing required environment variables: DATABASE_URL`.
- [ ] **Config validation rejects malformed URLs:** Set `DATABASE_URL=not-a-url` and call `validateConfig()` -- confirm it throws about PostgreSQL connection string format.
- [ ] **Config validation passes with correct env:** With proper `.env` values, `validateConfig()` completes without error and logs the present variables.
- [ ] **DB connects:** Import `db` from `core/db.ts` and run `await db.$connect()` -- confirm no connection error and Pino logs `prisma query` events.
- [ ] **Redis connects:** Import `redis` from `core/redis.ts` and run `await redis.ping()` -- confirm it returns `PONG` and Pino logs `Redis connected`.
- [ ] **Logger outputs structured JSON:** Import `logger` and call `logger.info({ test: true }, 'hello')` -- confirm output is structured JSON with `level`, `time`, `test`, and `msg` fields (or pretty-printed in dev mode).
- [ ] **Metrics endpoint registers:** Import `register` from `core/metrics.ts` and call `await register.metrics()` -- confirm it returns Prometheus-formatted text containing `http_request_duration_seconds` and `bullmq_job_duration_seconds`.
- [ ] **Queues instantiate:** Import `segmentQueue` and `webhookQueue` from `core/queues.ts` -- confirm no errors on import and the BullMQ queues initialized log message appears.
- [ ] **Graceful shutdown helpers work:** Call `disconnectDb()`, `disconnectRedis()`, and `closeQueues()` -- confirm each logs its disconnect message and resolves without error.

## Commit

```bash
git add backend/src/core/
git commit -m "feat: add core singletons + env validation (db, redis, logger, metrics, queues, config)"
```
