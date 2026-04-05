# Decision: Pointer Pattern for Webhook Ingestion

**Status:** Decided (Phase 1+)  
**Date:** 2026-04-05  
**Stakeholders:** Architecture, backend engineering, DevOps

---

## Decision

**Webhook routes store payloads once in the database (`WebhookEvent`), then enqueue a job containing only the `webhookEventId` (pointer). Workers retrieve the full payload from the database. Raw webhook payloads are never stored directly in BullMQ job data.**

This pattern applies to Phase 1 webhook ingestion and is extended to Phase 2 research jobs and beyond.

---

## Context

Webhooks arrive from external providers (Cal.com, WAHA, email services) with payloads ranging from ~1KB (Cal.com booking) to 100KB+ (email with full HTML body). At scale:

- 10K webhooks/day × 10KB average = 100MB/day
- BullMQ stores job data in Redis
- Redis is in-memory; disk is not the bottleneck, memory is

The question: where should the full webhook payload live during processing?

---

## Rationale

### ✅ Why Pointer Pattern

**Deduplication Safety (Critical)**
Webhook providers retry on failure. The same webhook event may fire twice (or more):
```
Provider: [sends event X] → timeout → [sends event X again]
```

With pointer pattern:
```typescript
// In routes.ts
const webhookEvent = await db.webhookEvent.upsert({
  where: { provider_providerEventId: { provider: 'cal.com', providerEventId: 'booking-123' } },
  create: { provider, providerEventId, payload, status: 'RECEIVED' },
  update: {}, // ← key: upsert is idempotent
})
// webhookEventId = same both times (because of unique constraint)

await engagementQueue.add('process-webhook', { webhookEventId: webhookEvent.id })
// Job enqueued once; any duplicate event returns the same webhookEventId
```

If the same webhook fires twice in 10 seconds:
1. First event: creates `WebhookEvent` row, enqueues job with `webhookEventId = A`
2. Second event (duplicate): upsert finds existing row, returns `webhookEventId = A`, enqueues job with same ID
3. BullMQ deduplicates by job ID → only one job processes

**Without pointer pattern:** You'd enqueue the full payload twice, potentially doubling processing (CPU, API calls, DB writes).

**Audit Trail (Essential)**
Every webhook received is permanently stored with metadata:
```typescript
{
  id: 'webhook-event-123',
  provider: 'cal.com',
  providerEventId: 'booking-123',
  receivedAt: '2026-04-05T10:00:00Z',
  processedAt: '2026-04-05T10:00:05Z',
  status: 'PROCESSED',  // or FAILED
  payload: { /* full JSON */ },
  error: null,  // or error message if status = FAILED
}
```

Answer critical questions without log mining:
- "Did we receive the webhook?" → Check `receivedAt`
- "Was it processed?" → Check `processedAt` and `status`
- "What went wrong?" → Check `error` field
- "What was in the original payload?" → `payload` field

This is invaluable for support ("customer says their booking created but we don't see it") and debugging.

**Redis Memory Efficiency (Operational)**
BullMQ stores job data in Redis memory. A raw webhook payload is large:

- Cal.com booking: ~1KB JSON
- Email event: 10–100KB (includes full email body/HTML)
- At 10K webhooks/day: worst case 100MB/day × 7 days ≈ 700MB Redis memory for just one week of jobs

With pointers (~100 bytes each):
- 10K webhooks/day × 100 bytes = 1MB/day
- One week: ~7MB

**30–100x memory savings**, which matters on a single-VM deployment.

**Payload Integrity (Safety)**
Workers read from PostgreSQL, not Redis. If Redis data were corrupted (unlikely but possible):
```typescript
// Worker 1
const job = await queue.getJob(jobId)  // gets { webhookEventId }
const event = await db.webhookEvent.findUnique({ where: { id: job.data.webhookEventId } })
// Still intact; reads from Postgres, not Redis
```

Without pointers, the payload would only exist in Redis. Corruption = data loss.

**Replay Capability (Future-Proof)**
A webhook marked `status = 'FAILED'` can be re-queued without re-receiving from the provider:

```typescript
// months later, for audit or to fix a bug:
const event = await db.webhookEvent.findUnique({ where: { id: 'webhook-event-old' } })
// status = 'FAILED', payload still there
await queue.add('process-webhook', { webhookEventId: event.id })
// Re-processes the original payload
```

This enables:
- Post-mortem debugging ("let's reprocess all failed Cal.com events")
- Bug fixes ("we fixed the parser; replay the last 100 failed webhooks")
- One-off operations ("manually reprocess webhook X")

---

## Pattern Implementation

### Route Layer
```typescript
// src/modules/webhooks/routes.ts
fastify.post('/api/webhooks/cal', async (request, reply) => {
  const payload = request.body as Record<string, unknown>
  
  // Step 1: Store payload once
  const webhookEvent = await db.webhookEvent.upsert({
    where: { provider_providerEventId: { provider: 'cal.com', providerEventId: payload.uid } },
    create: {
      provider: 'cal.com',
      providerEventId: String(payload.uid),
      payload,  // full JSON stored
      status: 'RECEIVED',
      receivedAt: new Date(),
    },
    update: {},  // idempotent
  })
  
  // Step 2: Enqueue pointer only
  await engagementQueue.add(
    'process-webhook',
    { webhookEventId: webhookEvent.id },  // ← just the ID
    { jobId: `webhook:${webhookEvent.id}`, deduplication: { id: `webhook:${webhookEvent.id}` } }
  )
  
  return reply.code(200).send({ received: true })
})
```

