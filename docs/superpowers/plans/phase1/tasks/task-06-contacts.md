# Task 06: Contacts Module

**Depends on:** 04
**Parallel with:** 05, 07, 12, 13
**Blocks:** 08
**Outputs:** `backend/src/modules/contacts/schemas.ts`, `contacts/service.ts`, `contacts/routes.ts`, `tests/unit/contacts/service.test.ts`
**Verifies:** CRUD contact, bulk upsert queues jobs, soft delete works, pagination and filtering
**Estimated context:** ~500 lines

## Intent

Build the contacts vertical slice: TypeBox request/response schemas, a service layer with CRUD + bulk upsert + soft delete, Fastify route handlers, and unit tests. The contacts module is the first data module in the system and establishes the pattern for all subsequent CRUD modules (companies, campaigns, segments, etc.). Bulk upsert delegates to a BullMQ job via the pointer pattern (returns 202 + job ID).

## Prerequisites check

- Task 04 (core middleware) is committed: `auth`, `error-handler`, and `rate-limit` plugins export correctly.
- `sales-db` and `sales-redis` containers are running and healthy.
- The `Contact`, `ContactCompany`, and related models exist in the Prisma schema (from Task 02).
- Core singletons (`db`, `redis`, `logger`, `config`, `queues`) are available from Task 03.

## Steps

### Step 6.1: Create `backend/src/modules/contacts/schemas.ts`

Define TypeBox schemas for contact CRUD operations, list queries, and bulk upsert.

```typescript
import { Static, Type } from '@sinclair/typebox'

// Install: npm install @sinclair/typebox
// Fastify v5 uses TypeBox natively for schema generation

export const ContactResponseSchema = Type.Object({
  id: Type.String({ format: 'uuid' }),
  tenantId: Type.Union([Type.String(), Type.Null()]),
  firstName: Type.String(),
  lastName: Type.Union([Type.String(), Type.Null()]),
  email: Type.Union([Type.String(), Type.Null()]),
  phone: Type.Union([Type.String(), Type.Null()]),
  jobTitle: Type.Union([Type.String(), Type.Null()]),
  seniority: Type.Union([Type.String(), Type.Null()]),
  linkedinUrl: Type.Union([Type.String(), Type.Null()]),
  engagementScore: Type.Number(),
  customFields: Type.Record(Type.String(), Type.Unknown()),
  createdAt: Type.String({ format: 'date-time' }),
  updatedAt: Type.String({ format: 'date-time' }),
})
export type ContactResponse = Static<typeof ContactResponseSchema>

export const CreateContactSchema = Type.Object({
  firstName: Type.String({ minLength: 1 }),
  lastName: Type.Optional(Type.String()),
  email: Type.Optional(Type.String({ format: 'email' })),
  phone: Type.Optional(Type.String()),
  jobTitle: Type.Optional(Type.String()),
  seniority: Type.Optional(Type.Enum({
    C_LEVEL: 'C_LEVEL', VP: 'VP', DIRECTOR: 'DIRECTOR', MANAGER: 'MANAGER', IC: 'IC',
  })),
  linkedinUrl: Type.Optional(Type.String({ format: 'uri' })),
  timezone: Type.Optional(Type.String()),
  country: Type.Optional(Type.String()),
  city: Type.Optional(Type.String()),
  customFields: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  // Shorthand: also creates ContactCompany record
  companyId: Type.Optional(Type.String({ format: 'uuid' })),
  role: Type.Optional(Type.String()),
})
export type CreateContactInput = Static<typeof CreateContactSchema>

export const UpdateContactSchema = Type.Partial(CreateContactSchema)
export type UpdateContactInput = Static<typeof UpdateContactSchema>

export const ListContactsQuerySchema = Type.Object({
  page: Type.Optional(Type.Integer({ minimum: 1, default: 1 })),
  pageSize: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 50 })),
  search: Type.Optional(Type.String()),
  segmentId: Type.Optional(Type.String({ format: 'uuid' })),
  tagId: Type.Optional(Type.String({ format: 'uuid' })),
  sortBy: Type.Optional(Type.Enum({ createdAt: 'createdAt', engagementScore: 'engagementScore', updatedAt: 'updatedAt' })),
  sortDir: Type.Optional(Type.Enum({ asc: 'asc', desc: 'desc' })),
})
export type ListContactsQuery = Static<typeof ListContactsQuerySchema>

export const BulkUpsertSchema = Type.Object({
  contacts: Type.Array(CreateContactSchema, { minItems: 1, maxItems: 500 }),
  mode: Type.Enum({ upsert: 'upsert', create_only: 'create_only' }),
  upsertKey: Type.Optional(Type.Enum({ email: 'email', linkedinUrl: 'linkedinUrl' })),
})
export type BulkUpsertInput = Static<typeof BulkUpsertSchema>
```

