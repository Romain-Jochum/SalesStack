# Task 11: Webhooks Module

**Depends on:** 10
**Parallel with:** none
**Blocks:** 14
**Outputs:** `backend/src/modules/webhooks/verifiers.ts`, `webhooks/routes.ts`, `webhooks/webhook.worker.ts`, `tests/unit/webhooks/verifiers.test.ts`
**Verifies:** Cal webhook verified by HMAC, WAHA verified, email verified, all enqueue to worker, jobs trackable via pointer pattern
**Estimated context:** ~450 lines

## Intent

Create the webhooks module that receives inbound webhook events from external providers (Cal.com for bookings, WAHA for WhatsApp delivery/read receipts, Postmark/Mailgun for email events) and processes them into engagement events. Each webhook endpoint verifies the provider's HMAC signature using timing-safe comparison, stores the raw event idempotently (upsert on provider + providerEventId), and enqueues a BullMQ job carrying only a pointer (webhookEventId) -- never the raw payload. The webhook worker then resolves the pointer, matches the event to a contact, and delegates to the engagements service for score tracking. This module is the bridge between external systems and the engagement scoring pipeline.

## Prerequisites check

- Task 10 (engagements module) is committed and working.
- `sales-db` and `sales-redis` containers are running and healthy.
- The `WebhookEvent` model exists in the Prisma schema (from Task 02) with fields: `id`, `provider`, `providerEventId`, `payload`, `status`, `processedAt`, `error`, `createdAt`.
- The `WebhookEvent` model has a unique constraint on `(provider, providerEventId)` for idempotent upserts.
- The `engagementQueue` is defined in `core/queues.ts` (from Task 03) with queue name `ENGAGEMENT_PROCESS`.
- The `webhookProcessingDuration` histogram is defined in `core/metrics.ts` (from Task 03).
- The `logEngagement` function is available from `modules/engagements/service.ts` (from Task 10).
- Environment variables `WAHA_WEBHOOK_SECRET`, `CAL_WEBHOOK_SECRET` are defined (optional, verification skipped if empty).

## Steps

### Step 11.1: Write failing verifier tests

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

Create `tests/unit/webhooks/verifiers.test.ts`:

```typescript
import { createHmac } from 'crypto'
import { verifyWahaSignature, verifyCalSignature, verifyPostmarkSignature } from '../../../src/modules/webhooks/verifiers'

describe('verifyWahaSignature', () => {
  const secret = 'test-waha-secret'
  const body = JSON.stringify({ event: 'message', data: { id: '123' } })

  it('returns true for valid HMAC-SHA512 signature', () => {
    const signature = createHmac('sha512', secret).update(body).digest('hex')
    expect(verifyWahaSignature(body, signature, secret)).toBe(true)
  })

  it('returns false for invalid signature', () => {
    expect(verifyWahaSignature(body, 'invalid-sig', secret)).toBe(false)
  })

  it('returns false for empty signature', () => {
    expect(verifyWahaSignature(body, '', secret)).toBe(false)
  })
})

describe('verifyCalSignature', () => {
  const secret = 'test-cal-secret'
  const body = JSON.stringify({ triggerEvent: 'BOOKING_CREATED', payload: {} })

  it('returns true for valid HMAC-SHA256 signature', () => {
    const signature = createHmac('sha256', secret).update(body).digest('hex')
    expect(verifyCalSignature(body, signature, secret)).toBe(true)
  })

  it('returns false for invalid signature', () => {
    expect(verifyCalSignature(body, 'bad-sig', secret)).toBe(false)
  })
})
```

### Step 11.2: Run test -- should fail

```bash
cd backend && npx jest tests/unit/webhooks/verifiers.test.ts --no-coverage
```

Expected: FAIL (cannot resolve `verifiers` module).

### Step 11.3: Create `backend/src/modules/webhooks/verifiers.ts`

```typescript
import { createHmac, timingSafeEqual } from 'crypto'

function safeCompare(a: string, b: string): boolean {
  if (!a || !b) return false
  try {
    return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'))
  } catch {
    return false
  }
}

export function verifyWahaSignature(
  rawBody: string,
  receivedSignature: string,
  secret: string,
): boolean {
  const expected = createHmac('sha512', secret).update(rawBody).digest('hex')
  return safeCompare(expected, receivedSignature)
}

export function verifyCalSignature(
  rawBody: string,
  receivedSignature: string,
  secret: string,
): boolean {
  const expected = createHmac('sha256', secret).update(rawBody).digest('hex')
  return safeCompare(expected, receivedSignature)
}

export function verifyPostmarkSignature(
  rawBody: string,
  receivedSignature: string,
  secret: string,
): boolean {
  // Postmark uses base64-encoded HMAC-SHA256
  const expected = createHmac('sha256', secret).update(rawBody).digest('base64')
  try {
    return timingSafeEqual(Buffer.from(expected, 'base64'), Buffer.from(receivedSignature, 'base64'))
  } catch {
    return false
  }
}

export function verifyMailgunSignature(
  timestamp: string,
  token: string,
  signature: string,
  secret: string,
): boolean {
  const expected = createHmac('sha256', secret).update(timestamp + token).digest('hex')
  return safeCompare(expected, signature)
}
```

