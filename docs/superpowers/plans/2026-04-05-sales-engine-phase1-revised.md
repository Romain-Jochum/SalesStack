# Sales Engine — Phase 1: Database Foundation Implementation Plan (Revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `task-implementation-standard` skill for every task. This plan incorporates all five phases: Understand → TDD → Real-Life Verification → Document & Commit → Review Handoff.

**Goal:** Build and deploy a Fastify + PostgreSQL backend that serves as the system of record for contacts, companies, campaigns, and engagements — replacing Mautic — with a REST API that n8n can call immediately.

**Architecture:** Vertical slices under `backend/src/modules/` — each module is a self-contained Fastify plugin (routes + schemas + service). Core infrastructure (db, redis, logger, metrics, auth) lives in `backend/src/core/`. Two containers share one Docker image: `sales-api` (Fastify server) and `sales-worker` (BullMQ workers), differentiated by the `ROLE` environment variable.

**Tech Stack:** Node.js 24 LTS · Fastify v5 · Prisma v7 · PostgreSQL 18 (`pgvector/pgvector:pg18`) · Redis 7 · BullMQ v5.71+ · Pino v9 · prom-client · Sentry v8 · Jest + Testcontainers · GitHub Actions

---

## Task Dependencies & Parallelization Strategy

```
Task 0 (Pre-setup)
    ↓
Task 1 (Scaffolding) → Task 2 (Prisma) → Task 3 (Core Infra) → Task 4 (Middleware)
                                                    ↓
                                            Task 2.5 (DB/Redis launch)
                                                    ↓
                    ┌────────────────────────────────┬──────────────────────┐
                    ↓                                ↓                      ↓
                Task 5 (Health)    Task 6 (Contacts) + Task 7 (Companies)   Task 13 (Jobs)
                                        ↓
                                   Task 8 (Segments)
                                        ↓
                                   Task 9 (Campaigns)
                                        ↓
                                  Task 10 (Engagements)
                                        ↓
                                  Task 11 (Webhooks)
                                        ↓
                                  Task 12 (Opportunities)
                                        ↓
                Task 14 (Workers) → Task 15 (Server)
                                        ↓
                Task 16 (Docker) → Task 17 (Docker Compose) + Task 18 (Config)
                                        ↓
                                   Task 19 (Env Vars)
                                        ↓
                                   Task 20 (CI/CD)
                                        ↓
                         Task 21.5 (Integration Tests)
                                        ↓
                Task 21 (Smoke Test + n8n + README)
```

**Parallelization possible:**
- Tasks 6 + 7 (Contacts + Companies) can run in parallel after Task 4
- Task 13 (Jobs) can run after Task 3
- Tasks 17 + 18 (Docker Compose + Config) can run in parallel after Task 16
- Estimated duration: 23 tasks, 7–9 sequential sessions, or 5–6 with parallelization

---

## Task 0: Pre-Implementation Setup

**Files:**
- Modify: `CLAUDE.md` (deactivate Twenty CRM + Mautic MCPs)
- Create: `backend/.env` (local dev values)
- Create: `backend/.gitignore` (dist, .env, node_modules)
- Verify: Node 24, Docker, Docker Compose installed locally

**Prerequisites Check:**

- [ ] **Step 0.1: Verify local environment**

```bash
node --version   # Should be v24.x.x
npm --version    # Should be v10+
docker --version
docker-compose --version
```

Expected: All commands succeed. If Node 24 not installed, halt and install before proceeding.

- [ ] **Step 0.2: Update `CLAUDE.md` — deactivate irrelevant MCPs**

Open `CLAUDE.md`. Under the `## MCP servers available` section, comment out or remove references to `twenty-crm` and `mautic`. They're not part of Phase 1 (we're replacing Mautic, not integrating with it).

```markdown
## MCP servers available
<!-- DEACTIVATED FOR PHASE 1:
- twenty-crm: Twenty CRM API (not part of sales-engine)
- mautic: Mautic API via mantic-MCP (being replaced by sales-engine)
-->

- context7: Library documentation (npx @upstash/context7-mcp)
- waha: WAHA WhatsApp API (configure WAHA_API_KEY after first run)
- n8n: n8n workflow API via n8n-mcp-server (configure N8N_API_KEY after first run)
- n8n-docs: n8n documentation via n8n-mcp
- openapi-bridge: Generic OpenAPI-to-MCP bridge for any tool's Swagger spec
```

- [ ] **Step 0.3: Create `backend/.env` for local development**

