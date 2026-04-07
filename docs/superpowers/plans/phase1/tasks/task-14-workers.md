# Task 14: Workers Registration

**Depends on:** 03, 08, 11
**Parallel with:** none
**Blocks:** 15
**Outputs:** `backend/src/workers/index.ts`
**Verifies:** Webhook + segment workers instantiate, graceful shutdown works, error logging to Sentry
**Estimated context:** ~120 lines

## Intent

Create the unified workers entrypoint that bootstraps all BullMQ workers for the sales engine. This file connects to the database and Redis, instantiates the webhook and segment workers created in earlier tasks, wires up lifecycle event logging (completed/failed), initializes Sentry for error tracking, and registers a graceful shutdown handler (SIGTERM). The worker process runs as a separate container role (`ROLE=worker`) using the same Docker image as the API.

## Prerequisites check

- Task 03 (core infra) is committed and working -- `core/db.ts`, `core/redis.ts`, `core/logger.ts`, and `core/queues.ts` all exist.
- The `createWebhookWorker` function exists in `modules/webhooks/webhook.worker.ts`.
- The `createSegmentWorker` function exists in `modules/segments/segment.worker.ts`.
- `sales-db` and `sales-redis` containers are running and healthy.

## Steps

### Step 14.1: Create `backend/src/workers/index.ts`

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

```typescript
import { createSegmentWorker } from '../modules/segments/segment.worker'
import { createWebhookWorker } from '../modules/webhooks/webhook.worker'
import { Worker } from 'bullmq'
import { logger } from '../core/logger'
import * as Sentry from '@sentry/node'
import { redis } from '../core/redis'
import { db } from '../core/db'

// Phase 1 workers
const workers: Worker[] = []

async function startWorkers(): Promise<void> {
  if (process.env.SENTRY_DSN) {
    Sentry.init({ dsn: process.env.SENTRY_DSN, environment: process.env.NODE_ENV })
  }

  await redis.connect()
  await db.$connect()
  logger.info('Workers: DB + Redis connected')

  workers.push(
    createWebhookWorker(),  // queue:engagement:process
    createSegmentWorker(),  // queue:segment:evaluate
  )

  for (const worker of workers) {
    worker.on('completed', (job) => {
      logger.debug({ jobId: job.id, queue: worker.name }, 'Job completed')
    })
    worker.on('failed', (job, err) => {
      logger.error({ jobId: job?.id, queue: worker.name, err }, 'Job failed')
      Sentry.captureException(err, { extra: { jobId: job?.id, queue: worker.name } })
    })
  }

  logger.info({ workerCount: workers.length }, 'All workers started')

  // Graceful shutdown
  process.on('SIGTERM', async () => {
    logger.info('SIGTERM: closing workers')
    await Promise.all(workers.map((w) => w.close()))
    await db.$disconnect()
    await redis.quit()
    process.exit(0)
  })
}

startWorkers().catch((err) => {
  logger.error({ err }, 'Fatal: failed to start workers')
  process.exit(1)
})
```

### Step 14.2: Verify workers start cleanly

```bash
cd backend && npx tsx src/workers/index.ts
```

Expected: logs showing "Workers: DB + Redis connected" and "All workers started" with `workerCount: 2`. No crash, no unhandled errors.

## Phase C verification

See `shared/phase-c-template.md` for the general pattern.

Specific verifications for this task:
- Worker process starts without errors when `ROLE=worker`
- Both webhook and segment workers are registered (workerCount: 2 in logs)
- DB and Redis connections are established before workers start
- Sentry initializes when `SENTRY_DSN` is set (check logs, no crash if unset)
- SIGTERM triggers graceful shutdown: workers close, DB disconnects, Redis quits
- Failed jobs log errors with jobId and queue name
- Completed jobs log debug with jobId and queue name
- Worker process exits cleanly on SIGTERM (exit code 0)
- Worker process exits with code 1 if startup fails (e.g., DB unreachable)

## Commit

```bash
git add backend/src/workers/
git commit -m "feat: add workers entry (webhook + segment workers)"
```

See `shared/commit-conventions.md` for formatting rules.
