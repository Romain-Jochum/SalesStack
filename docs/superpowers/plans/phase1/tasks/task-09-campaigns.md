# Task 09: Campaigns Module

**Depends on:** 08
**Parallel with:** none
**Blocks:** 10
**Outputs:** `backend/src/modules/campaigns/schemas.ts`, `campaigns/service.ts`, `campaigns/routes.ts`, `tests/unit/campaigns/service.test.ts`
**Verifies:** CREATE campaign, enroll contact, list enrolled, stage transitions, soft delete
**Estimated context:** ~310 lines

## Intent

Create the campaigns module with full CRUD for campaigns and a contact enrollment sub-resource. Campaigns track outreach sequences (email, WhatsApp, mixed, LinkedIn). Each campaign starts in DRAFT status and can transition through ACTIVE, PAUSED, COMPLETED, CANCELLED. Contacts are enrolled into campaigns via a `CampaignEnrollment` join, which tracks stage, enrollment timestamp, and exit timestamps. Duplicate enrollment is rejected with a 409 CONFLICT. This module follows the vertical-slice pattern (schemas, service, routes) and is wired into the server in Task 15.

## Prerequisites check

- Task 08 (segments module) is committed and passing.
- `sales-db` and `sales-redis` containers are running and healthy.
- The `Campaign` and `CampaignEnrollment` models exist in the Prisma schema (from Task 02) with fields for status, type, settings (JSON), enrollment stage, and timestamps.
- The `Contact` model exists (from Task 05) for the enrollment foreign key.

## Steps

### Step 9.1: Write failing tests (RED)

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

Create `backend/tests/unit/campaigns/service.test.ts`:

```typescript
import { createCampaign, enrollContact } from '../../../src/modules/campaigns/service'
import { PrismaClient, CampaignStatus, CampaignType } from '@prisma/client'

const mockDb = {
  campaign: { create: jest.fn(), findFirst: jest.fn() },
  campaignEnrollment: { create: jest.fn(), findFirst: jest.fn() },
} as unknown as PrismaClient

const mockCampaign = {
  id: 'campaign-uuid-1',
  tenantId: null,
  name: 'Cold Outreach Q1',
  description: null,
  status: CampaignStatus.DRAFT,
  type: CampaignType.EMAIL_SEQUENCE,
  settings: {},
  startDate: null,
  endDate: null,
  createdAt: new Date(),
  updatedAt: new Date(),
  deletedAt: null,
}

beforeEach(() => jest.clearAllMocks())

describe('createCampaign', () => {
  it('creates a campaign with DRAFT status by default', async () => {
    ;(mockDb.campaign.create as jest.Mock).mockResolvedValue(mockCampaign)
    const result = await createCampaign(mockDb, {
      name: 'Cold Outreach Q1',
      type: CampaignType.EMAIL_SEQUENCE,
    })
    expect(result.status).toBe(CampaignStatus.DRAFT)
    expect(result.name).toBe('Cold Outreach Q1')
  })
})

describe('enrollContact', () => {
  it('throws CONFLICT when contact already enrolled', async () => {
    ;(mockDb.campaign.findFirst as jest.Mock).mockResolvedValue(mockCampaign)
    ;(mockDb.campaignEnrollment.findFirst as jest.Mock).mockResolvedValue({ id: 'existing' })
    await expect(enrollContact(mockDb, 'campaign-uuid-1', 'contact-uuid-1')).rejects.toThrow('CONFLICT')
  })

  it('creates enrollment when not already enrolled', async () => {
    ;(mockDb.campaign.findFirst as jest.Mock).mockResolvedValue(mockCampaign)
    ;(mockDb.campaignEnrollment.findFirst as jest.Mock).mockResolvedValue(null)
    ;(mockDb.campaignEnrollment.create as jest.Mock).mockResolvedValue({ id: 'new-enrollment' })
    const result = await enrollContact(mockDb, 'campaign-uuid-1', 'contact-uuid-1')
    expect(result.id).toBe('new-enrollment')
  })
})
```