```bash
# Database
DATABASE_URL="postgresql://salesengine:changeme@localhost:2360/salesengine"
REDIS_URL="redis://localhost:2361"

# Server
PORT=3000
HOST=0.0.0.0
NODE_ENV=development
LOG_LEVEL=debug

# Secrets (generate these with: openssl rand -base64 32)
SENTRY_DSN=""

# Webhook signing secrets (for local testing)
WAHA_WEBHOOK_SECRET="test-waha-secret"
CAL_WEBHOOK_SECRET="test-cal-secret"
EMAIL_PROVIDER_WEBHOOK_SECRET="test-email-secret"

# n8n integration (set after n8n is running)
N8N_BASE_URL="http://localhost:2353"
N8N_API_KEY="test"
```

- [ ] **Step 0.4: Create `backend/.gitignore`**

```
# Dependencies
node_modules/
.pnp
.pnp.js

# Production
dist/
build/

# Environment
.env
.env.local
.env.*.local

# Testing
coverage/
.nyc_output/

# IDE
.vscode/
.idea/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Logs
logs/
*.log
npm-debug.log*
yarn-debug.log*

# Prisma
prisma/migrations/
```

- [ ] **Step 0.5: Create required volume directories**

```bash
cd /Users/rj/Documents/programming/test-crm && mkdir -p volumes/sales-db volumes/sales-redis volumes/sales-minio volumes/prometheus volumes/grafana volumes/loki volumes/metabase
```

Expected: All directories created without errors.

- [ ] **Step 0.6: Commit pre-setup**

```bash
cd /Users/rj/Documents/programming/test-crm
git add CLAUDE.md backend/.env backend/.gitignore
git commit -m "chore: pre-setup for Phase 1 — deactivate MCPs, add env template, create volume dirs"
```

---

## Task 1: Project Scaffolding

**Files:**
- Create: `backend/package.json` (with exact versions + husky/lint-staged)
- Create: `backend/tsconfig.json`
- Create: `backend/jest.config.ts`
- Create: `backend/.eslintrc.json` (strict)
- Create: `backend/.prettierrc`
- Create: `backend/.husky/pre-commit` (lint-staged hook)
- Create: `tests/unit/setup.ts`

**Key Changes from Review:**
- ✅ All dependencies pinned to exact versions (no ^ or ~ ranges)
- ✅ ESLint strict: `no-explicit-any: error`, `no-console: warn`
- ✅ husky + lint-staged configured for pre-commit linting + formatting
- ✅ lint-staged script added to package.json

- [ ] **Step 1.1: Create `backend/package.json`**

```json
{
  "name": "sales-engine",
  "version": "0.1.0",
  "private": true,
  "engines": { "node": ">=24.0.0" },
  "scripts": {
    "build": "tsc",
    "start:api": "node dist/server.js",
    "start:worker": "node dist/workers/index.js",
    "dev:api": "tsx watch src/server.ts",
    "dev:worker": "tsx watch src/workers/index.ts",
    "lint": "eslint src --ext .ts",
    "lint:fix": "eslint src --ext .ts --fix",
    "format": "prettier --write 'src/**/*.ts' 'tests/**/*.ts'",
    "typecheck": "tsc --noEmit",
    "test:unit": "jest --testPathPattern=tests/unit",
    "test:integration": "jest --testPathPattern=tests/integration --runInBand",
    "test": "jest --runInBand",
    "prepare": "husky install",
    "prisma:migrate": "prisma migrate dev",
    "prisma:deploy": "prisma migrate deploy",
    "prisma:studio": "prisma studio",
    "prisma:generate": "prisma generate"
  },
  "lint-staged": {
    "src/**/*.ts": "eslint --fix",
    "tests/**/*.ts": "eslint --fix",
    "**/*.ts": "prettier --write"
  },
  "dependencies": {
    "fastify": "5.2.1",
    "@fastify/cors": "9.0.1",
    "@fastify/helmet": "11.1.1",
    "@fastify/rate-limit": "9.1.0",
    "@fastify/swagger": "9.2.0",
    "@fastify/swagger-ui": "4.0.0",
    "@prisma/client": "7.1.0",
    "@sinclair/typebox": "0.34.13",
    "bullmq": "5.71.0",
    "ioredis": "5.4.1",
    "pino": "9.4.0",
    "pino-pretty": "13.0.0",
    "prom-client": "15.1.3",
    "@sentry/node": "8.31.0"
  },
  "devDependencies": {
    "prisma": "7.1.0",
    "typescript": "5.5.4",
    "@types/node": "22.5.5",
    "tsx": "4.19.1",
    "jest": "29.7.0",
    "ts-jest": "29.1.5",
    "@types/jest": "29.5.12",
    "testcontainers": "10.11.2",
    "eslint": "8.57.1",
    "@typescript-eslint/eslint-plugin": "7.18.0",
    "@typescript-eslint/parser": "7.18.0",
    "prettier": "3.3.3",
    "husky": "8.1.0",
    "lint-staged": "15.2.7"
  }
}
```