### Worker Layer
```typescript
// src/modules/webhooks/webhook.worker.ts
export function createWebhookWorker(): Worker {
  return new Worker(
    QUEUE_NAMES.ENGAGEMENT_PROCESS,
    async (job: Job) => {
      const { webhookEventId } = job.data as { webhookEventId: string }
      
      // Step 3: Worker resolves payload from DB
      const webhookEvent = await db.webhookEvent.findUnique({
        where: { id: webhookEventId }
      })
      
      if (!webhookEvent) {
        logger.warn({ webhookEventId }, 'WebhookEvent not found')
        return
      }
      
      // Mark as processing
      await db.webhookEvent.update({
        where: { id: webhookEventId },
        data: { status: 'PROCESSING' }
      })
      
      try {
        // Step 4: Process the payload
        const payload = webhookEvent.payload as Record<string, unknown>
        
        if (webhookEvent.provider === 'cal.com') {
          await processCalEvent(payload)
        } else if (webhookEvent.provider === 'waha') {
          await processWahaEvent(payload)
        }
        
        // Mark as processed
        await db.webhookEvent.update({
          where: { id: webhookEventId },
          data: { status: 'PROCESSED', processedAt: new Date() }
        })
      } catch (err) {
        // Mark as failed
        await db.webhookEvent.update({
          where: { id: webhookEventId },
          data: { status: 'FAILED', error: String(err) }
        })
        throw err  // BullMQ will retry
      }
    },
    { connection: redis, concurrency: 5 }
  )
}
```

### Database Schema
```prisma
model WebhookEvent {
  id              String        @id @default(uuid()) @db.Uuid
  tenantId        String?       @map("tenant_id") @db.Uuid
  provider        String  // 'cal.com', 'waha', 'postmark', 'mailgun'
  providerEventId String  @map("provider_event_id")
  receivedAt      DateTime      @default(now()) @map("received_at")
  processedAt     DateTime?     @map("processed_at")
  status          WebhookStatus @default(RECEIVED)  // RECEIVED, PROCESSING, PROCESSED, FAILED, SKIPPED
  payload         Json          @db.JsonB  // full webhook payload
  error           String?  // error message if status = FAILED

  @@unique([provider, providerEventId])  // ← deduplication key
  @@index([provider, status])  // ← for batch reprocessing
  @@index([receivedAt])  // ← for time-range queries
  @@map("webhook_events")
}

enum WebhookStatus {
  RECEIVED
  PROCESSING
  PROCESSED
  FAILED
  SKIPPED
}
```

---

## Trade-Offs

**Database Size Grows**
- Each webhook row includes the full JSON payload
- 10K webhooks/day × 10KB = 100MB/day → 36GB/year
- Mitigated: Delete old processed webhooks after 30/60/90 days, or archive to S3

**No "Streaming" Patterns**
- Can't pass a webhook stream directly to a function
- Instead: fetch from DB, process in memory
- Acceptable: webhooks are not high-frequency (not like a real-time chat stream); 10K/day is fine

---

## Examples from Phase 1 Plan

**Cal.com webhook:**
```bash
curl -X POST http://localhost:3000/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: $(sig)" \
  -d '{"triggerEvent":"BOOKING_CREATED","payload":{"uid":"booking-123","attendees":[{"email":"alice@test.com"}]}}'

# Step 1: Stored in webhook_events row (unique: provider=cal.com, providerEventId=booking-123)
# Step 2: Enqueued as { webhookEventId: 'webhook-uuid' }
# Step 3: Worker fetches webhook_events row, processes booking
# Step 4: Updates webhook_events.status = PROCESSED, engagement_events created
```

**Replay after bug fix:**
```bash
# Query failed webhooks
SELECT * FROM webhook_events WHERE status = 'FAILED' AND provider = 'cal.com' LIMIT 10

# Re-enqueue each one
INSERT INTO bullmq_jobs (queue_name, name, data, ...)
VALUES ('queue:engagement:process', 'process-webhook', '{"webhookEventId":"..."}', ...)
```

---

## Extension to Phase 2 (Research Jobs)

Phase 2 research jobs will follow the same pattern:
```typescript
// Research job dispatch
const researchJob = await db.researchJob.create({
  data: { targetUrl: '...', status: 'PENDING' }
})

// Enqueue pointer, not the URL itself
await flowProducer.add({
  name: 'research-pipeline',
  data: { researchJobId: researchJob.id },  // ← not the URL
  children: [
    { name: 'scrape', data: { researchJobId: researchJob.id }, ... }
    // ... etc
  ]
})

// Worker resolves job
const job = await db.researchJob.findUnique({ where: { id: researchJobId } })
const targetUrl = job.targetUrl
// proceed
```

This pattern is foundational and carries into all future async work.

---

## Approval

- [ ] Engineering lead
- [ ] Backend architect
- [ ] Database administrator (for long-term storage strategy)

---

## Related Decisions

- `001-minio-not-s3.md` — Where to store research artifacts (MinIO, not Redis)
- `002-flowproducers-research-workflows.md` — Why FlowProducers for multi-stage pipelines