### Step 9.2: Run test -- verify it fails for the right reason

```bash
cd backend && npx jest tests/unit/campaigns/ --no-coverage
```

Expected: FAIL -- `Cannot find module '../../../src/modules/campaigns/service'`

### Step 9.3: Create `backend/src/modules/campaigns/schemas.ts` (GREEN)

```typescript
import { Static, Type } from '@sinclair/typebox'

export const CreateCampaignSchema = Type.Object({
  name: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  type: Type.Enum({ EMAIL_SEQUENCE: 'EMAIL_SEQUENCE', WHATSAPP_SEQUENCE: 'WHATSAPP_SEQUENCE', MIXED: 'MIXED', LINKEDIN_SEQUENCE: 'LINKEDIN_SEQUENCE' }),
  settings: Type.Optional(Type.Object({
    steps: Type.Optional(Type.Array(Type.Unknown())),
    fromAddress: Type.Optional(Type.String()),
    replyTo: Type.Optional(Type.String()),
    throttle: Type.Optional(Type.Object({
      maxPerDay: Type.Integer(),
      minDelayMinutes: Type.Integer(),
    })),
  })),
  startDate: Type.Optional(Type.String({ format: 'date-time' })),
  endDate: Type.Optional(Type.String({ format: 'date-time' })),
})
export type CreateCampaignInput = Static<typeof CreateCampaignSchema>
```

### Step 9.4: Create `backend/src/modules/campaigns/service.ts`

```typescript
import { PrismaClient, Campaign, CampaignEnrollment, CampaignType } from '@prisma/client'
import { CreateCampaignInput } from './schemas'

export async function createCampaign(
  db: PrismaClient,
  payload: CreateCampaignInput,
): Promise<Campaign> {
  return db.campaign.create({
    data: {
      name: payload.name,
      description: payload.description,
      type: payload.type as CampaignType,
      settings: payload.settings ?? {},
      startDate: payload.startDate ? new Date(payload.startDate) : null,
      endDate: payload.endDate ? new Date(payload.endDate) : null,
    },
  })
}

export async function getCampaign(db: PrismaClient, id: string): Promise<Campaign | null> {
  return db.campaign.findFirst({ where: { id, deletedAt: null } })
}

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

export async function getCampaignContacts(
  db: PrismaClient,
  campaignId: string,
  stage?: string,
): Promise<unknown[]> {
  return db.campaignEnrollment.findMany({
    where: { campaignId, ...(stage && { stage }) },
    include: { contact: true },
    orderBy: { enrolledAt: 'desc' },
  })
}
```

### Step 9.5: Create `backend/src/modules/campaigns/routes.ts`

```typescript
import { FastifyPluginAsync } from 'fastify'
import { CreateCampaignSchema } from './schemas'
import { createCampaign, getCampaign, enrollContact, getCampaignContacts } from './service'
import { db } from '../../core/db'

const campaignsPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.get('/api/campaigns', async (_req, reply) => {
    const campaigns = await db.campaign.findMany({ where: { deletedAt: null }, orderBy: { createdAt: 'desc' } })
    return reply.send({ data: campaigns })
  })

  fastify.post('/api/campaigns', { schema: { body: CreateCampaignSchema } }, async (request, reply) => {
    const campaign = await createCampaign(db, request.body as never)
    return reply.code(201).send({ data: campaign })
  })

  fastify.get('/api/campaigns/:id', async (request, reply) => {
    const campaign = await getCampaign(db, (request.params as { id: string }).id)
    if (!campaign) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Campaign not found' } })
    return reply.send({ data: campaign })
  })

  fastify.patch('/api/campaigns/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const existing = await getCampaign(db, id)
    if (!existing) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Campaign not found' } })
    const updated = await db.campaign.update({ where: { id }, data: request.body as never })
    return reply.send({ data: updated })
  })

  fastify.post('/api/campaigns/:id/enroll', async (request, reply) => {
    const { id } = request.params as { id: string }
    const { contactId } = request.body as { contactId: string }
    try {
      const enrollment = await enrollContact(db, id, contactId)
      return reply.code(201).send({ data: enrollment })
    } catch (err) {
      const msg = String(err)
      if (msg.includes('NOT_FOUND')) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Campaign not found' } })
      if (msg.includes('CONFLICT')) return reply.code(409).send({ error: { code: 'CONFLICT', message: 'Contact already enrolled' } })
      throw err
    }
  })

  fastify.get('/api/campaigns/:id/contacts', async (request, reply) => {
    const { id } = request.params as { id: string }
    const { stage } = request.query as { stage?: string }
    const contacts = await getCampaignContacts(db, id, stage)
    return reply.send({ data: contacts })
  })
}

export default campaignsPlugin
```