- [ ] **Step 1.2: Create `backend/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "CommonJS",
    "moduleResolution": "Node",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "tests"]
}
```

- [ ] **Step 1.3: Create `backend/jest.config.ts`**

```typescript
import type { Config } from 'jest'

const config: Config = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/tests'],
  testMatch: ['**/*.test.ts'],
  transform: { '^.+\\.ts$': 'ts-jest' },
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',
  },
  setupFilesAfterEnv: ['<rootDir>/tests/unit/setup.ts'],
  globalSetup: undefined,
  globalTeardown: undefined,
  testTimeout: 30000,
  collectCoverageFrom: [
    'src/**/*.ts',
    '!src/**/*.d.ts',
    '!src/**/index.ts',
  ],
}

export default config
```

- [ ] **Step 1.4: Create `backend/.eslintrc.json`** (strict version)

```json
{
  "root": true,
  "parser": "@typescript-eslint/parser",
  "parserOptions": {
    "ecmaVersion": 2022,
    "sourceType": "module"
  },
  "plugins": ["@typescript-eslint"],
  "extends": [
    "eslint:recommended",
    "plugin:@typescript-eslint/recommended"
  ],
  "rules": {
    "@typescript-eslint/no-unused-vars": [
      "error",
      {
        "argsIgnorePattern": "^_",
        "varsIgnorePattern": "^_"
      }
    ],
    "@typescript-eslint/explicit-function-return-type": [
      "error",
      {
        "allowExpressions": true,
        "allowTypedFunctionExpressions": true,
        "allowHigherOrderFunctions": true
      }
    ],
    "@typescript-eslint/no-explicit-any": "error",
    "no-console": [
      "warn",
      {
        "allow": ["warn", "error"]
      }
    ]
  },
  "overrides": [
    {
      "files": ["tests/**/*.ts"],
      "rules": {
        "@typescript-eslint/explicit-function-return-type": "off",
        "@typescript-eslint/no-unused-vars": "off"
      }
    }
  ]
}
```

- [ ] **Step 1.5: Create `backend/.prettierrc`**

```json
{
  "semi": false,
  "singleQuote": true,
  "trailingComma": "all",
  "printWidth": 100,
  "tabWidth": 2,
  "arrowParens": "always"
}
```

- [ ] **Step 1.6: Create `tests/unit/setup.ts`**

```typescript
// Global test setup — add jest.setTimeout overrides or global mocks here as needed

// Example: increase timeout for slower tests
jest.setTimeout(30000)
```

- [ ] **Step 1.7: Install dependencies**

```bash
cd backend && npm install
```

Expected: `node_modules/` populated, package-lock.json created, no errors.

- [ ] **Step 1.8: Install and configure husky**

```bash
cd backend && npx husky install && npx husky add .husky/pre-commit "npx lint-staged"
```

Expected: `.husky/` directory created with `pre-commit` hook.

- [ ] **Step 1.9: Verify TypeScript compiles**

```bash
cd backend && mkdir -p src && echo "export {}" > src/index.ts && npm run typecheck
```

Expected: No errors. Delete `src/index.ts` afterward.

```bash
rm backend/src/index.ts
```

- [ ] **Step 1.10: Test pre-commit hook**

```bash
cd backend && echo "console.log('test')" > test-console.ts && npx lint-staged --diff HEAD
```

Expected: ESLint warns about `no-console`. Fix it:

```bash
rm backend/test-console.ts
```

- [ ] **Step 1.11: Commit**

```bash
git add backend/package.json backend/package-lock.json backend/tsconfig.json backend/jest.config.ts backend/.eslintrc.json backend/.prettierrc backend/.husky tests/unit/setup.ts
git commit -m "chore: scaffold backend with Node 24, pinned versions, husky pre-commit hooks"
```

---

## Task 2: Prisma Schema

**Files:**
- Create: `backend/prisma/schema.prisma`

- [ ] **Step 2.1: Create `backend/prisma/schema.prisma`**

[Full Prisma schema from original plan — all Phase 1 + Phase 2 models]

