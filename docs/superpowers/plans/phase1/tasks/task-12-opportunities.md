# Task 12: Opportunities Module

**Depends on:** 04
**Parallel with:** 05, 06, 07, 13
**Blocks:** none
**Outputs:** `backend/src/modules/opportunities/schemas.ts`, `opportunities/service.ts`, `opportunities/routes.ts`
**Verifies:** CRUD opportunity, filter by stage, value + probability update, soft delete
**Estimated context:** ~250 lines

## Intent

Create the opportunities module that tracks sales deals through a pipeline. Each opportunity has a title, optional company/contact/campaign links, a stage (e.g. prospecting, negotiation, closed-won), monetary value, probability percentage, and expected close date. This module provides the CRUD foundation for pipeline visibility and will later feed into reporting and forecasting.

## Prerequisites check

- Task 04 (middleware) is committed and working.
- `sales-db` and `sales-redis` containers are running and healthy.
- The `Opportunity` model exists in the Prisma schema (from Task 02) with fields: `id`, `title`, `companyId`, `contactId`, `campaignId`, `stage`, `value`, `currency`, `probability`, `closeDate`, `metadata`, `createdAt`, `updatedAt`, `deletedAt`.
- Core singletons (`db`, `logger`, `config`) are available from Task 03.

## Steps

### Step 12.1: Create `backend/src/modules/opportunities/schemas.ts`

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

```typescript
import { Static, Type } from '@sinclair/typebox'

export const CreateOpportunitySchema = Type.Object({
  title: Type.String({ minLength: 1 }),
  companyId: Type.Optional(Type.String({ format: 'uuid' })),
  contactId: Type.Optional(Type.String({ format: 'uuid' })),
  campaignId: Type.Optional(Type.String({ format: 'uuid' })),
  stage: Type.Optional(Type.String({ default: 'prospecting' })),
  value: Type.Optional(Type.Number()),
  currency: Type.Optional(Type.String({ default: 'USD' })),
  probability: Type.Optional(Type.Integer({ minimum: 0, maximum: 100 })),
  closeDate: Type.Optional(Type.String({ format: 'date-time' })),
  metadata: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
})
export type CreateOpportunityInput = Static<typeof CreateOpportunitySchema>
```

### Step 12.2: Create `backend/src/modules/opportunities/service.ts`

```typescript
import { PrismaClient, Opportunity } from '@prisma/client'
import { CreateOpportunityInput } from './schemas'

export async function createOpportunity(db: PrismaClient, payload: CreateOpportunityInput): Promise<Opportunity> {
  return db.opportunity.create({
    data: {
      title: payload.title,
      companyId: payload.companyId ?? null,
      contactId: payload.contactId ?? null,
      campaignId: payload.campaignId ?? null,
      stage: payload.stage ?? 'prospecting',
      value: payload.value ?? null,
      currency: payload.currency ?? 'USD',
      probability: payload.probability ?? null,
      closeDate: payload.closeDate ? new Date(payload.closeDate) : null,
      metadata: payload.metadata ?? {},
    },
  })
}

export async function getOpportunity(db: PrismaClient, id: string): Promise<Opportunity | null> {
  return db.opportunity.findFirst({ where: { id, deletedAt: null } })
}

export async function listOpportunities(db: PrismaClient, stage?: string): Promise<Opportunity[]> {
  return db.opportunity.findMany({
    where: { deletedAt: null, ...(stage && { stage }) },
    orderBy: { createdAt: 'desc' },
  })
}

export async function updateOpportunity(db: PrismaClient, id: string, payload: Partial<CreateOpportunityInput>): Promise<Opportunity | null> {
  const existing = await db.opportunity.findFirst({ where: { id, deletedAt: null } })
  if (!existing) return null
  return db.opportunity.update({ where: { id }, data: payload })
}
```

### Step 12.3: Create `backend/src/modules/opportunities/routes.ts`

```typescript
import { FastifyPluginAsync } from 'fastify'
import { CreateOpportunitySchema } from './schemas'
import { createOpportunity, getOpportunity, listOpportunities, updateOpportunity } from './service'
import { db } from '../../core/db'

const opportunitiesPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.get('/api/opportunities', async (request, reply) => {
    const { stage } = request.query as { stage?: string }
    return reply.send({ data: await listOpportunities(db, stage) })
  })

  fastify.post('/api/opportunities', { schema: { body: CreateOpportunitySchema } }, async (request, reply) => {
    const opp = await createOpportunity(db, request.body as never)
    return reply.code(201).send({ data: opp })
  })

  fastify.get('/api/opportunities/:id', async (request, reply) => {
    const opp = await getOpportunity(db, (request.params as { id: string }).id)
    if (!opp) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Opportunity not found' } })
    return reply.send({ data: opp })
  })

  fastify.patch('/api/opportunities/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const opp = await updateOpportunity(db, id, request.body as never)
    if (!opp) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Opportunity not found' } })
    return reply.send({ data: opp })
  })
}

export default opportunitiesPlugin
```

### Step 12.4: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` for curl patterns.

With server running, test opportunities API:

```bash
API_KEY="sk_live_test1234567890"

# Test 1: Create an opportunity (happy path)
curl -X POST http://localhost:3000/api/opportunities \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"title":"Deal with Acme","value":50000,"stage":"prospecting","probability":25}'
# Expected: 201 Created
# OPP_ID="..."

# Test 2: Get opportunities list
curl http://localhost:3000/api/opportunities \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with data array containing Acme deal

# Test 3: Get single opportunity
curl http://localhost:3000/api/opportunities/$OPP_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with full opportunity object

# Test 4: Update opportunity (change stage)
curl -X PATCH http://localhost:3000/api/opportunities/$OPP_ID \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"stage":"negotiation","probability":50}'
# Expected: 200 with updated stage and probability

# Test 5: Filter by stage
curl http://localhost:3000/api/opportunities?stage=prospecting \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with empty data (deal moved to negotiation)

curl http://localhost:3000/api/opportunities?stage=negotiation \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with Acme deal
```

## Phase C verification

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` for curl patterns.

Specific verifications for this task:
- POST /api/opportunities creates opportunity with stage and value -> 201
- GET /api/opportunities lists all non-deleted opportunities -> 200
- GET /api/opportunities/:id retrieves single opportunity -> 200
- PATCH /api/opportunities/:id updates stage, probability, value -> 200
- Filtering by stage works correctly (returns only matching stage)
- Non-existent ID returns 404
- Missing auth returns 401
- Invalid body (missing title) returns 400
- DB reflects all changes (actual PostgreSQL rows)
- Logs show structured request/response entries

## Commit

```bash
git add backend/src/modules/opportunities/
git commit -m "feat: add opportunities module (CRUD) with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
