# Task 04: Core Middleware

**Depends on:** 03
**Parallel with:** none
**Blocks:** 05, 06, 07, 12
**Outputs:** `backend/src/core/middleware/auth.ts`, `core/middleware/error-handler.ts`, `core/middleware/rate-limit.ts`, `tests/unit/middleware/auth.test.ts`
**Verifies:** Auth rejects invalid keys, rate limit blocks excess, error handler returns standard JSON shape, valid keys pass
**Estimated context:** ~240 lines

## Intent

Create the three core middleware components that every downstream route depends on: API key authentication (SHA-256 hashed, looked up in `api_keys` table), a global error handler that normalizes all errors into the standard `{error: {code, message, details?}}` JSON shape, and Redis-backed rate limiting (500 req/min per key prefix or IP). These middlewares are registered as Fastify plugins/hooks and will be wired into the server entrypoint in Task 15.

## Prerequisites check

- Task 03 (core singletons) is committed: `db`, `redis`, `logger`, `config` all export correctly.
- `sales-db` and `sales-redis` containers are running and healthy.
- The `ApiKey` model exists in the Prisma schema (from Task 02) with fields: `id`, `name`, `keyHash`, `keyPrefix`, `scopes`, `tenantId`, `revokedAt`, `expiresAt`, `lastUsedAt`.

## Steps

### Step 4.1: Write failing test for auth middleware (RED)

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

Create `tests/unit/middleware/auth.test.ts`:

```typescript
import { hashApiKey, extractKeyPrefix } from '../../../src/core/middleware/auth'

describe('API key hashing', () => {
  it('produces consistent SHA-256 hashes', () => {
    const key = 'sk_live_abcd1234efgh5678'
    const hash1 = hashApiKey(key)
    const hash2 = hashApiKey(key)
    expect(hash1).toBe(hash2)
    expect(hash1).toHaveLength(64) // SHA-256 hex
  })

  it('extracts 8-char prefix', () => {
    const key = 'sk_live_abcd1234efgh5678'
    expect(extractKeyPrefix(key)).toBe('sk_live_')
  })

  it('different keys produce different hashes', () => {
    expect(hashApiKey('key1')).not.toBe(hashApiKey('key2'))
  })
})
```

### Step 4.2: Run test -- verify it fails for the right reason

```bash
cd backend && npx jest tests/unit/middleware/auth.test.ts --no-coverage
```

Expected: FAIL -- `Cannot find module '../../../src/core/middleware/auth'`

### Step 4.3: Create `backend/src/core/middleware/auth.ts` (GREEN)

```typescript
import { FastifyPluginAsync, FastifyRequest, FastifyReply } from 'fastify'
import { createHash } from 'crypto'
import { db } from '../db'
import { logger } from '../logger'

export function hashApiKey(rawKey: string): string {
  return createHash('sha256').update(rawKey).digest('hex')
}

export function extractKeyPrefix(rawKey: string): string {
  return rawKey.substring(0, 8)
}

async function verifyApiKey(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const authHeader = request.headers.authorization
  if (!authHeader?.startsWith('Bearer ')) {
    return reply.code(401).send({ error: { code: 'UNAUTHORIZED', message: 'Missing API key' } })
  }

  const rawKey = authHeader.slice(7)
  const prefix = extractKeyPrefix(rawKey)
  const keyHash = hashApiKey(rawKey)

  const apiKey = await db.apiKey.findFirst({
    where: {
      keyPrefix: prefix,
      keyHash,
      revokedAt: null,
      OR: [{ expiresAt: null }, { expiresAt: { gt: new Date() } }],
    },
  })

  if (!apiKey) {
    logger.warn({ prefix }, 'Invalid API key attempt')
    return reply.code(401).send({ error: { code: 'UNAUTHORIZED', message: 'Invalid API key' } })
  }

  // Update lastUsedAt async — don't await, don't block the request
  db.apiKey.update({
    where: { id: apiKey.id },
    data: { lastUsedAt: new Date() },
  }).catch((err) => logger.error({ err }, 'Failed to update lastUsedAt'))

  // Attach to request for downstream use
  ;(request as FastifyRequest & { tenantId: string | null; apiKeyId: string; scopes: string[] }).tenantId = apiKey.tenantId
  ;(request as FastifyRequest & { tenantId: string | null; apiKeyId: string; scopes: string[] }).apiKeyId = apiKey.id
  ;(request as FastifyRequest & { tenantId: string | null; apiKeyId: string; scopes: string[] }).scopes = apiKey.scopes
}

export const authPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.addHook('onRequest', verifyApiKey)
}

export default authPlugin
```

