# Task 07: Companies Module

**Depends on:** 04
**Parallel with:** 05, 06, 12, 13
**Blocks:** none
**Outputs:** `backend/src/modules/companies/schemas.ts`, `companies/service.ts`, `companies/routes.ts`, `tests/unit/companies/service.test.ts`
**Verifies:** CRUD company, linked to contacts, filtering by industry works, soft delete
**Estimated context:** ~290 lines

## Intent

Create the companies module following the vertical-slice pattern: TypeBox schemas for request/response validation, a service layer with pure Prisma queries (create, get, list with search, update, soft-delete), and Fastify route handlers that wire everything together. Includes a sub-route `GET /api/companies/:id/contacts` to list contacts linked to a given company via the `ContactCompany` join table.

## Prerequisites check

- Task 04 (core middleware) is committed: `auth`, `error-handler`, `rate-limit` all export correctly.
- `sales-db` and `sales-redis` containers are running and healthy.
- The `Company` model exists in the Prisma schema (from Task 02) with fields: `id`, `tenantId`, `name`, `domain`, `website`, `industry`, `employeeCount`, `annualRevenue`, `country`, `city`, `state`, `linkedinUrl`, `description`, `customFields`, `embedding`, `createdAt`, `updatedAt`, `deletedAt`.
- The `ContactCompany` join model exists for the company-contacts sub-route.
- The `db` singleton from `core/db` is importable and functional.

## Steps

### Step 7.1: Write failing test (RED)

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

Create `tests/unit/companies/service.test.ts`:

```typescript
import { createCompany, getCompany, listCompanies, updateCompany, softDeleteCompany } from '../../../src/modules/companies/service'
import { PrismaClient } from '@prisma/client'

const mockDb = {
  company: {
    create: jest.fn(),
    findFirst: jest.fn(),
    findMany: jest.fn(),
    update: jest.fn(),
    count: jest.fn(),
  },
} as unknown as PrismaClient

const mockCompany = {
  id: 'company-uuid-1',
  tenantId: null,
  name: 'Acme Corp',
  domain: 'acme.com',
  website: 'https://acme.com',
  industry: 'SaaS',
  employeeCount: 50,
  annualRevenue: null,
  country: 'US',
  city: 'San Francisco',
  state: 'CA',
  linkedinUrl: null,
  description: null,
  customFields: {},
  embedding: null,
  createdAt: new Date('2026-01-01'),
  updatedAt: new Date('2026-01-01'),
  deletedAt: null,
}

beforeEach(() => jest.clearAllMocks())

describe('createCompany', () => {
  it('creates a company', async () => {
    ;(mockDb.company.create as jest.Mock).mockResolvedValue(mockCompany)
    const result = await createCompany(mockDb, { name: 'Acme Corp', domain: 'acme.com' })
    expect(result.name).toBe('Acme Corp')
  })
})

describe('softDeleteCompany', () => {
  it('sets deletedAt', async () => {
    ;(mockDb.company.update as jest.Mock).mockResolvedValue({ ...mockCompany, deletedAt: new Date() })
    await softDeleteCompany(mockDb, mockCompany.id)
    expect(mockDb.company.update).toHaveBeenCalledWith({
      where: { id: mockCompany.id },
      data: { deletedAt: expect.any(Date) },
    })
  })
})
```

### Step 7.2: Run test -- verify it fails for the right reason

```bash
cd backend && npx jest tests/unit/companies/ --no-coverage
```

Expected: FAIL -- `Cannot find module '../../../src/modules/companies/service'`

### Step 7.3: Create `backend/src/modules/companies/schemas.ts` (GREEN)

