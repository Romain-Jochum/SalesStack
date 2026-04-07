# Error Handling Contract

> All API errors follow a single response shape and use typed error codes.
> This contract is enforced by the Fastify error handler in
> `backend/src/core/middleware/error-handler.ts`.

## Error Response Shape

Every error response (4xx and 5xx) uses this JSON structure:

```json
{
  "error": {
    "code": "NOT_FOUND",
    "message": "Contact not found",
    "details": {}
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `error.code` | `string` | Yes | Machine-readable error code (see table below) |
| `error.message` | `string` | Yes | Human-readable description |
| `error.details` | `object` | No | Additional context (validation errors, field names) |

## Error Codes

| Code | HTTP Status | When |
|------|-------------|------|
| `VALIDATION_ERROR` | 400 | Schema validation fails (missing required fields, wrong types, format violations) |
| `UNAUTHORIZED` | 401 | Missing `Authorization` header, invalid Bearer token, expired API key |
| `INVALID_SIGNATURE` | 401 | Webhook HMAC signature verification fails |
| `FORBIDDEN` | 403 | Valid API key but insufficient scopes for the requested operation |
| `NOT_FOUND` | 404 | Resource does not exist, has been soft-deleted, or job ID not found |
| `CONFLICT` | 409 | Duplicate unique constraint (e.g., contact already enrolled in campaign, duplicate email within tenant) |
| `RATE_LIMITED` | 429 | Exceeded 500 requests per minute per IP or API key prefix |
| `INTERNAL_ERROR` | 500 | Unexpected server error (details hidden from client) |

## Error Handler Implementation

The error handler in `core/middleware/error-handler.ts` catches all errors and
formats them into the standard shape:

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

  // Fastify validation errors get special handling
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

Key behaviors:

- **Validation errors** (from Fastify/TypeBox schema validation) are caught
  automatically. The `error.validation` array is passed through as `details`.
- **5xx errors** are reported to Sentry and logged with full stack traces.
  The client receives a generic "Internal server error" message (no leak of
  internals).
- **4xx errors** are NOT reported to Sentry. The client receives the actual
  error message.
- The `error.code` field on the Fastify error is passed through directly. If
  absent, it defaults to `INTERNAL_ERROR`.

## Throw-and-Catch Pattern

Services throw typed errors. Route handlers catch and convert them to HTTP
responses. There are two patterns used across the codebase:

### Pattern 1: Return null for not-found (preferred for CRUD)

Service functions return `null` when a resource is not found. The route handler
checks and sends 404:

```typescript
// service.ts
export async function getContact(db: PrismaClient, id: string): Promise<Contact | null> {
  return db.contact.findFirst({ where: { id, deletedAt: null } })
}

// routes.ts
fastify.get('/api/contacts/:id', async (request, reply) => {
  const { id } = request.params as { id: string }
  const contact = await getContact(db, id)
  if (!contact) {
    return reply.code(404).send({
      error: { code: 'NOT_FOUND', message: 'Contact not found' },
    })
  }
  return reply.send({ data: contact })
})
```

### Pattern 2: Throw error for business logic violations

Service functions throw an `Error` with a code prefix. The route handler
catches and maps to the correct HTTP status:

```typescript
// service.ts
export async function enrollContact(
  db: PrismaClient,
  campaignId: string,
  contactId: string,
): Promise<CampaignEnrollment> {
  const campaign = await db.campaign.findFirst({ where: { id: campaignId, deletedAt: null } })
  if (!campaign) throw new Error('NOT_FOUND: Campaign not found')

  const existing = await db.campaignEnrollment.findFirst({ where: { campaignId, contactId } })
  if (existing) throw new Error('CONFLICT: Contact already enrolled in this campaign')

  return db.campaignEnrollment.create({
    data: { campaignId, contactId, stage: 'enrolled' },
  })
}

// routes.ts
fastify.post('/api/campaigns/:id/enroll', async (request, reply) => {
  try {
    const enrollment = await enrollContact(db, id, contactId)
    return reply.code(201).send({ data: enrollment })
  } catch (err) {
    const msg = String(err)
    if (msg.includes('NOT_FOUND')) {
      return reply.code(404).send({
        error: { code: 'NOT_FOUND', message: 'Campaign not found' },
      })
    }
    if (msg.includes('CONFLICT')) {
      return reply.code(409).send({
        error: { code: 'CONFLICT', message: 'Contact already enrolled' },
      })
    }
    throw err  // re-throw unknown errors for the global handler
  }
})
```

## Auth Middleware Errors

The auth middleware in `core/middleware/auth.ts` sends 401 directly without
throwing, since it runs as a Fastify `onRequest` hook:

```typescript
// Missing or malformed Authorization header
return reply.code(401).send({
  error: { code: 'UNAUTHORIZED', message: 'Missing API key' },
})

// Valid format but key not found in database
return reply.code(401).send({
  error: { code: 'UNAUTHORIZED', message: 'Invalid API key' },
})
```

## Webhook Signature Errors

Webhook routes verify HMAC signatures before processing. Invalid signatures
return 401 with a specific code:

```typescript
return reply.code(401).send({
  error: { code: 'INVALID_SIGNATURE', message: 'Invalid signature' },
})
```

## Rate Limiting Errors

The rate limiter (via `@fastify/rate-limit`) uses a custom error response
builder:

```typescript
errorResponseBuilder: (_request, context) => ({
  error: {
    code: 'RATE_LIMITED',
    message: `Rate limit exceeded. Try again in ${context.after}`,
  },
})
```

## Sentry Integration

- 5xx errors: captured to Sentry with request URL and method as extra context
- 4xx errors: NOT captured (expected client errors)
- Worker failures: captured in the worker error handler with job ID and queue
  name as extra context