### Step 4.4: Run test -- verify it passes

```bash
cd backend && npx jest tests/unit/middleware/auth.test.ts --no-coverage
```

Expected: PASS (3 tests passing)

### Step 4.5: Create `backend/src/core/middleware/error-handler.ts`

> See `shared/error-contract.md` for the full error response shape, error codes table, and throw-and-catch patterns.

```typescript
import { FastifyError, FastifyReply, FastifyRequest } from 'fastify'
import * as Sentry from '@sentry/node'
import { logger } from '../logger'

export function errorHandler(
  error: FastifyError,
  request: FastifyRequest,
  reply: FastifyReply,
): void {
  // Don't report 4xx errors to Sentry
  if (!error.statusCode || error.statusCode >= 500) {
    Sentry.captureException(error, {
      extra: { url: request.url, method: request.method },
    })
    logger.error({ err: error, url: request.url }, 'Unhandled server error')
  }

  const statusCode = error.statusCode ?? 500

  if (error.validation) {
    return void reply.code(400).send({
      error: {
        code: 'VALIDATION_ERROR',
        message: 'Request validation failed',
        details: error.validation,
      },
    })
  }

  reply.code(statusCode).send({
    error: {
      code: error.code ?? 'INTERNAL_ERROR',
      message: statusCode === 500 ? 'Internal server error' : error.message,
    },
  })
}
```

### Step 4.6: Create `backend/src/core/middleware/rate-limit.ts`

```typescript
import { FastifyPluginAsync } from 'fastify'
import rateLimit from '@fastify/rate-limit'
import { redis } from '../redis'

export const rateLimitPlugin: FastifyPluginAsync = async (fastify) => {
  await fastify.register(rateLimit, {
    global: true,
    max: 500,
    timeWindow: '1 minute',
    redis,
    keyGenerator: (request) => {
      // Rate limit by API key prefix if available, otherwise by IP
      const auth = request.headers.authorization
      return auth?.startsWith('Bearer ') ? auth.slice(7, 15) : request.ip
    },
    errorResponseBuilder: (_request, context) => ({
      error: {
        code: 'RATE_LIMITED',
        message: `Rate limit exceeded. Try again in ${context.after}`,
      },
    }),
  })
}

export default rateLimitPlugin
```

### Step 4.7: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` "Auth" and "Error Testing" sections for curl patterns.

Specific verifications for this task:

Boot the server with valid database + Redis running, then test:

```bash
# In one terminal, start the stack:
docker compose up -d sales-db sales-redis

# Wait for health checks (30-60 sec)

# In another terminal, build and start API:
cd backend && npm run build && ROLE=api npm start
```

Expected: Server boots, logs "Sales Engine API started", no connection errors.

Then verify middleware is working:

```bash
# Test 1: Request without API key (should fail)
curl -X GET http://localhost:3000/health
# Expected: 200 OK (health endpoint has no auth)

# Test 2: Create API key in database
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "INSERT INTO api_keys (id, name, key_hash, key_prefix, scopes) \
   VALUES (gen_random_uuid(), 'test-key', \
   '$(echo -n \"sk_live_test1234567890\" | openssl dgst -sha256 -hex | awk \"{print \\\$2}\")', \
   'sk_live_', '{contacts:read}')"

# Test 3: Request with invalid API key (should fail)
curl -X GET http://localhost:3000/api/contacts \
  -H "Authorization: Bearer sk_live_invalid"
# Expected: 401 Unauthorized

# Test 4: Request with valid API key (should work with "no matching user" error initially, but auth passed)
curl -X GET http://localhost:3000/api/contacts \
  -H "Authorization: Bearer sk_live_test1234567890"
# Expected: 200 or 403 (auth middleware passed, route handler responds)

# Test 5: Rate limiting (exceed 500 reqs/min)
for i in {1..510}; do curl -s -H "Authorization: Bearer sk_live_test1234567890" http://localhost:3000/health; done | grep "RATE_LIMITED" | head -1
# Expected: At least one response with "RATE_LIMITED" code
```

## Phase C verification

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` "Auth" and "Error Testing" sections for curl patterns.

Specific verifications for this task:
- Request without Authorization header on authenticated route -> 401 `{error: {code: "UNAUTHORIZED"}}`
- Request with invalid API key -> 401
- Request with valid API key -> passes through to route handler
- Rate limit: send 501+ requests in 1 minute -> 429
- Malformed JSON body -> 400 with standard error shape
- Unhandled route -> 404

## Commit

```bash
git add backend/src/core/middleware/ tests/unit/middleware/
git commit -m "feat: add auth, error-handler, rate-limit middleware with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