```typescript
import { Static, Type } from '@sinclair/typebox'

export const CompanyResponseSchema = Type.Object({
  id: Type.String({ format: 'uuid' }),
  tenantId: Type.Union([Type.String(), Type.Null()]),
  name: Type.String(),
  domain: Type.Union([Type.String(), Type.Null()]),
  website: Type.Union([Type.String(), Type.Null()]),
  industry: Type.Union([Type.String(), Type.Null()]),
  employeeCount: Type.Union([Type.Integer(), Type.Null()]),
  country: Type.Union([Type.String(), Type.Null()]),
  city: Type.Union([Type.String(), Type.Null()]),
  linkedinUrl: Type.Union([Type.String(), Type.Null()]),
  customFields: Type.Record(Type.String(), Type.Unknown()),
  createdAt: Type.String({ format: 'date-time' }),
  updatedAt: Type.String({ format: 'date-time' }),
})

export const CreateCompanySchema = Type.Object({
  name: Type.String({ minLength: 1 }),
  domain: Type.Optional(Type.String()),
  website: Type.Optional(Type.String({ format: 'uri' })),
  industry: Type.Optional(Type.String()),
  employeeCount: Type.Optional(Type.Integer({ minimum: 0 })),
  annualRevenue: Type.Optional(Type.Number()),
  country: Type.Optional(Type.String()),
  city: Type.Optional(Type.String()),
  state: Type.Optional(Type.String()),
  linkedinUrl: Type.Optional(Type.String({ format: 'uri' })),
  description: Type.Optional(Type.String()),
  customFields: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
})
export type CreateCompanyInput = Static<typeof CreateCompanySchema>
export const UpdateCompanySchema = Type.Partial(CreateCompanySchema)
export type UpdateCompanyInput = Static<typeof UpdateCompanySchema>
```

### Step 7.4: Create `backend/src/modules/companies/service.ts`

```typescript
import { PrismaClient, Company, Prisma } from '@prisma/client'
import { CreateCompanyInput, UpdateCompanyInput } from './schemas'

export async function createCompany(db: PrismaClient, payload: CreateCompanyInput): Promise<Company> {
  return db.company.create({ data: { ...payload, customFields: payload.customFields ?? {} } })
}

export async function getCompany(db: PrismaClient, id: string): Promise<Company | null> {
  return db.company.findFirst({ where: { id, deletedAt: null } })
}

export async function listCompanies(
  db: PrismaClient,
  query: { page?: number; pageSize?: number; search?: string },
): Promise<{ data: Company[]; total: number }> {
  const { page = 1, pageSize = 50, search } = query
  const skip = (page - 1) * pageSize
  const where: Prisma.CompanyWhereInput = {
    deletedAt: null,
    ...(search && {
      OR: [
        { name: { contains: search, mode: 'insensitive' } },
        { domain: { contains: search, mode: 'insensitive' } },
      ],
    }),
  }
  const [data, total] = await Promise.all([
    db.company.findMany({ where, skip, take: pageSize, orderBy: { createdAt: 'desc' } }),
    db.company.count({ where }),
  ])
  return { data, total }
}

export async function updateCompany(db: PrismaClient, id: string, payload: UpdateCompanyInput): Promise<Company | null> {
  const existing = await db.company.findFirst({ where: { id, deletedAt: null } })
  if (!existing) return null
  return db.company.update({ where: { id }, data: payload })
}

export async function softDeleteCompany(db: PrismaClient, id: string): Promise<void> {
  await db.company.update({ where: { id }, data: { deletedAt: new Date() } })
}
```

### Step 7.5: Create `backend/src/modules/companies/routes.ts`

```typescript
import { FastifyPluginAsync } from 'fastify'
import { CreateCompanySchema, UpdateCompanySchema } from './schemas'
import { createCompany, getCompany, listCompanies, updateCompany, softDeleteCompany } from './service'
import { db } from '../../core/db'

const companiesPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.get('/api/companies', async (request, reply) => {
    const query = request.query as { page?: number; pageSize?: number; search?: string }
    const { data, total } = await listCompanies(db, query)
    return reply.send({ data, meta: { total, page: query.page ?? 1, pageSize: query.pageSize ?? 50 } })
  })

  fastify.post('/api/companies', { schema: { body: CreateCompanySchema } }, async (request, reply) => {
    const company = await createCompany(db, request.body as never)
    return reply.code(201).send({ data: company })
  })

  fastify.get('/api/companies/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const company = await getCompany(db, id)
    if (!company) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Company not found' } })
    return reply.send({ data: company })
  })

  fastify.get('/api/companies/:id/contacts', async (request, reply) => {
    const { id } = request.params as { id: string }
    const contacts = await db.contact.findMany({
      where: {
        deletedAt: null,
        contactCompanies: { some: { companyId: id, deletedAt: null } },
      },
      include: { contactCompanies: { where: { companyId: id } } },
    })
    return reply.send({ data: contacts, meta: { total: contacts.length } })
  })

  fastify.patch('/api/companies/:id', { schema: { body: UpdateCompanySchema } }, async (request, reply) => {
    const { id } = request.params as { id: string }
    const company = await updateCompany(db, id, request.body as never)
    if (!company) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Company not found' } })
    return reply.send({ data: company })
  })

  fastify.delete('/api/companies/:id', async (request, reply) => {
    const existing = await getCompany(db, (request.params as { id: string }).id)
    if (!existing) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Company not found' } })
    await softDeleteCompany(db, (request.params as { id: string }).id)
    return reply.code(204).send()
  })
}

export default companiesPlugin
```