### Step 9.6: Run tests -- verify they pass (GREEN)

```bash
cd backend && npx jest tests/unit/campaigns/ --no-coverage
```

Expected: PASS (3 tests passing)

### Step 9.7: Real-life verification (Phase C)

> See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` "Campaign Enrollment" and "Error Testing" sections for curl patterns.

Boot the server with valid database + Redis running, then test:

```bash
# In one terminal, start the stack:
docker compose up -d sales-db sales-redis

# Wait for health checks (30-60 sec)

# In another terminal, start API:
cd backend && npm run dev:api
```

Specific verifications for this task:

```bash
API_KEY="sk_live_test1234567890"

# Test 1: Create a campaign (happy path)
curl -X POST http://localhost:3000/api/campaigns \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"Cold Outreach Q1","type":"EMAIL_SEQUENCE","description":"Outreach to US CTOs"}'
# Expected: 201 Created with status DRAFT
# CAMPAIGN_ID="..."

# Test 2: Get campaigns list
curl http://localhost:3000/api/campaigns \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with data array containing Cold Outreach campaign

# Test 3: Get single campaign
curl http://localhost:3000/api/campaigns/CAMPAIGN_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with full campaign object, status DRAFT

# Test 4: Create a contact to enroll
curl -X POST http://localhost:3000/api/contacts \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Charlie","lastName":"Wilson","email":"charlie@test.com"}'
# Expected: 201 Created
# CONTACT_ID="..."

# Test 5: Enroll contact in campaign (happy path)
curl -X POST http://localhost:3000/api/campaigns/CAMPAIGN_ID/enroll \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"contactId":"CONTACT_ID"}'
# Expected: 201 Created with enrollment object, stage "enrolled"

# Test 6: Try to re-enroll same contact (unhappy path - conflict)
curl -X POST http://localhost:3000/api/campaigns/CAMPAIGN_ID/enroll \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"contactId":"CONTACT_ID"}'
# Expected: 409 Conflict

# Test 7: Get campaign contacts
curl http://localhost:3000/api/campaigns/CAMPAIGN_ID/contacts \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with 1 enrollment containing Charlie

# Test 8: Update campaign (change status)
curl -X PATCH http://localhost:3000/api/campaigns/CAMPAIGN_ID \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status":"ACTIVE"}'
# Expected: 200 with campaign status now ACTIVE
```

## Phase C verification checklist

- [ ] POST /api/campaigns creates campaign with DRAFT status
- [ ] GET /api/campaigns lists all non-deleted campaigns
- [ ] GET /api/campaigns/:id retrieves single campaign
- [ ] POST /api/campaigns/:id/enroll creates enrollment with stage "enrolled"
- [ ] POST /api/campaigns/:id/enroll rejects duplicate enrollment (409 CONFLICT)
- [ ] GET /api/campaigns/:id/contacts returns list of enrolled contacts
- [ ] PATCH /api/campaigns/:id updates campaign properties
- [ ] Non-existent campaign ID returns 404
- [ ] Missing auth returns 401
- [ ] DB tracks campaign enrollments with enrolledAt, completedAt, exitedAt timestamps
- [ ] Logs show structured request/response entries

## Commit

```bash
git add backend/src/modules/campaigns/ tests/unit/campaigns/
git commit -m "feat: add campaigns module with enrollment logic with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