### Step 6.2: Write failing tests for service (RED)

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

Create `tests/unit/contacts/service.test.ts`:

```typescript
import { createContact, getContact, listContacts, updateContact, softDeleteContact } from '../../../src/modules/contacts/service'
import { PrismaClient } from '@prisma/client'

// Mock the Prisma client
const mockDb = {
  contact: {
    create: jest.fn(),
    findFirst: jest.fn(),
    findUnique: jest.fn(),
    update: jest.fn(),
    findMany: jest.fn(),
    count: jest.fn(),
  },
  contactCompany: {
    create: jest.fn(),
  },
  $transaction: jest.fn(),
} as unknown as PrismaClient

const mockContact = {
  id: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  tenantId: null,
  firstName: 'Alice',
  lastName: 'Smith',
  email: 'alice@example.com',
  phone: null,
  jobTitle: 'CTO',
  seniority: null,
  linkedinUrl: null,
  timezone: null,
  country: null,
  city: null,
  emailVerified: false,
  engagementScore: 0,
  customFields: {},
  embedding: null,
  createdAt: new Date('2026-01-01'),
  updatedAt: new Date('2026-01-01'),
  deletedAt: null,
}

beforeEach(() => jest.clearAllMocks())

describe('createContact', () => {
  it('creates a contact and returns it', async () => {
    ;(mockDb.contact.create as jest.Mock).mockResolvedValue(mockContact)
    ;(mockDb.$transaction as jest.Mock).mockImplementation((fn) => fn(mockDb))

    const result = await createContact(mockDb, {
      firstName: 'Alice',
      lastName: 'Smith',
      email: 'alice@example.com',
      jobTitle: 'CTO',
    })

    expect(result).toMatchObject({ firstName: 'Alice', email: 'alice@example.com' })
    expect(mockDb.contact.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ firstName: 'Alice', email: 'alice@example.com' }),
      }),
    )
  })

  it('creates ContactCompany if companyId provided', async () => {
    ;(mockDb.contact.create as jest.Mock).mockResolvedValue(mockContact)
    ;(mockDb.contactCompany.create as jest.Mock).mockResolvedValue({})
    ;(mockDb.$transaction as jest.Mock).mockImplementation(async (fn) => fn(mockDb))

    await createContact(mockDb, {
      firstName: 'Alice',
      companyId: 'company-uuid-here',
      role: 'CTO',
    })

    expect(mockDb.contactCompany.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ companyId: 'company-uuid-here', role: 'CTO', isPrimary: true }),
      }),
    )
  })
})

describe('getContact', () => {
  it('returns null for missing contact', async () => {
    ;(mockDb.contact.findFirst as jest.Mock).mockResolvedValue(null)
    const result = await getContact(mockDb, 'nonexistent-id')
    expect(result).toBeNull()
  })

  it('returns contact when found', async () => {
    ;(mockDb.contact.findFirst as jest.Mock).mockResolvedValue(mockContact)
    const result = await getContact(mockDb, mockContact.id)
    expect(result?.id).toBe(mockContact.id)
  })
})

describe('softDeleteContact', () => {
  it('sets deletedAt to current date', async () => {
    ;(mockDb.contact.update as jest.Mock).mockResolvedValue({ ...mockContact, deletedAt: new Date() })

    await softDeleteContact(mockDb, mockContact.id)

    expect(mockDb.contact.update).toHaveBeenCalledWith({
      where: { id: mockContact.id },
      data: { deletedAt: expect.any(Date) },
    })
  })
})
```

