# Task 15: Server Entrypoint

**Depends on:** 14
**Parallel with:** none
**Blocks:** 16
**Outputs:** `backend/src/server.ts`
**Verifies:** TypeScript compiles, Fastify boots, all middleware + module plugins register, health check responds
**Estimated context:** ~150 lines

## Intent

Create the Fastify server entrypoint that wires together all core middleware and module plugins into a running application. The `buildApp()` function assembles the full request pipeline: CORS, Helmet, rate limiting, request timing (Prometheus), error handling, public routes (health, webhooks), and authenticated routes (contacts, companies, segments, campaigns, engagements, opportunities, jobs). The `start()` function connects to PostgreSQL and Redis, boots the Fastify server, and installs a SIGTERM handler for graceful shutdown. This is the single file that turns all previously-built modules into a runnable API server.

## Prerequisites check

- Task 14 (jobs module) is committed: all nine module plugins exist and export correctly.
- All core singletons from Task 03 are available: `db`, `redis`, `logger`, `httpRequestDuration`, `connectDb`, `disconnectDb`.
- All core middleware from Task 04 is available: `errorHandler`, `authPlugin`, `rateLimitPlugin`.
- All module plugins from Tasks 05-14 are importable: health, contacts, companies, segments, campaigns, engagements, webhooks, opportunities, jobs.
- `sales-db` and `sales-redis` containers are running and healthy.

## Steps

### Step 15.1: Create `backend/src/server.ts`

```typescript
import Fastify, { FastifyInstance } from 'fastify'
import cors from '@fastify/cors'
import helmet from '@fastify/helmet'
import * as Sentry from '@sentry/node'
import { logger } from './core/logger'
import { errorHandler } from './core/middleware/error-handler'
import authPlugin from './core/middleware/auth'
import rateLimitPlugin from './core/middleware/rate-limit'
import { httpRequestDuration } from './core/metrics'
import { connectDb, disconnectDb } from './core/db'
import { redis } from './core/redis'

// Module plugins
import healthPlugin from './modules/health/routes'
import contactsPlugin from './modules/contacts/routes'
import companiesPlugin from './modules/companies/routes'
import segmentsPlugin from './modules/segments/routes'
import campaignsPlugin from './modules/campaigns/routes'
import engagementsPlugin from './modules/engagements/routes'
import webhooksPlugin from './modules/webhooks/routes'
import opportunitiesPlugin from './modules/opportunities/routes'
import jobsPlugin from './modules/jobs/routes'

export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    logger: false, // we use Pino directly
    disableRequestLogging: true,
    trustProxy: true,
  })

  // Sentry
  if (process.env.SENTRY_DSN) {
    Sentry.init({ dsn: process.env.SENTRY_DSN, environment: process.env.NODE_ENV })
  }

  // Global plugins
  await app.register(cors, { origin: process.env.CORS_ORIGIN ?? false })
  await app.register(helmet)
  await app.register(rateLimitPlugin)

  // Request timing for Prometheus
  app.addHook('onRequest', async (request) => {
    ;(request as unknown as { _startTime: number })._startTime = Date.now()
  })
  app.addHook('onResponse', async (request, reply) => {
    const duration = (Date.now() - (request as unknown as { _startTime: number })._startTime) / 1000
    const route = request.routeOptions?.url ?? request.url
    httpRequestDuration.observe(
      { method: request.method, route, status_code: reply.statusCode },
      duration,
    )
    logger.info({ method: request.method, url: request.url, status: reply.statusCode, duration }, 'request')
  })

  // Error handler
  app.setErrorHandler(errorHandler)

  // Public routes (no auth)
  await app.register(healthPlugin)
  await app.register(webhooksPlugin) // webhooks verify their own HMAC signatures

  // Authenticated routes
  const authenticated = async (app: FastifyInstance) => {
    await app.register(authPlugin)
    await app.register(contactsPlugin)
    await app.register(companiesPlugin)
    await app.register(segmentsPlugin)
    await app.register(campaignsPlugin)
    await app.register(engagementsPlugin)
    await app.register(opportunitiesPlugin)
    await app.register(jobsPlugin)
  }
  await app.register(authenticated)

  return app
}

async function start(): Promise<void> {
  await redis.connect()
  await connectDb()

  const app = await buildApp()
  const port = Number(process.env.PORT ?? 3000)
  const host = process.env.HOST ?? '0.0.0.0'

  await app.listen({ port, host })
  logger.info({ port, host }, 'Sales Engine API started')

  process.on('SIGTERM', async () => {
    logger.info('SIGTERM: shutting down API')
    await app.close()
    await disconnectDb()
    await redis.quit()
    process.exit(0)
  })
}

start().catch((err) => {
  logger.error({ err }, 'Fatal: failed to start server')
  process.exit(1)
})
```

### Step 15.2: Verify TypeScript compiles

```bash
cd backend && npm run typecheck
```

Expected: no errors. If there are type errors, fix them before proceeding.

### Step 15.3: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern.

With the dev server running (`cd backend && npm run dev:api`), verify the full application boots and responds:

```bash
# Test 1: Server boots without errors
# Check terminal output for "Sales Engine API started" with no connection errors

# Test 2: Health endpoint responds (proves all plugins registered)
curl http://localhost:3000/health
# Expected: {"status":"ok","uptime":...}

# Test 3: Ready endpoint confirms DB + Redis connectivity
curl http://localhost:3000/ready
# Expected: {"status":"ready","db":"ok","redis":"ok"}

# Test 4: Authenticated route rejects without auth (proves auth middleware registered)
curl http://localhost:3000/api/contacts
# Expected: 401 {"error":{"code":"UNAUTHORIZED","message":"..."}}

# Test 5: Metrics endpoint (proves Prometheus timing hooks work)
curl http://localhost:3000/metrics
# Expected: text/plain with prometheus metrics including http_request_duration_seconds

# Test 6: Graceful shutdown
# Send SIGTERM to dev server process, verify clean shutdown in logs
# Expected: "SIGTERM: shutting down API" log line, process exits cleanly
```

Specific verifications for this task:

- [ ] Server starts with `Sales Engine API started` log and no errors
- [ ] GET /health returns 200 with `{"status":"ok","uptime":<number>}`
- [ ] GET /ready returns 200 with `{"status":"ready","db":"ok","redis":"ok"}`
- [ ] GET /api/contacts without auth returns 401 (auth middleware active)
- [ ] GET /metrics returns 200 with `text/plain` and includes `http_request_duration_seconds`
- [ ] Request timing hooks produce log lines with method, url, status, duration
- [ ] SIGTERM triggers graceful shutdown (DB disconnect, Redis quit, clean exit)

## Commit

```bash
git add backend/src/server.ts
git commit -m "feat: add Fastify server entrypoint wiring all module plugins"
```

See `shared/commit-conventions.md` for formatting rules.
