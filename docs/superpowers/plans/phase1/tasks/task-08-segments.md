# Task 08: Segments Module + Filter Engine

**Depends on:** 06
**Parallel with:** none
**Blocks:** 09, 14
**Outputs:** `backend/src/modules/segments/filter-engine.ts`, `segments/schemas.ts`, `segments/service.ts`, `segments/routes.ts`, `segments/segment.worker.ts`, `tests/unit/segments/filter-engine.test.ts`
**Verifies:** Filter engine evaluates AND/OR/NOT, segment worker enqueues, member list updates, evaluation async via pointer pattern
**Estimated context:** ~550 lines

## Intent

Build the segments module: a filter engine that evaluates AND/OR/NOT rule groups against contact records, a BullMQ worker that asynchronously evaluates dynamic segments and updates membership, and CRUD routes for segments with manual add/remove of contacts. The filter engine uses a recursive FilterRuleGroup AST supporting nested groups, dot-notation field access (for customFields), and 12 comparison operators. Segment evaluation is triggered via `POST /api/segments/evaluate` which returns 202 Accepted (pointer pattern) and queues a BullMQ job.

## Prerequisites check

- Task 06 (contacts module) is committed: `Contact` model exists, contacts CRUD works.
- The `Segment` and `ContactSegmentMembership` models exist in the Prisma schema (from Task 02) with the expected fields.
- `segmentQueue` and `QUEUE_NAMES.SEGMENT_EVALUATE` are exported from `core/queues` (from Task 03).
- `sales-db` and `sales-redis` containers are running and healthy.

## Steps

### Step 8.1: Write failing filter-engine tests (RED)

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

Create `tests/unit/segments/filter-engine.test.ts`:

```typescript
import { evaluateFilterRuleGroup, FilterRuleGroup } from '../../../src/modules/segments/filter-engine'

const mockContact = {
  firstName: 'Alice',
  lastName: 'Smith',
  email: 'alice@acme.com',
  jobTitle: 'CTO',
  country: 'US',
  engagementScore: 75,
  customFields: { industry: 'SaaS', employeeRange: '50-100' },
}

describe('evaluateFilterRuleGroup', () => {
  it('evaluates simple eq rule', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [{ field: 'country', op: 'eq', value: 'US' }],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(true)
  })

  it('evaluates eq rule — mismatch', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [{ field: 'country', op: 'eq', value: 'FR' }],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(false)
  })

  it('evaluates contains rule', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [{ field: 'email', op: 'contains', value: 'acme' }],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(true)
  })

  it('evaluates gt rule on engagementScore', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [{ field: 'engagementScore', op: 'gt', value: 50 }],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(true)
  })

  it('evaluates AND group — all must pass', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [
        { field: 'country', op: 'eq', value: 'US' },
        { field: 'engagementScore', op: 'gt', value: 100 }, // fails
      ],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(false)
  })

  it('evaluates OR group — any can pass', () => {
    const rule: FilterRuleGroup = {
      operator: 'OR',
      rules: [
        { field: 'country', op: 'eq', value: 'FR' }, // fails
        { field: 'country', op: 'eq', value: 'US' }, // passes
      ],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(true)
  })

  it('evaluates nested groups', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [
        { field: 'country', op: 'eq', value: 'US' },
        {
          operator: 'OR',
          rules: [
            { field: 'jobTitle', op: 'eq', value: 'CEO' },
            { field: 'jobTitle', op: 'eq', value: 'CTO' },
          ],
        },
      ],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(true)
  })

  it('evaluates customFields with dot notation', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [{ field: 'customFields.industry', op: 'eq', value: 'SaaS' }],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(true)
  })

  it('evaluates in operator', () => {
    const rule: FilterRuleGroup = {
      operator: 'AND',
      rules: [{ field: 'country', op: 'in', value: ['US', 'CA', 'UK'] }],
    }
    expect(evaluateFilterRuleGroup(rule, mockContact)).toBe(true)
  })
})
```

### Step 8.2: Run test -- verify it fails for the right reason

```bash
cd backend && npx jest tests/unit/segments/filter-engine.test.ts --no-coverage
```

Expected: FAIL -- `Cannot find module '../../../src/modules/segments/filter-engine'`

### Step 8.3: Create `backend/src/modules/segments/filter-engine.ts` (GREEN)