### Step 6.3: Run test -- verify it fails for the right reason

```bash
cd backend && npx jest tests/unit/contacts/ --no-coverage
```

Expected: FAIL -- `Cannot find module '../../../src/modules/contacts/service'`

### Step 6.4: Create `backend/src/modules/contacts/service.ts` (GREEN)

> See `shared/error-contract.md` for the return-null-for-not-found pattern and the throw-and-catch pattern for business logic violations.

```typescript
import { PrismaClient, Contact, Prisma } from '@prisma/client'
import { CreateContactInput, ListContactsQuery, UpdateContactInput } from './schemas'
import { engagementQueue, segmentQueue, QUEUE_NAMES } from '../../core/queues'

export async function createContact(
  db: PrismaClient,
  payload: CreateContactInput,
): Promise<Contact> {
  const { companyId, role, ...contactData } = payload

  return db.$transaction(async (tx) => {
    const contact = await tx.contact.create({
      data: {
        ...contactData,
        customFields: contactData.customFields ?? {},
      },
    })

    if (companyId) {
      await tx.contactCompany.create({
        data: { contactId: contact.id, companyId, role: role ?? null, isPrimary: true },
      })
    }

    return contact
  })
}

export async function getContact(
  db: PrismaClient,
  id: string,
): Promise<(Contact & { contactCompanies?: unknown[]; contactTags?: unknown[] }) | null> {
  return db.contact.findFirst({
    where: { id, deletedAt: null },
    include: {
      contactCompanies: { include: { company: true }, where: { deletedAt: null } },
      contactTags: { include: { tag: true } },
    },
  })
}

export async function listContacts(
  db: PrismaClient,
  query: ListContactsQuery,
): Promise<{ data: Contact[]; total: number }> {
  const { page = 1, pageSize = 50, search, segmentId, tagId, sortBy = 'createdAt', sortDir = 'desc' } = query
  const skip = (page - 1) * pageSize

  const where: Prisma.ContactWhereInput = {
    deletedAt: null,
    ...(search && {
      OR: [
        { firstName: { contains: search, mode: 'insensitive' } },
        { lastName: { contains: search, mode: 'insensitive' } },
        { email: { contains: search, mode: 'insensitive' } },
      ],
    }),
    ...(segmentId && {
      segmentMemberships: { some: { segmentId, removedAt: null } },
    }),
    ...(tagId && {
      contactTags: { some: { tagId } },
    }),
  }

  const [data, total] = await Promise.all([
    db.contact.findMany({ where, skip, take: pageSize, orderBy: { [sortBy]: sortDir } }),
    db.contact.count({ where }),
  ])

  return { data, total }
}

export async function updateContact(
  db: PrismaClient,
  id: string,
  payload: UpdateContactInput,
): Promise<Contact | null> {
  const existing = await db.contact.findFirst({ where: { id, deletedAt: null } })
  if (!existing) return null

  return db.contact.update({ where: { id }, data: payload })
}

export async function softDeleteContact(db: PrismaClient, id: string): Promise<void> {
  await db.contact.update({ where: { id }, data: { deletedAt: new Date() } })
}

export async function bulkUpsertContacts(
  db: PrismaClient,
  contacts: CreateContactInput[],
  mode: 'upsert' | 'create_only',
  upsertKey: 'email' | 'linkedinUrl' = 'email',
): Promise<{ created: number; updated: number; skipped: number; errors: string[] }> {
  let created = 0, updated = 0, skipped = 0
  const errors: string[] = []

  for (const payload of contacts) {
    try {
      const key = payload[upsertKey]
      if (!key) { skipped++; continue }

      if (mode === 'upsert') {
        const existing = await db.contact.findFirst({ where: { [upsertKey]: key, deletedAt: null } })
        if (existing) {
          await db.contact.update({ where: { id: existing.id }, data: payload })
          updated++
        } else {
          await createContact(db, payload)
          created++
        }
      } else {
        await createContact(db, payload)
        created++
      }
    } catch (err) {
      errors.push(`${payload.email ?? 'unknown'}: ${String(err)}`)
    }
  }

  return { created, updated, skipped, errors }
}
```