### Step 7.6: Run tests -- verify they pass

```bash
cd backend && npx jest tests/unit/companies/ --no-coverage
```

Expected: PASS (2 tests passing)

### Step 7.7: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` for curl patterns.

Specific endpoints introduced by this task:

| Method | Endpoint | Expected status |
|--------|----------|----------------|
| POST | `/api/companies` | 201 Created |
| GET | `/api/companies` | 200 OK |
| GET | `/api/companies/:id` | 200 OK |
| GET | `/api/companies/:id/contacts` | 200 OK |
| PATCH | `/api/companies/:id` | 200 OK |
| DELETE | `/api/companies/:id` | 204 No Content |

Boot the server with valid database + Redis running, then test:

```bash
# In one terminal, start the stack:
docker compose up -d sales-db sales-redis
# Wait for health checks (30-60 sec)

# In another terminal:
cd backend && npm run dev:api
```

Then run the verification:

```bash
API_KEY="sk_live_test1234567890"

# Test 1: Create a company (happy path)
curl -X POST http://localhost:3000/api/companies \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"Acme Corp","domain":"acme.com","industry":"SaaS","employeeCount":50}'
# Expected: 201 Created with company object

# Test 2: Get companies list
curl http://localhost:3000/api/companies \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with data array containing Acme

# Test 3: Get single company
COMPANY_ID="..."  # from Test 1
curl http://localhost:3000/api/companies/$COMPANY_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with full company object

# Test 4: Update company (unhappy path - invalid input)
curl -X PATCH http://localhost:3000/api/companies/$COMPANY_ID \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":""}'
# Expected: 400 Validation Error

# Test 5: Get company contacts (empty initially)
curl http://localhost:3000/api/companies/$COMPANY_ID/contacts \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with empty data array

# Test 6: Non-existent company
curl http://localhost:3000/api/companies/00000000-0000-0000-0000-000000000000 \
  -H "Authorization: Bearer $API_KEY"
# Expected: 404 NOT_FOUND

# Test 7: Missing auth header
curl http://localhost:3000/api/companies
# Expected: 401 UNAUTHORIZED

# Test 8: Delete company
curl -X DELETE http://localhost:3000/api/companies/$COMPANY_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 204 No Content

# Test 9: Verify soft-delete (should be gone)
curl http://localhost:3000/api/companies/$COMPANY_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 404 Not Found

# Test 10: Verify DB state
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, name, deleted_at FROM companies ORDER BY created_at DESC LIMIT 5;"
# Expected: Acme Corp row with deleted_at set (not NULL)
```

## Phase C verification checklist

- [ ] POST /api/companies creates company with valid input (201)
- [ ] GET /api/companies lists all non-deleted companies (200)
- [ ] GET /api/companies/:id retrieves single company (200)
- [ ] PATCH /api/companies/:id rejects invalid input -- empty name (400)
- [ ] GET /api/companies/:id/contacts returns empty list initially (200)
- [ ] Non-existent ID returns 404
- [ ] Missing auth returns 401
- [ ] DELETE /api/companies/:id soft-deletes company (204)
- [ ] GET after DELETE returns 404
- [ ] DB reflects all changes (actual PostgreSQL rows, `deleted_at` set)
- [ ] Logs show structured request/response entries

## Commit

```bash
git add backend/src/modules/companies/ tests/unit/companies/
git commit -m "feat: add companies module (schemas, service, routes) with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