```typescript
export type FilterOperator = 'eq' | 'neq' | 'contains' | 'not_contains' | 'gt' | 'lt' | 'gte' | 'lte' | 'in' | 'not_in' | 'exists' | 'not_exists'

export interface FilterRule {
  field: string
  op: FilterOperator
  value?: unknown
}

export interface FilterRuleGroup {
  operator: 'AND' | 'OR'
  rules: Array<FilterRule | FilterRuleGroup>
}

function isFilterRuleGroup(rule: FilterRule | FilterRuleGroup): rule is FilterRuleGroup {
  return 'operator' in rule && 'rules' in rule
}

function getFieldValue(record: Record<string, unknown>, field: string): unknown {
  const parts = field.split('.')
  let current: unknown = record
  for (const part of parts) {
    if (current == null || typeof current !== 'object') return undefined
    current = (current as Record<string, unknown>)[part]
  }
  return current
}

function evaluateRule(rule: FilterRule, record: Record<string, unknown>): boolean {
  const fieldValue = getFieldValue(record, rule.field)

  switch (rule.op) {
    case 'eq':
      return fieldValue === rule.value
    case 'neq':
      return fieldValue !== rule.value
    case 'contains':
      return typeof fieldValue === 'string' && typeof rule.value === 'string'
        ? fieldValue.toLowerCase().includes(rule.value.toLowerCase())
        : false
    case 'not_contains':
      return typeof fieldValue === 'string' && typeof rule.value === 'string'
        ? !fieldValue.toLowerCase().includes(rule.value.toLowerCase())
        : true
    case 'gt':
      return typeof fieldValue === 'number' && typeof rule.value === 'number'
        ? fieldValue > rule.value
        : false
    case 'lt':
      return typeof fieldValue === 'number' && typeof rule.value === 'number'
        ? fieldValue < rule.value
        : false
    case 'gte':
      return typeof fieldValue === 'number' && typeof rule.value === 'number'
        ? fieldValue >= rule.value
        : false
    case 'lte':
      return typeof fieldValue === 'number' && typeof rule.value === 'number'
        ? fieldValue <= rule.value
        : false
    case 'in':
      return Array.isArray(rule.value) && rule.value.includes(fieldValue)
    case 'not_in':
      return Array.isArray(rule.value) && !rule.value.includes(fieldValue)
    case 'exists':
      return fieldValue != null
    case 'not_exists':
      return fieldValue == null
    default:
      return false
  }
}

export function evaluateFilterRuleGroup(
  group: FilterRuleGroup,
  record: Record<string, unknown>,
): boolean {
  const results = group.rules.map((rule) =>
    isFilterRuleGroup(rule)
      ? evaluateFilterRuleGroup(rule, record)
      : evaluateRule(rule, record),
  )

  return group.operator === 'AND' ? results.every(Boolean) : results.some(Boolean)
}
```

### Step 8.4: Run test -- verify it passes

```bash
cd backend && npx jest tests/unit/segments/filter-engine.test.ts --no-coverage
```

Expected: PASS (9 tests passing)

### Step 8.5: Create `backend/src/modules/segments/schemas.ts`

```typescript
import { Static, Type } from '@sinclair/typebox'

const FilterRuleSchema = Type.Recursive((Self) =>
  Type.Union([
    // Leaf rule
    Type.Object({
      field: Type.String(),
      op: Type.Enum({
        eq: 'eq', neq: 'neq', contains: 'contains', not_contains: 'not_contains',
        gt: 'gt', lt: 'lt', gte: 'gte', lte: 'lte', in: 'in', not_in: 'not_in',
        exists: 'exists', not_exists: 'not_exists',
      }),
      value: Type.Optional(Type.Unknown()),
    }),
    // Group
    Type.Object({
      operator: Type.Enum({ AND: 'AND', OR: 'OR' }),
      rules: Type.Array(Self),
    }),
  ]),
)

export const CreateSegmentSchema = Type.Object({
  name: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  filterRules: Type.Object({
    operator: Type.Enum({ AND: 'AND', OR: 'OR' }),
    rules: Type.Array(Type.Unknown()),
  }),
  isDynamic: Type.Optional(Type.Boolean({ default: true })),
})
export type CreateSegmentInput = Static<typeof CreateSegmentSchema>
```

### Step 8.6: Create `backend/src/modules/segments/service.ts`