### Step 6.5: Run tests -- verify they pass

```bash
cd backend && npx jest tests/unit/contacts/ --no-coverage
```

Expected: PASS (5 tests passing)

### Step 6.6: Create `backend/src/modules/contacts/routes.ts`

> See `shared/error-contract.md` for the return-null-for-not-found pattern used in GET/PATCH/DELETE handlers.

```typescript
import { FastifyPluginAsync } from 'fastify'
import { PrismaClient } from '@prisma/client'
import {
  CreateContactSchema,
  UpdateContactSchema,
  ListContactsQuerySchema,
  BulkUpsertSchema,
} from './schemas'
import {
  createContact,
  getContact,
  listContacts,
  updateContact,
  softDeleteContact,
  bulkUpsertContacts,
} from './service'
import { engagementQueue, QUEUE_NAMES } from '../../core/queues'
import { db } from '../../core/db'

const contactsPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.get(
    '/api/contacts',
    { schema: { querystring: ListContactsQuerySchema } },
    async (request, reply) => {
      const { data, total } = await listContacts(db, request.query as never)
      const { page = 1, pageSize = 50 } = request.query as never
      return reply.send({ data, meta: { total, page, pageSize } })
    },
  )

  fastify.post(
    '/api/contacts',
    { schema: { body: CreateContactSchema } },
    async (request, reply) => {
      const contact = await createContact(db, request.body as never)
      return reply.code(201).send({ data: contact })
    },
  )

  fastify.get('/api/contacts/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const contact = await getContact(db, id)
    if (!contact) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Contact not found' } })
    return reply.send({ data: contact })
  })

  fastify.patch(
    '/api/contacts/:id',
    { schema: { body: UpdateContactSchema } },
    async (request, reply) => {
      const { id } = request.params as { id: string }
      const contact = await updateContact(db, id, request.body as never)
      if (!contact) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Contact not found' } })
      return reply.send({ data: contact })
    },
  )

  fastify.delete('/api/contacts/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const existing = await getContact(db, id)
    if (!existing) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Contact not found' } })
    await softDeleteContact(db, id)
    return reply.code(204).send()
  })

  fastify.post(
    '/api/contacts/bulk',
    { schema: { body: BulkUpsertSchema } },
    async (request, reply) => {
      const { contacts, mode, upsertKey } = request.body as never
      const job = await engagementQueue.add(
        'bulk-upsert-contacts',
        { contacts, mode, upsertKey },
        { jobId: `bulk-${Date.now()}` },
      )
      return reply.code(202).send({
        jobId: job.id,
        status: 'accepted',
        statusUrl: `/api/jobs/${job.id}`,
      })
    },
  )
}

export default contactsPlugin
```

## Phase C verification

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` for reusable curl snippets (especially "JSON POST", "JSON PATCH", "DELETE", "Pagination", "Async Jobs", and "Error Testing" sections).

### Endpoints to verify

| Method | Endpoint | Expected status | Notes |
|--------|----------|----------------|-------|
| POST | `/api/contacts` | 201 | Create contact with valid input |
| GET | `/api/contacts` | 200 | List with pagination and `meta` envelope |
| GET | `/api/contacts/:id` | 200 | Single contact with included companies/tags |
| PATCH | `/api/contacts/:id` | 200 | Update fields |
| DELETE | `/api/contacts/:id` | 204 | Soft delete |
| POST | `/api/contacts/bulk` | 202 | Queues BullMQ job, returns job ID |

### Specific scenarios

Boot the server following the instructions in `shared/phase-c-template.md` (start `sales-db`, `sales-redis`, then `npm run dev:api`). Also start the worker (`npm run dev:worker`) for bulk upsert testing.

```bash
API_KEY="sk_live_test1234567890"  # From Task 4