### Step 11.4: Run test -- should pass

```bash
cd backend && npx jest tests/unit/webhooks/verifiers.test.ts --no-coverage
```

Expected: PASS (5 tests passing).

### Step 11.5: Create `backend/src/modules/webhooks/webhook.worker.ts`

```typescript
import { Worker, Job } from 'bullmq'
import { redis } from '../../core/redis'
import { db } from '../../core/db'
import { QUEUE_NAMES } from '../../core/queues'
import { logEngagement } from '../engagements/service'
import { EngagementEventType } from '@prisma/client'
import { logger } from '../../core/logger'

// Maps Cal.com trigger events to our EngagementEventType
const CAL_EVENT_MAP: Record<string, EngagementEventType> = {
  BOOKING_CREATED: EngagementEventType.BOOKING_CREATED,
  BOOKING_CANCELLED: EngagementEventType.BOOKING_CANCELLED,
}

// Maps WAHA ack values to our EngagementEventType
function wahaAckToEventType(ack: number): EngagementEventType | null {
  switch (ack) {
    case 3: return EngagementEventType.WHATSAPP_DELIVERED
    case 4: return EngagementEventType.WHATSAPP_READ
    default: return null
  }
}

export function createWebhookWorker(): Worker {
  return new Worker(
    QUEUE_NAMES.ENGAGEMENT_PROCESS,
    async (job: Job) => {
      const { webhookEventId } = job.data as { webhookEventId: string }

      const webhookEvent = await db.webhookEvent.findUnique({ where: { id: webhookEventId } })
      if (!webhookEvent) {
        logger.warn({ webhookEventId }, 'WebhookEvent not found — skipping')
        return
      }

      await db.webhookEvent.update({
        where: { id: webhookEventId },
        data: { status: 'PROCESSING' },
      })

      try {
        const payload = webhookEvent.payload as Record<string, unknown>

        if (webhookEvent.provider === 'waha') {
          await processWahaEvent(payload)
        } else if (webhookEvent.provider === 'cal') {
          await processCalEvent(payload)
        } else if (webhookEvent.provider === 'postmark' || webhookEvent.provider === 'mailgun') {
          await processEmailEvent(payload, webhookEvent.provider)
        }

        await db.webhookEvent.update({
          where: { id: webhookEventId },
          data: { status: 'PROCESSED', processedAt: new Date() },
        })
      } catch (err) {
        await db.webhookEvent.update({
          where: { id: webhookEventId },
          data: { status: 'FAILED', error: String(err) },
        })
        throw err
      }
    },
    { connection: redis, concurrency: 5 },
  )
}

async function processWahaEvent(payload: Record<string, unknown>): Promise<void> {
  const event = payload.event as string
  const chatId = (payload as Record<string, Record<string, unknown>>).from?.id as string | undefined
  if (!chatId) return

  const phone = chatId.replace('@c.us', '')
  const contact = await db.contact.findFirst({ where: { phone, deletedAt: null } })
  if (!contact) {
    logger.info({ phone }, 'No contact found for WAHA event — skipping')
    return
  }

  if (event === 'message') {
    await logEngagement(db, {
      contactId: contact.id,
      eventType: 'WHATSAPP_REPLIED',
      channel: 'whatsapp',
      sourceProvider: 'waha',
      metadata: { chatId, messageId: (payload as Record<string, unknown>).id },
    })
  } else if (event === 'message.ack') {
    const ack = (payload as Record<string, unknown>).ack as number
    const eventType = wahaAckToEventType(ack)
    if (eventType) {
      await logEngagement(db, { contactId: contact.id, eventType, channel: 'whatsapp', sourceProvider: 'waha', metadata: { ack } })
    }
  }
}

async function processCalEvent(payload: Record<string, unknown>): Promise<void> {
  const triggerEvent = payload.triggerEvent as string
  const eventType = CAL_EVENT_MAP[triggerEvent]
  if (!eventType) return

  const bookingPayload = payload.payload as Record<string, unknown>
  const attendeeEmail = (bookingPayload?.attendees as Record<string, string>[])?.[0]?.email
  if (!attendeeEmail) return

  const contact = await db.contact.findFirst({ where: { email: attendeeEmail, deletedAt: null } })
  if (!contact) {
    logger.info({ attendeeEmail }, 'No contact found for Cal.com event — skipping')
    return
  }

  await logEngagement(db, {
    contactId: contact.id,
    eventType,
    channel: 'email',
    sourceProvider: 'cal',
    metadata: { bookingId: bookingPayload?.uid, attendeeEmail },
  })
}

async function processEmailEvent(payload: Record<string, unknown>, provider: string): Promise<void> {
  const email = (payload.Recipient ?? payload.recipient ?? payload.email) as string
  if (!email) return

  const contact = await db.contact.findFirst({ where: { email, deletedAt: null } })
  if (!contact) return

  const recordType = (payload.RecordType ?? payload.event) as string
  const eventTypeMap: Record<string, EngagementEventType> = {
    Open: EngagementEventType.EMAIL_OPENED,
    Click: EngagementEventType.EMAIL_CLICKED,
    Bounce: EngagementEventType.EMAIL_BOUNCED,
    SpamComplaint: EngagementEventType.EMAIL_SPAM,
    Unsubscribe: EngagementEventType.EMAIL_UNSUBSCRIBED,
    Delivery: EngagementEventType.EMAIL_DELIVERED,
  }

  const eventType = eventTypeMap[recordType]
  if (!eventType) return

  await logEngagement(db, {
    contactId: contact.id,
    eventType,
    channel: 'email',
    sourceProvider: provider,
    metadata: { messageId: payload.MessageID ?? payload['message-id'], recordType },
  })
}
```