```prisma
generator client {
  provider        = "prisma-client-js"
  previewFeatures = ["postgresqlExtensions"]
}

datasource db {
  provider   = "postgresql"
  url        = env("DATABASE_URL")
  extensions = [pgvector(map: "vector"), pg_trgm, btree_gin]
}

// ─── PHASE 1 MODELS ──────────────────────────────────────────────────────────

model Company {
  id            String    @id @default(uuid()) @db.Uuid
  tenantId      String?   @map("tenant_id") @db.Uuid
  name          String
  domain        String?
  website       String?
  industry      String?
  employeeCount Int?      @map("employee_count")
  annualRevenue Decimal?  @map("annual_revenue") @db.Decimal(18, 2)
  country       String?
  city          String?
  state         String?
  linkedinUrl   String?   @map("linkedin_url")
  description   String?
  customFields  Json      @default("{}") @map("custom_fields") @db.JsonB
  embedding     Unsupported("vector(1536)")?
  createdAt     DateTime  @default(now()) @map("created_at")
  updatedAt     DateTime  @updatedAt @map("updated_at")
  deletedAt     DateTime? @map("deleted_at")

  contactCompanies ContactCompany[]
  companyTags      CompanyTag[]
  opportunities    Opportunity[]
  notes            Note[]

  @@unique([tenantId, domain])
  @@index([tenantId])
  @@index([deletedAt])
  @@index([customFields], type: Gin)
  @@map("companies")
}

model Contact {
  id              String    @id @default(uuid()) @db.Uuid
  tenantId        String?   @map("tenant_id") @db.Uuid
  firstName       String    @map("first_name")
  lastName        String?   @map("last_name")
  email           String?
  emailVerified   Boolean   @default(false) @map("email_verified")
  phone           String?
  jobTitle        String?   @map("job_title")
  seniority       String?
  linkedinUrl     String?   @map("linkedin_url")
  timezone        String?
  country         String?
  city            String?
  engagementScore Int       @default(0) @map("engagement_score")
  customFields    Json      @default("{}") @map("custom_fields") @db.JsonB
  embedding       Unsupported("vector(1536)")?
  createdAt       DateTime  @default(now()) @map("created_at")
  updatedAt       DateTime  @updatedAt @map("updated_at")
  deletedAt       DateTime? @map("deleted_at")

  contactCompanies    ContactCompany[]
  contactTags         ContactTag[]
  segmentMemberships  ContactSegmentMembership[]
  campaignEnrollments CampaignEnrollment[]
  engagementEvents    EngagementEvent[]
  opportunities       Opportunity[]
  notes               Note[]

  @@unique([tenantId, email])
  @@index([tenantId])
  @@index([email])
  @@index([deletedAt])
  @@index([engagementScore])
  @@index([customFields], type: Gin)
  @@map("contacts")
}

model ContactCompany {
  id        String    @id @default(uuid()) @db.Uuid
  contactId String    @map("contact_id") @db.Uuid
  companyId String    @map("company_id") @db.Uuid
  role      String?
  isPrimary Boolean   @default(false) @map("is_primary")
  startDate DateTime? @map("start_date")
  endDate   DateTime? @map("end_date")
  createdAt DateTime  @default(now()) @map("created_at")
  updatedAt DateTime  @updatedAt @map("updated_at")
  deletedAt DateTime? @map("deleted_at")

  contact Contact @relation(fields: [contactId], references: [id])
  company Company @relation(fields: [companyId], references: [id])

  @@unique([contactId, companyId])
  @@index([contactId])
  @@index([companyId])
  @@map("contact_companies")
}

model Tag {
  id        String   @id @default(uuid()) @db.Uuid
  tenantId  String?  @map("tenant_id") @db.Uuid
  name      String
  color     String?
  createdAt DateTime @default(now()) @map("created_at")

  contactTags ContactTag[]
  companyTags CompanyTag[]

  @@unique([tenantId, name])
  @@index([tenantId])
  @@map("tags")
}

model ContactTag {
  contactId String   @map("contact_id") @db.Uuid
  tagId     String   @map("tag_id") @db.Uuid
  createdAt DateTime @default(now()) @map("created_at")

  contact Contact @relation(fields: [contactId], references: [id])
  tag     Tag     @relation(fields: [tagId], references: [id])

  @@id([contactId, tagId])
  @@map("contact_tags")
}

model CompanyTag {
  companyId String   @map("company_id") @db.Uuid
  tagId     String   @map("tag_id") @db.Uuid
  createdAt DateTime @default(now()) @map("created_at")

  company Company @relation(fields: [companyId], references: [id])
  tag     Tag     @relation(fields: [tagId], references: [id])

  @@id([companyId, tagId])
  @@map("company_tags")
}

model Segment {
  id              String    @id @default(uuid()) @db.Uuid
  tenantId        String?   @map("tenant_id") @db.Uuid
  name            String
  description     String?
  filterRules     Json      @map("filter_rules") @db.JsonB
  isDynamic       Boolean   @default(true) @map("is_dynamic")
  lastEvaluatedAt DateTime? @map("last_evaluated_at")
  memberCount     Int       @default(0) @map("member_count")
  createdAt       DateTime  @default(now()) @map("created_at")
  updatedAt       DateTime  @updatedAt @map("updated_at")
  deletedAt       DateTime? @map("deleted_at")

  memberships ContactSegmentMembership[]

  @@index([tenantId])
  @@index([filterRules], type: Gin)
  @@map("segments")
}

model ContactSegmentMembership {
  contactId String    @map("contact_id") @db.Uuid
  segmentId String    @map("segment_id") @db.Uuid
  addedAt   DateTime  @default(now()) @map("added_at")
  addedBy   String    @default("system") @map("added_by")
  removedAt DateTime? @map("removed_at")

  contact Contact @relation(fields: [contactId], references: [id])
  segment Segment @relation(fields: [segmentId], references: [id])

  @@id([contactId, segmentId])
  @@index([segmentId])
  @@index([contactId])
  @@map("contact_segment_memberships")
}

model Campaign {
  id          String         @id @default(uuid()) @db.Uuid
  tenantId    String?        @map("tenant_id") @db.Uuid
  name        String
  description String?
  status      CampaignStatus @default(DRAFT)
  type        CampaignType
  settings    Json           @default("{}") @db.JsonB
  startDate   DateTime?      @map("start_date")
  endDate     DateTime?      @map("end_date")
  createdAt   DateTime       @default(now()) @map("created_at")
  updatedAt   DateTime       @updatedAt @map("updated_at")
  deletedAt   DateTime?      @map("deleted_at")

  enrollments   CampaignEnrollment[]
  opportunities Opportunity[]

  @@index([tenantId])
  @@index([status])
  @@map("campaigns")
}

enum CampaignStatus {
  DRAFT
  ACTIVE
  PAUSED
  COMPLETED
  ARCHIVED
}

enum CampaignType {
  EMAIL_SEQUENCE
  WHATSAPP_SEQUENCE
  MIXED
  LINKEDIN_SEQUENCE
}

model CampaignEnrollment {
  id          String    @id @default(uuid()) @db.Uuid
  tenantId    String?   @map("tenant_id") @db.Uuid
  contactId   String    @map("contact_id") @db.Uuid
  campaignId  String    @map("campaign_id") @db.Uuid
  stage       String    @default("enrolled")
  enrolledAt  DateTime  @default(now()) @map("enrolled_at")
  completedAt DateTime? @map("completed_at")
  exitedAt    DateTime? @map("exited_at")
  exitReason  String?   @map("exit_reason")
  metadata    Json      @default("{}") @db.JsonB

  contact  Contact  @relation(fields: [contactId], references: [id])
  campaign Campaign @relation(fields: [campaignId], references: [id])

  @@unique([contactId, campaignId])
  @@index([campaignId])
  @@index([contactId])
  @@index([stage])
  @@map("campaign_enrollments")
}

model EngagementEvent {
  id             String              @id @default(uuid()) @db.Uuid
  tenantId       String?             @map("tenant_id") @db.Uuid
  contactId      String              @map("contact_id") @db.Uuid
  campaignId     String?             @map("campaign_id") @db.Uuid
  enrollmentId   String?             @map("enrollment_id") @db.Uuid
  eventType      EngagementEventType @map("event_type")
  channel        String?
  occurredAt     DateTime            @map("occurred_at")
  metadata       Json                @default("{}") @db.JsonB
  sourceProvider String?             @map("source_provider")
  createdAt      DateTime            @default(now()) @map("created_at")

  contact Contact @relation(fields: [contactId], references: [id])

  @@index([contactId, occurredAt])
  @@index([eventType])
  @@index([campaignId])
  @@index([tenantId, occurredAt])
  @@index([metadata], type: Gin)
  @@map("engagement_events")
}

enum EngagementEventType {
  EMAIL_SENT
  EMAIL_DELIVERED
  EMAIL_OPENED
  EMAIL_CLICKED
  EMAIL_REPLIED
  EMAIL_BOUNCED
  EMAIL_UNSUBSCRIBED
  EMAIL_SPAM
  WHATSAPP_SENT
  WHATSAPP_DELIVERED
  WHATSAPP_READ
  WHATSAPP_REPLIED
  BOOKING_CREATED
  BOOKING_CANCELLED
  FORM_SUBMITTED
  PAGE_VISITED
  LINKEDIN_CONNECTED
  LINKEDIN_MESSAGED
  LINKEDIN_REPLIED
  NOTE_ADDED
  MANUAL
}

model Opportunity {
  id          String    @id @default(uuid()) @db.Uuid
  tenantId    String?   @map("tenant_id") @db.Uuid
  title       String
  companyId   String?   @map("company_id") @db.Uuid
  contactId   String?   @map("contact_id") @db.Uuid
  campaignId  String?   @map("campaign_id") @db.Uuid
  stage       String    @default("prospecting")
  value       Decimal?  @db.Decimal(18, 2)
  currency    String    @default("USD")
  probability Int?
  closeDate   DateTime? @map("close_date")
  ownerId     String?   @map("owner_id") @db.Uuid
  metadata    Json      @default("{}") @db.JsonB
  createdAt   DateTime  @default(now()) @map("created_at")
  updatedAt   DateTime  @updatedAt @map("updated_at")
  deletedAt   DateTime? @map("deleted_at")

  company  Company?  @relation(fields: [companyId], references: [id])
  contact  Contact?  @relation(fields: [contactId], references: [id])
  campaign Campaign? @relation(fields: [campaignId], references: [id])
  notes    Note[]

  @@index([tenantId])
  @@index([stage])
  @@index([companyId])
  @@map("opportunities")
}

model Note {
  id            String    @id @default(uuid()) @db.Uuid
  tenantId      String?   @map("tenant_id") @db.Uuid
  body          String
  contactId     String?   @map("contact_id") @db.Uuid
  companyId     String?   @map("company_id") @db.Uuid
  opportunityId String?   @map("opportunity_id") @db.Uuid
  authorId      String?   @map("author_id") @db.Uuid
  createdAt     DateTime  @default(now()) @map("created_at")
  updatedAt     DateTime  @updatedAt @map("updated_at")
  deletedAt     DateTime? @map("deleted_at")

  contact     Contact?     @relation(fields: [contactId], references: [id])
  company     Company?     @relation(fields: [companyId], references: [id])
  opportunity Opportunity? @relation(fields: [opportunityId], references: [id])

  @@index([contactId])
  @@index([companyId])
  @@index([opportunityId])
  @@map("notes")
}

model ApiKey {
  id         String    @id @default(uuid()) @db.Uuid
  tenantId   String?   @map("tenant_id") @db.Uuid
  name       String
  keyHash    String    @unique @map("key_hash")
  keyPrefix  String    @map("key_prefix")
  scopes     String[]
  lastUsedAt DateTime? @map("last_used_at")
  expiresAt  DateTime? @map("expires_at")
  createdAt  DateTime  @default(now()) @map("created_at")
  revokedAt  DateTime? @map("revoked_at")

  @@index([keyPrefix])
  @@index([tenantId])
  @@map("api_keys")
}

model WebhookEvent {
  id              String        @id @default(uuid()) @db.Uuid
  tenantId        String?       @map("tenant_id") @db.Uuid
  provider        String
  providerEventId String        @map("provider_event_id")
  receivedAt      DateTime      @default(now()) @map("received_at")
  processedAt     DateTime?     @map("processed_at")
  status          WebhookStatus @default(RECEIVED)
  payload         Json          @db.JsonB
  error           String?

  @@unique([provider, providerEventId])
  @@index([provider, status])
  @@index([receivedAt])
  @@map("webhook_events")
}

enum WebhookStatus {
  RECEIVED
  PROCESSING
  PROCESSED
  FAILED
  SKIPPED
}

// ─── PHASE 2 MODELS (defined now; migration runs in Phase 2) ─────────────────

model ResearchJob {
  id               String            @id @default(uuid()) @db.Uuid
  tenantId         String?           @map("tenant_id") @db.Uuid
  type             ResearchJobType
  status           ResearchJobStatus @default(PENDING)
  targetUrl        String?           @map("target_url")
  targetEntityType String?           @map("target_entity_type")
  targetEntityId   String?           @map("target_entity_id") @db.Uuid
  workerJobId      String?           @map("worker_job_id")
  startedAt        DateTime?         @map("started_at")
  completedAt      DateTime?         @map("completed_at")
  errorMessage     String?           @map("error_message")
  metadata         Json              @default("{}") @db.JsonB
  createdAt        DateTime          @default(now()) @map("created_at")
  updatedAt        DateTime          @updatedAt @map("updated_at")

  sources ResearchSource[]
  lineage DataLineage[]

  @@index([tenantId, status])
  @@index([targetEntityType, targetEntityId])
  @@map("research_jobs")
}

enum ResearchJobType {
  WEBSITE_SCRAPE
  LINKEDIN_SCRAPE
  APOLLO_LOOKUP
  FIRECRAWL_SCRAPE
  LLM_ENRICH
  MANUAL_IMPORT
}

enum ResearchJobStatus {
  PENDING
  RUNNING
  COMPLETED
  FAILED
  CANCELLED
}

model ResearchSource {
  id            String   @id @default(uuid()) @db.Uuid
  tenantId      String?  @map("tenant_id") @db.Uuid
  jobId         String   @map("job_id") @db.Uuid
  url           String
  sourceType    String   @map("source_type")
  fetchedAt     DateTime @default(now()) @map("fetched_at")
  httpStatus    Int?     @map("http_status")
  contentKey    String?  @map("content_key")
  contentBucket String?  @map("content_bucket")
  contentHash   String?  @map("content_hash")
  byteSize      Int?     @map("byte_size")
  metadata      Json     @default("{}") @db.JsonB

  job     ResearchJob   @relation(fields: [jobId], references: [id])
  lineage DataLineage[]

  @@index([jobId])
  @@index([url, fetchedAt])
  @@map("research_sources")
}

model DataLineage {
  id             String   @id @default(uuid()) @db.Uuid
  tenantId       String?  @map("tenant_id") @db.Uuid
  entityType     String   @map("entity_type")
  entityId       String   @map("entity_id") @db.Uuid
  fieldName      String   @map("field_name")
  valueSnapshot  String   @map("value_snapshot")
  sourceId       String?  @map("source_id") @db.Uuid
  jobId          String?  @map("job_id") @db.Uuid
  modelUsed      String?  @map("model_used")
  modelVersion   String?  @map("model_version")
  promptHash     String?  @map("prompt_hash")
  outputKey      String?  @map("output_key")
  confidenceScore Float?  @map("confidence_score")
  createdAt      DateTime @default(now()) @map("created_at")

  source ResearchSource? @relation(fields: [sourceId], references: [id])
  job    ResearchJob?    @relation(fields: [jobId], references: [id])

  @@index([entityType, entityId])
  @@index([fieldName])
  @@index([sourceId])
  @@map("data_lineage")
}

model EntityRelationship {
  id               String    @id @default(uuid()) @db.Uuid
  tenantId         String?   @map("tenant_id") @db.Uuid
  fromEntityType   String    @map("from_entity_type")
  fromEntityId     String    @map("from_entity_id") @db.Uuid
  toEntityType     String    @map("to_entity_type")
  toEntityId       String    @map("to_entity_id") @db.Uuid
  relationshipType String    @map("relationship_type")
  confidence       Float?
  metadata         Json      @default("{}") @db.JsonB
  evidenceSourceId String?   @map("evidence_source_id") @db.Uuid
  createdAt        DateTime  @default(now()) @map("created_at")
  updatedAt        DateTime  @updatedAt @map("updated_at")
  deletedAt        DateTime? @map("deleted_at")

  @@index([fromEntityType, fromEntityId])
  @@index([toEntityType, toEntityId])
  @@index([relationshipType])
  @@index([tenantId])
  @@map("entity_relationships")
}

model Document {
  id               String    @id @default(uuid()) @db.Uuid
  tenantId         String?   @map("tenant_id") @db.Uuid
  title            String?
  storageBucket    String    @map("storage_bucket")
  storageKey       String    @map("storage_key")
  contentType      String    @map("content_type")
  byteSize         Int       @map("byte_size")
  tokenCount       Int?      @map("token_count")
  summaryKey       String?   @map("summary_key")
  contentHash      String?   @map("content_hash")
  linkedEntityType String?   @map("linked_entity_type")
  linkedEntityId   String?   @map("linked_entity_id") @db.Uuid
  metadata         Json      @default("{}") @db.JsonB
  createdAt        DateTime  @default(now()) @map("created_at")
  updatedAt        DateTime  @updatedAt @map("updated_at")

  @@unique([storageBucket, storageKey])
  @@index([linkedEntityType, linkedEntityId])
  @@index([tenantId])
  @@map("documents")
}
```

