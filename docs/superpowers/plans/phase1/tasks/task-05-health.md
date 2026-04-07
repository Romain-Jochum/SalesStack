# Task 05: Health Module

**Depends on:** 04
**Parallel with:** 06, 07, 12, 13
**Blocks:** none
**Outputs:** `backend/src/modules/health/routes.ts`, `tests/unit/health/routes.test.ts`
**Verifies:** GET /health returns status+uptime, GET /ready checks DB+Redis connectivity
**Estimated context:** ~150 lines

## Intent

Create the health module as a Fastify plugin providing three unauthenticated endpoints: `/health` (liveness probe returning status and uptime), `/ready` (readiness probe that pings PostgreSQL and Redis), and `/metrics` (Prometheus text format from prom-client). These endpoints are critical for Docker health checks, Kubernetes probes, and monitoring. They require no authentication and are registered outside the auth middleware scope.

## Prerequisites check

- Task 04 (core middleware) is committed: `auth`, `error-handler`, `rate-limit` all export correctly.
- Core singletons from Task 03 are available: `db`, `redis`, `register` (metrics).
- `sales-db` and `sales-redis` containers are running and healthy.

## Steps

### Step 5.1: Write failing test (RED)

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

Create `backend/tests/unit/health/routes.test.ts`:

```typescript
import Fastify from 'fastify'
import healthPlugin from '../../../src/modules/health/routes'

describe('Health routes', () => {
  let app: ReturnType<typeof Fastify>

  beforeEach(async () => {
    app = Fastify()
    await app.register(healthPlugin)
    await app.ready()
  })

  afterEach(() => app.close())

  it('GET /health returns 200 with status ok', async () => {
    const res = await app.inject({ method: 'GET', url: '/health' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ status: 'ok' })
    expect(typeof res.json().uptime).toBe('number')
  })

  it('GET /metrics returns prometheus text format', async () => {
    const res = await app.inject({ method: 'GET', url: '/metrics' })
    expect(res.statusCode).toBe(200)
    expect(res.headers['content-type']).toContain('text/plain')
  })
})
```

### Step 5.2: Run test -- verify it fails for the right reason

```bash
cd backend && npx jest tests/unit/health/ --no-coverage
```

Expected: FAIL -- `Cannot find module '../../../src/modules/health/routes'`

This confirms the test is wired correctly before we write the implementation.

### Step 5.3: Create `backend/src/modules/health/routes.ts` (GREEN)

```typescript
import { FastifyPluginAsync } from 'fastify'
import { register } from '../../core/metrics'
import { db } from '../../core/db'
import { redis } from '../../core/redis'

const healthPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.get('/health', { logLevel: 'silent' }, async (_req, reply) => {
    return reply.send({ status: 'ok', uptime: process.uptime() })
  })

  fastify.get('/ready', { logLevel: 'silent' }, async (_req, reply) => {
    try {
      await db.$queryRaw`SELECT 1`
      await redis.ping()
      return reply.send({ status: 'ready', db: 'ok', redis: 'ok' })
    } catch (err) {
      return reply.code(503).send({ status: 'not ready', error: String(err) })
    }
  })

  fastify.get('/metrics', async (_req, reply) => {
    const metrics = await register.metrics()
    return reply.header('Content-Type', register.contentType).send(metrics)
  })
}

export default healthPlugin
```

### Step 5.4: Run test -- verify it passes

```bash
cd backend && npx jest tests/unit/health/ --no-coverage
```

Expected: PASS (2 tests passing)

### Step 5.5: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` "Health Endpoints" section for curl patterns.

With the dev server running (from Task 04 or via `cd backend && npm run dev:api`), test the health endpoints:

```bash
# Test 1: /health endpoint (no auth required)
curl http://localhost:3000/health
# Expected: {"status":"ok","uptime":...}

# Test 2: /ready endpoint with healthy DB and Redis
curl http://localhost:3000/ready
# Expected: {"status":"ready","db":"ok","redis":"ok"}

# Test 3: /metrics endpoint (Prometheus format)
curl http://localhost:3000/metrics
# Expected: text/plain response with prometheus metrics (HELP, TYPE, metric lines)

# Test 4: Verify metrics have data
curl http://localhost:3000/metrics | grep "process_uptime_seconds"
# Expected: process_uptime_seconds value
```

Specific verifications for this task:

- [ ] GET /health returns 200 with `{"status":"ok","uptime":<number>}`
- [ ] GET /ready returns 200 with `{"status":"ready","db":"ok","redis":"ok"}`
- [ ] GET /ready returns 503 when DB or Redis is down
- [ ] GET /metrics returns 200 with `text/plain` content type
- [ ] GET /metrics output contains `process_uptime_seconds`
- [ ] None of these endpoints require authentication
- [ ] Logs show structured request/response entries (or silent for health/ready)

## Commit

```bash
git add backend/src/modules/health/ tests/unit/health/
git commit -m "feat: add health, ready, and metrics endpoints with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