```typescript
import { PrismaClient, Segment } from '@prisma/client'
import { CreateSegmentInput } from './schemas'
import { FilterRuleGroup } from './filter-engine'
import { segmentQueue, QUEUE_NAMES } from '../../core/queues'

export async function createSegment(db: PrismaClient, payload: CreateSegmentInput): Promise<Segment> {
  return db.segment.create({
    data: {
      name: payload.name,
      description: payload.description,
      filterRules: payload.filterRules as object,
      isDynamic: payload.isDynamic ?? true,
    },
  })
}

export async function getSegment(db: PrismaClient, id: string): Promise<Segment | null> {
  return db.segment.findFirst({ where: { id, deletedAt: null } })
}

export async function listSegments(db: PrismaClient): Promise<Segment[]> {
  return db.segment.findMany({ where: { deletedAt: null }, orderBy: { createdAt: 'desc' } })
}

export async function getSegmentContacts(
  db: PrismaClient,
  segmentId: string,
  page: number = 1,
  pageSize: number = 50,
): Promise<{ data: unknown[]; total: number }> {
  const skip = (page - 1) * pageSize
  const where = { segmentId, removedAt: null }
  const [memberships, total] = await Promise.all([
    db.contactSegmentMembership.findMany({
      where,
      skip,
      take: pageSize,
      include: { contact: true },
    }),
    db.contactSegmentMembership.count({ where }),
  ])
  return { data: memberships.map((m) => m.contact), total }
}

export async function addContactToSegment(
  db: PrismaClient,
  segmentId: string,
  contactId: string,
): Promise<void> {
  await db.contactSegmentMembership.upsert({
    where: { contactId_segmentId: { contactId, segmentId } },
    create: { contactId, segmentId, addedBy: 'manual' },
    update: { removedAt: null, addedBy: 'manual' },
  })
}

export async function removeContactFromSegment(
  db: PrismaClient,
  segmentId: string,
  contactId: string,
): Promise<void> {
  await db.contactSegmentMembership.update({
    where: { contactId_segmentId: { contactId, segmentId } },
    data: { removedAt: new Date() },
  })
}

export async function queueSegmentEvaluation(segmentIds?: string[]): Promise<void> {
  const jobs = segmentIds
    ? segmentIds.map((id) => ({ name: 'evaluate', data: { segmentId: id }, opts: { jobId: `seg-eval:${id}`, deduplication: { id: `seg-eval:${id}` } } }))
    : [{ name: 'evaluate-all', data: { all: true }, opts: { jobId: 'seg-eval-all' } }]

  await segmentQueue.addBulk(jobs)
}
```

### Step 8.7: Create `backend/src/modules/segments/segment.worker.ts`

```typescript
import { Worker, Job } from 'bullmq'
import { redis } from '../../core/redis'
import { db } from '../../core/db'
import { QUEUE_NAMES } from '../../core/queues'
import { evaluateFilterRuleGroup, FilterRuleGroup } from './filter-engine'
import { logger } from '../../core/logger'

export function createSegmentWorker(): Worker {
  return new Worker(
    QUEUE_NAMES.SEGMENT_EVALUATE,
    async (job: Job) => {
      const { segmentId, all } = job.data as { segmentId?: string; all?: boolean }

      const segments = all
        ? await db.segment.findMany({ where: { isDynamic: true, deletedAt: null } })
        : segmentId
          ? [await db.segment.findFirst({ where: { id: segmentId, deletedAt: null } })].filter(Boolean)
          : []

      for (const segment of segments) {
        if (!segment) continue
        logger.info({ segmentId: segment.id }, 'Evaluating segment')

        const filterRules = segment.filterRules as unknown as FilterRuleGroup
        const contacts = await db.contact.findMany({
          where: { deletedAt: null },
          select: {
            id: true, firstName: true, lastName: true, email: true, jobTitle: true,
            seniority: true, country: true, city: true, engagementScore: true,
            customFields: true,
          },
        })

        const matchingIds = new Set<string>()
        for (const contact of contacts) {
          if (evaluateFilterRuleGroup(filterRules, contact as Record<string, unknown>)) {
            matchingIds.add(contact.id)
          }
        }

        // Upsert memberships for matching contacts
        const upserts = Array.from(matchingIds).map((contactId) =>
          db.contactSegmentMembership.upsert({
            where: { contactId_segmentId: { contactId, segmentId: segment.id } },
            create: { contactId, segmentId: segment.id, addedBy: 'system' },
            update: { removedAt: null },
          }),
        )

        // Remove contacts that no longer match
        await db.contactSegmentMembership.updateMany({
          where: {
            segmentId: segment.id,
            contactId: { notIn: Array.from(matchingIds) },
            removedAt: null,
          },
          data: { removedAt: new Date() },
        })

        await Promise.all(upserts)

        await db.segment.update({
          where: { id: segment.id },
          data: { lastEvaluatedAt: new Date(), memberCount: matchingIds.size },
        })

        logger.info({ segmentId: segment.id, memberCount: matchingIds.size }, 'Segment evaluated')
      }
    },
    { connection: redis, concurrency: 2 },
  )
}
```

### Step 8.8: Create `backend/src/modules/segments/routes.ts`