### Step 11.6: Create `backend/src/modules/webhooks/routes.ts`

```typescript
import { FastifyPluginAsync } from 'fastify'
import { verifyWahaSignature, verifyCalSignature, verifyPostmarkSignature, verifyMailgunSignature } from './verifiers'
import { engagementQueue, QUEUE_NAMES } from '../../core/queues'
import { db } from '../../core/db'
import { logger } from '../../core/logger'
import { webhookProcessingDuration } from '../../core/metrics'

function extractProviderEventId(provider: string, payload: Record<string, unknown>): string {
  switch (provider) {
    case 'waha': return String(payload.id ?? `${payload.event}-${Date.now()}`)
    case 'cal': return String((payload.payload as Record<string, unknown>)?.uid ?? Date.now())
    case 'postmark': return String(payload.MessageID ?? Date.now())
    case 'mailgun': return String(payload['message-id'] ?? Date.now())
    default: return String(Date.now())
  }
}

async function ingestWebhook(
  provider: string,
  providerEventId: string,
  payload: Record<string, unknown>,
): Promise<string> {
  const webhookEvent = await db.webhookEvent.upsert({
    where: { provider_providerEventId: { provider, providerEventId } },
    create: { provider, providerEventId, payload, status: 'RECEIVED' },
    update: {}, // idempotent: if already exists, do nothing
  })

  await engagementQueue.add(
    'process-webhook',
    { webhookEventId: webhookEvent.id }, // pointer only, never raw payload
    { jobId: `webhook:${webhookEvent.id}`, deduplication: { id: `webhook:${webhookEvent.id}` } },
  )

  return webhookEvent.id
}

const webhooksPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.post('/api/webhooks/waha', async (request, reply) => {
    const end = webhookProcessingDuration.startTimer({ provider: 'waha' })
    const rawBody = JSON.stringify(request.body)
    const signature = request.headers['x-webhook-hmac'] as string
    const secret = process.env.WAHA_WEBHOOK_SECRET ?? ''

    if (secret && !verifyWahaSignature(rawBody, signature, secret)) {
      end()
      logger.warn('Invalid WAHA signature')
      return reply.code(401).send({ error: { code: 'INVALID_SIGNATURE', message: 'Invalid signature' } })
    }

    const payload = request.body as Record<string, unknown>
    const providerEventId = extractProviderEventId('waha', payload)
    await ingestWebhook('waha', providerEventId, payload)
    end()
    return reply.code(200).send({ received: true })
  })

  fastify.post('/api/webhooks/cal', async (request, reply) => {
    const end = webhookProcessingDuration.startTimer({ provider: 'cal' })
    const rawBody = JSON.stringify(request.body)
    const signature = request.headers['x-cal-signature-256'] as string
    const secret = process.env.CAL_WEBHOOK_SECRET ?? ''

    if (secret && !verifyCalSignature(rawBody, signature, secret)) {
      end()
      return reply.code(401).send({ error: { code: 'INVALID_SIGNATURE', message: 'Invalid signature' } })
    }

    const payload = request.body as Record<string, unknown>
    const providerEventId = extractProviderEventId('cal', payload)
    await ingestWebhook('cal', providerEventId, payload)
    end()
    return reply.code(200).send({ received: true })
  })

  fastify.post('/api/webhooks/email', async (request, reply) => {
    const end = webhookProcessingDuration.startTimer({ provider: 'email' })
    const payload = request.body as Record<string, unknown>

    // Detect provider by header
    let provider = 'unknown'
    if (request.headers['x-postmark-signature']) provider = 'postmark'
    else if (request.headers['x-mailgun-signature']) provider = 'mailgun'

    const providerEventId = extractProviderEventId(provider, payload)
    await ingestWebhook(provider, providerEventId, payload)
    end()
    return reply.code(200).send({ received: true })
  })
}

export default webhooksPlugin
```