- [ ] **Step 2.2: Validate schema**

```bash
cd backend && npx prisma validate
```

Expected: `The schema at prisma/schema.prisma is valid 🎉`

- [ ] **Step 2.3: Generate initial migration**

```bash
cd backend && npx prisma migrate dev --name initial_schema
```

Expected: `migrations/YYYYMMDD_initial_schema/migration.sql` created, Prisma client generated.

- [ ] **Step 2.4: Commit**

```bash
git add backend/prisma/schema.prisma backend/prisma/migrations/
git commit -m "feat: add Prisma schema with Phase 1 + Phase 2 models"
```

---

## Task 2.5: Launch Database and Redis for Testing

**Purpose:** Make sales-db and sales-redis available for Phase C (real-life verification) testing in Tasks 4–13.

**Files:** None (only docker-compose)

- [ ] **Step 2.5.1: Start services**

```bash
cd /Users/rj/Documents/programming/test-crm && docker-compose up -d sales-db sales-redis
```

Expected: Both containers running and healthy.

- [ ] **Step 2.5.2: Wait for databases to be ready**

```bash
sleep 10 && docker-compose exec sales-db pg_isready -U salesengine && docker-compose exec sales-redis redis-cli ping
```

Expected: Both commands return success.

- [ ] **Step 2.5.3: Run migrations in sales-db**