# Test 1: Create a contact (happy path)
curl -X POST http://localhost:3000/api/contacts \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Alice","lastName":"Smith","email":"alice@test.com","jobTitle":"CTO"}'
# Expected: 201 Created with contact object

# Test 2: Get contacts list
curl http://localhost:3000/api/contacts \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with data array containing Alice, meta with total/page/pageSize

# Test 3: Get single contact (use id from Test 1)
CONTACT_ID="..."  # paste id from Test 1 response
curl http://localhost:3000/api/contacts/$CONTACT_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with full contact object including contactCompanies and contactTags

# Test 4: Update contact
curl -X PATCH http://localhost:3000/api/contacts/$CONTACT_ID \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jobTitle":"VP Engineering"}'
# Expected: 200 with updated contact

# Test 5: Update contact (unhappy path - invalid input)
curl -X PATCH http://localhost:3000/api/contacts/$CONTACT_ID \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firstName":""}'
# Expected: 400 VALIDATION_ERROR (minLength: 1 violated)

# Test 6: Get non-existent contact
curl http://localhost:3000/api/contacts/00000000-0000-0000-0000-000000000000 \
  -H "Authorization: Bearer $API_KEY"
# Expected: 404 NOT_FOUND

# Test 7: Missing auth header
curl http://localhost:3000/api/contacts
# Expected: 401 UNAUTHORIZED

# Test 8: Delete contact
curl -X DELETE http://localhost:3000/api/contacts/$CONTACT_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 204 No Content

# Test 9: Verify soft delete (GET after DELETE)
curl http://localhost:3000/api/contacts/$CONTACT_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 404 Not Found

# Test 10: List with search
curl "http://localhost:3000/api/contacts?search=alice" \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with matching contacts (may be empty after soft delete)

# Test 11: List with pagination
curl "http://localhost:3000/api/contacts?page=1&pageSize=10&sortBy=createdAt&sortDir=desc" \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with data array and correct meta

# Test 12: Bulk upsert (pointer pattern)
curl -X POST http://localhost:3000/api/contacts/bulk \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"contacts":[{"firstName":"Eve","email":"eve@test.com"},{"firstName":"Frank","email":"frank@test.com"}],"mode":"create_only"}'
# Expected: 202 Accepted with jobId and statusUrl
```

### Database verification

```bash
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, first_name, email, engagement_score, deleted_at FROM contacts ORDER BY created_at DESC LIMIT 5;"
```

Verify:
- New rows exist after POST
- `deleted_at` is set (not NULL) after DELETE
- No orphaned rows

### Verification checklist

```
- [ ] POST /api/contacts creates contact with valid input (201)
- [ ] GET /api/contacts lists all non-deleted contacts with meta envelope (200)
- [ ] GET /api/contacts/:id retrieves single contact with includes (200)
- [ ] PATCH /api/contacts/:id updates contact fields (200)
- [ ] PATCH /api/contacts/:id rejects invalid input (400 VALIDATION_ERROR)
- [ ] DELETE /api/contacts/:id soft-deletes contact (204)
- [ ] GET after DELETE returns 404 NOT_FOUND
- [ ] Non-existent ID returns 404 NOT_FOUND
- [ ] Missing auth returns 401 UNAUTHORIZED
- [ ] Search query filters results correctly
- [ ] Pagination and sorting work as expected
- [ ] POST /api/contacts/bulk returns 202 with jobId (pointer pattern)
- [ ] DB reflects all changes (actual PostgreSQL rows)
- [ ] Logs show structured request/response entries
```

## Commit

```bash
git add backend/src/modules/contacts/ tests/unit/contacts/
git commit -m "feat: add contacts module (schemas, service, routes) with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