### Step 11.7: Run verifier tests

```bash
cd backend && npx jest tests/unit/webhooks/ --no-coverage
```

Expected: PASS

### Step 11.8: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` section "HMAC Signing" for the signature generation patterns.

With server and workers running (`npm run dev:api` + `npm run dev:worker`):

```bash
CAL_SECRET="${CAL_WEBHOOK_SECRET}"
WAHA_SECRET="${WAHA_WEBHOOK_SECRET}"

# Test 1: Cal.com webhook with valid HMAC-SHA256 signature
PAYLOAD='{"triggerEvent":"BOOKING_CREATED","payload":{"uid":"booking-123","attendees":[{"email":"diana@test.com","name":"Diana Lee"}]}}'
SIG=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$CAL_SECRET" -hex | awk '{print $2}')

curl -X POST http://localhost:3000/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: $SIG" \
  -d "$PAYLOAD"
# Expected: 200 {"received":true}

# Test 2: Cal.com webhook with invalid signature (unhappy path)
BAD_SIG="invalid_signature_xyz123"

curl -X POST http://localhost:3000/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: $BAD_SIG" \
  -d "$PAYLOAD"
# Expected: 401 {"error":{"code":"INVALID_SIGNATURE"...}}

# Test 3: Idempotency -- send same webhook event twice
curl -X POST http://localhost:3000/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: $SIG" \
  -d "$PAYLOAD"
# Expected: 200 (second request is idempotent, same providerEventId)

curl -X POST http://localhost:3000/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: $SIG" \
  -d "$PAYLOAD"
# Expected: 200 (no duplicate webhook_event created)

# Test 4: WAHA webhook with valid HMAC-SHA512 signature
WAHA_PAYLOAD='{"event":"message.ack","from":"447911123456@c.us","id":"msg-uuid-456","ack":4}'
WAHA_SIG=$(echo -n "$WAHA_PAYLOAD" | openssl dgst -sha512 -hmac "$WAHA_SECRET" -hex | awk '{print $2}')

curl -X POST http://localhost:3000/api/webhooks/waha \
  -H "Content-Type: application/json" \
  -H "x-webhook-hmac: $WAHA_SIG" \
  -d "$WAHA_PAYLOAD"
# Expected: 200 {"received":true}

# Wait for webhook worker to process
sleep 5

# Test 5: Verify webhook events stored in DB
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, provider, provider_event_id, status FROM webhook_events ORDER BY created_at DESC LIMIT 5;"
# Expected: rows for cal (booking-123) and waha (msg-uuid-456), status PROCESSED

# Test 6: Email provider webhook (Postmark detected by header)
curl -X POST http://localhost:3000/api/webhooks/email \
  -H "Content-Type: application/json" \
  -H "x-postmark-signature: placeholder" \
  -d '{"RecordType":"Open","Recipient":"diana@test.com","MessageID":"msg-postmark-789"}'
# Expected: 200 {"received":true}
```

## Phase C verification

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` section "HMAC Signing" for signature generation patterns.

Specific verifications for this task:

- POST /api/webhooks/cal accepts valid Cal.com HMAC-SHA256 signature -> 200
- POST /api/webhooks/cal rejects invalid signature -> 401 INVALID_SIGNATURE
- Webhook events are idempotent (same providerEventId = no duplicate row)
- POST /api/webhooks/waha accepts valid WAHA HMAC-SHA512 signature -> 200
- POST /api/webhooks/email accepts Postmark/Mailgun events (detected by header) -> 200
- Webhook payloads are stored in DB, not passed raw to queue (pointer pattern enforced)
- Webhook worker processes events asynchronously (status transitions: RECEIVED -> PROCESSING -> PROCESSED)
- Worker matches webhook events to contacts and creates engagement events via logEngagement
- DB reflects webhook_events rows with correct provider, provider_event_id, and status
- Logs show structured entries for each webhook request
- Missing or empty webhook secret skips verification (graceful degradation)

## Commit

```bash
git add backend/src/modules/webhooks/ tests/unit/webhooks/
git commit -m "feat: add webhooks module with HMAC verification and idempotent ingestion with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