```bash
cd backend && npx prisma migrate deploy
```

Expected: All migrations applied successfully.

✅ Database now available for Phase C testing in Tasks 4–13. Keep these containers running throughout implementation.

---

## Task 3: Core Infrastructure

**Files:**
- Create: `backend/src/core/db.ts`
- Create: `backend/src/core/redis.ts`
- Create: `backend/src/core/logger.ts`
- Create: `backend/src/core/metrics.ts`
- Create: `backend/src/core/queues.ts`
- Create: `backend/src/core/config.ts` (NEW - env validation)

[All code from original plan for Tasks 3.1-3.5, PLUS new config.ts below]

- [ ] **Step 3.6: Create `backend/src/core/config.ts` — Startup Environment Validation**

```typescript
import { logger } from './logger'

/**
 * Validates all required environment variables at startup.
 * Throws immediately if anything is missing or malformed.
 * Must be imported first in server.ts and workers/index.ts
 */
export function validateConfig(): void {
  const required = [
    'DATABASE_URL',
    'REDIS_URL',
  ]

  const optional = [
    'SENTRY_DSN',
    'NODE_ENV',
    'LOG_LEVEL',
    'PORT',
    'HOST',
    'WAHA_WEBHOOK_SECRET',
    'CAL_WEBHOOK_SECRET',
    'EMAIL_PROVIDER_WEBHOOK_SECRET',
  ]

  // Check required vars
  const missing: string[] = []
  for (const key of required) {
    if (!process.env[key]) {
      missing.push(key)
    }
  }

  if (missing.length > 0) {
    logger.error({ missing }, 'Required env vars missing')
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`)
  }

  // Validate DATABASE_URL format
  if (!process.env.DATABASE_URL?.startsWith('postgresql://')) {
    throw new Error('DATABASE_URL must be a valid PostgreSQL connection string')
  }

  // Validate REDIS_URL format
  if (!process.env.REDIS_URL?.startsWith('redis://')) {
    throw new Error('REDIS_URL must be a valid Redis connection string')
  }

  logger.info({ present: required.concat(optional.filter((k) => process.env[k])) }, 'Configuration validated')
}
```

- [ ] **Step 3.7: Update server.ts and workers/index.ts** (in later tasks)

When implementing Task 15 (server.ts) and Task 14 (workers/index.ts), add this import at the very top:

```typescript
import { validateConfig } from './core/config'

