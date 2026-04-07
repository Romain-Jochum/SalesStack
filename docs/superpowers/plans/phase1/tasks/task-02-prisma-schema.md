# Task 02: Prisma Schema

**Depends on:** 01
**Parallel with:** none
**Blocks:** 02.5
**Outputs:** `backend/prisma/schema.prisma`, initial migration
**Verifies:** Schema valid, all models defined, migrations can generate, enums correct
**Estimated context:** ~80 lines

## Intent

Define the complete data model for the Sales Engine, covering both Phase 1 (contacts, companies, segments, campaigns, engagements, opportunities, notes, API keys, webhooks) and Phase 2 (research jobs, data lineage, entity relationships, documents). The schema uses PostgreSQL extensions (pgvector, pg_trgm, btree_gin), enforces tenant isolation via `tenantId` on every model, and maps Prisma field names to snake_case column names. Getting this right early means every subsequent module task builds on a stable, validated foundation.

## Prerequisites check

- Task 01 is complete: `backend/package.json` exists with `prisma` and `@prisma/client` as dependencies.
- `backend/prisma/` directory exists (created during `prisma init` or Task 01 scaffolding).
- `sales-db` container is running and healthy (`docker compose up -d sales-db`).
- `DATABASE_URL` is set in `backend/.env` pointing to the running PostgreSQL instance.

## Steps

### Step 2.1: Copy the Prisma schema

Copy `artifacts/schema.prisma` to `backend/prisma/schema.prisma`, replacing any placeholder schema that may exist from `prisma init`.

```bash
cp docs/superpowers/plan/phase1/artifacts/schema.prisma backend/prisma/schema.prisma
```

The schema defines all Phase 1 and Phase 2 models (~500 lines). Review the artifact to confirm it includes: `Company`, `Contact`, `ContactCompany`, `Tag`, `ContactTag`, `CompanyTag`, `Segment`, `ContactSegmentMembership`, `Campaign`, `CampaignEnrollment`, `EngagementEvent`, `Opportunity`, `Note`, `ApiKey`, `WebhookEvent`, `ResearchJob`, `ResearchSource`, `DataLineage`, `EntityRelationship`, `Document`, and all associated enums (`CampaignStatus`, `CampaignType`, `EngagementEventType`, `WebhookStatus`, `ResearchJobType`, `ResearchJobStatus`).

### Step 2.2: Validate schema

```bash
cd backend && npx prisma validate
```

Expected: `The schema at prisma/schema.prisma is valid`

### Step 2.3: Generate initial migration

```bash
cd backend && npx prisma migrate dev --name initial_schema
```

Expected: `migrations/YYYYMMDD_initial_schema/migration.sql` created, Prisma client generated.

### Step 2.4: Verify Prisma client generation

```bash
cd backend && npx prisma generate
```

Confirm no errors and that `node_modules/.prisma/client` is populated.

## Phase C verification

See `shared/phase-c-template.md` for the general pattern.

Since this task produces no API endpoints, Phase C is limited to database-level verification:

- [ ] `npx prisma validate` exits with success
- [ ] `npx prisma migrate dev --name initial_schema` creates the migration file without errors
- [ ] Connect to `sales-db` and confirm all tables exist:

```bash
docker compose exec sales-db psql -U salesengine -d salesengine -c "\dt"
```

Expected tables: `companies`, `contacts`, `contact_companies`, `tags`, `contact_tags`, `company_tags`, `segments`, `contact_segment_memberships`, `campaigns`, `campaign_enrollments`, `engagement_events`, `opportunities`, `notes`, `api_keys`, `webhook_events`, `research_jobs`, `research_sources`, `data_lineage`, `entity_relationships`, `documents`, `_prisma_migrations`.

- [ ] Verify PostgreSQL extensions are enabled:

```bash
docker compose exec sales-db psql -U salesengine -d salesengine -c "\dx"
```

Expected: `vector`, `pg_trgm`, `btree_gin` listed.

- [ ] Verify enums exist:

```bash
docker compose exec sales-db psql -U salesengine -d salesengine -c "\dT+"
```

Expected: `CampaignStatus`, `CampaignType`, `EngagementEventType`, `WebhookStatus`, `ResearchJobType`, `ResearchJobStatus`.

- [ ] Verify a sample unique constraint is tenant-scoped:

```bash
docker compose exec sales-db psql -U salesengine -d salesengine -c "\d companies" | grep -i unique
```

Expected: unique constraint on `(tenant_id, domain)`.

## Commit

```bash
git add backend/prisma/schema.prisma backend/prisma/migrations/
git commit -m "feat: add Prisma schema with Phase 1 + Phase 2 models"
```