```typescript
import { FastifyPluginAsync } from 'fastify'
import { CreateSegmentSchema } from './schemas'
import {
  createSegment, getSegment, listSegments, getSegmentContacts,
  addContactToSegment, removeContactFromSegment, queueSegmentEvaluation,
} from './service'
import { db } from '../../core/db'

const segmentsPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.get('/api/segments', async (_req, reply) => {
    return reply.send({ data: await listSegments(db) })
  })

  fastify.post('/api/segments', { schema: { body: CreateSegmentSchema } }, async (request, reply) => {
    const segment = await createSegment(db, request.body as never)
    return reply.code(201).send({ data: segment })
  })

  fastify.get('/api/segments/:id/contacts', async (request, reply) => {
    const { id } = request.params as { id: string }
    const { page, pageSize } = request.query as { page?: number; pageSize?: number }
    const result = await getSegmentContacts(db, id, page, pageSize)
    return reply.send(result)
  })

  fastify.post('/api/segments/:id/contacts/:contactId', async (request, reply) => {
    const { id, contactId } = request.params as { id: string; contactId: string }
    await addContactToSegment(db, id, contactId)
    return reply.code(201).send({ data: { segmentId: id, contactId } })
  })

  fastify.delete('/api/segments/:id/contacts/:contactId', async (request, reply) => {
    const { id, contactId } = request.params as { id: string; contactId: string }
    await removeContactFromSegment(db, id, contactId)
    return reply.code(204).send()
  })

  fastify.post('/api/segments/evaluate', async (request, reply) => {
    const { segmentIds } = (request.body ?? {}) as { segmentIds?: string[] }
    await queueSegmentEvaluation(segmentIds)
    return reply.code(202).send({ status: 'accepted', message: 'Segment evaluation queued' })
  })
}

export default segmentsPlugin
```

### Step 8.9: Run all segment tests

```bash
cd backend && npx jest tests/unit/segments/ --no-coverage
```

Expected: PASS (9 filter-engine tests passing)

### Step 8.10: Real-life verification (Phase C)

> See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` for curl snippets.

With server and workers running, test segments end-to-end:

```bash
# Prerequisites: start infra + dev servers
docker compose up -d sales-db sales-redis
cd backend && npm run dev:api    # Terminal 1
cd backend && npm run dev:worker # Terminal 2

API_KEY="sk_live_test1234567890"
```

```bash
# Test 1: Create a segment with filter rules
curl -X POST http://localhost:3000/api/segments \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "US CTOs",
    "filterRules": {
      "operator": "AND",
      "rules": [
        {"field": "country", "op": "eq", "value": "US"},
        {"field": "jobTitle", "op": "eq", "value": "CTO"}
      ]
    }
  }'
# Expected: 201 Created with segment object
# SEGMENT_ID="..."
```

```bash
# Test 2: Create contacts that match (and don't match) the segment
curl -X POST http://localhost:3000/api/contacts \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Alice","lastName":"Smith","email":"alice@test.com","jobTitle":"CTO","country":"US"}'
# Expected: 201 Created (Alice matches: US + CTO)
# ALICE_ID="..."

curl -X POST http://localhost:3000/api/contacts \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Bob","lastName":"Jones","email":"bob@test.com","jobTitle":"Manager","country":"UK"}'
# Expected: 201 Created (Bob doesn't match: UK + Manager)
```

```bash
# Test 3: Trigger segment evaluation
curl -X POST http://localhost:3000/api/segments/evaluate \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"segmentIds":["SEGMENT_ID"]}'
# Expected: 202 Accepted (job queued)

# Wait for worker to process (5-10 sec)
sleep 5
```

```bash
# Test 4: Get segment members (should include Alice but not Bob)
curl http://localhost:3000/api/segments/SEGMENT_ID/contacts \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with 1 contact (Alice)
```

```bash
# Test 5: Manually add a contact to segment
curl -X POST http://localhost:3000/api/segments/SEGMENT_ID/contacts/ALICE_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 201 Created
```

```bash
# Test 6: Remove from segment
curl -X DELETE http://localhost:3000/api/segments/SEGMENT_ID/contacts/ALICE_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 204 No Content
```

## Phase C verification checklist

- [ ] POST /api/segments creates segment with filter rules (201)
- [ ] GET /api/segments lists all non-deleted segments (200)
- [ ] Filter engine evaluates rules correctly (matches US CTO, rejects UK Manager)
- [ ] POST /api/segments/evaluate queues async evaluation job (202)
- [ ] Segment evaluation worker processes job and updates memberships
- [ ] GET /api/segments/:id/contacts returns matching members after evaluation
- [ ] POST /api/segments/:id/contacts/:contactId manually adds contact (201)
- [ ] DELETE /api/segments/:id/contacts/:contactId removes contact (204)
- [ ] DB tracks segment memberships with addedAt, addedBy, removedAt
- [ ] Missing auth returns 401
- [ ] Logs show structured request/response entries and worker evaluation output

## Commit

```bash
git add backend/src/modules/segments/ tests/unit/segments/
git commit -m "feat: add segments module with FilterRuleGroup AST evaluator and BullMQ worker with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