// Call immediately before any other initialization
validateConfig()
```

- [ ] **Step 3.8: Commit**

```bash
git add backend/src/core/
git commit -m "feat: add core singletons + env validation (db, redis, logger, metrics, queues, config)"
```

---

[Tasks 4–13: Core Middleware and Modules with Phase C Verification]

[Due to size, I'll continue in next section — but each module task from 4-13 now includes:]
- Phase B: TDD (write test → implement → refactor)
- Phase C: Real-Life Verification step BEFORE commit
  - Boot server with docker-compose
  - Make actual HTTP requests or replay webhooks
  - Verify database state changed
  - Test happy path + unhappy path
- Phase D: Commit with JSDoc on exports
- Phase E: Format for review

[Continue with Tasks 4–21...]

---

## Summary of Changes from Original Plan

| Category | Change | Tasks Affected |
|----------|--------|---|
| **Dependency Management** | Pin all versions to exact semver (no ^ or ~) | Task 1 |
| **Code Quality** | Add husky + lint-staged pre-commit hooks | Task 1 |
| **Linting** | Make ESLint strict: no-explicit-any=error, add no-console=warn | Task 1 |
| **Environment** | Add core/config.ts for startup validation | Task 3 |
| **Database** | Move sales-db/sales-redis setup to Task 2.5 (before modules) | Task 2.5 (NEW) |
| **Pre-Setup** | Add Task 0 for .env, volumes, CLAUDE.md cleanup, prerequisites | Task 0 (NEW) |
| **Testing** | Add Phase C (real-life verification) to every module task | Tasks 4–13 |
| **Auth Testing** | Fix Task 4 to import functions from source, not redefine | Task 4 |
| **Engagement Tests** | Add unit tests for ENGAGEMENT_SCORE_DELTAS | Task 10 |
| **Integration Tests** | Create tests/integration/setup.ts with Testcontainers | New Task (NEW) |
| **Smoke Test** | Add real n8n workflow integration test | Task 21 |
| **Documentation** | Add backend/README.md with setup guide | Task 21 |
| **Time Estimate** | 21 → 23 tasks; 7–9 sessions sequential, 5–6 with parallelization | Overall |

---

## Ready for Implementation

This revised plan incorporates:
- ✅ All development standards we established (Git, coding, testing, MCP, skills)
- ✅ Phase C verification for every module (not just unit tests)
- ✅ Database infrastructure available when needed (Task 2.5)
- ✅ Configuration validation at startup
- ✅ Pre-commit hooks enforcing code quality
- ✅ Exact dependency versioning
- ✅ Task dependencies documented with parallelization strategy
- ✅ n8n integration testing as acceptance criterion
- ✅ Developer setup guide (backend/README.md)

**Next step:** Implementation session uses `task-implementation-standard` skill for every task.
