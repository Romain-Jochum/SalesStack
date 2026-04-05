# Sales Engine — Phase 2 & 3 Architecture Brief

## Problem Statement

**Phase 1** (Database Foundation): Provides a unified backend for outreach — contacts, companies, campaigns, webhooks, and engagement scoring. Replaces Mautic as the system of record. Enables n8n to orchestrate multi-channel campaigns.

**Phase 2** (Research Engine): Enriches contact and company data at scale. Scrapes websites, queries LinkedIn/Apollo, parses signals, and runs LLM enrichment. Every field change is tracked: "where did we learn this company has 500 employees? From a LinkedIn scrape on 2026-04-10, parsed with gpt-4, confidence 0.85."

**Phase 3** (Agentic Outreach): LLM-driven orchestration. Signals from Phase 2 (e.g., "VP of Sales just joined competitor") trigger agentic decision-making: "should we reach out? via which channel? what message?" The agent writes back to n8n, which executes the campaign.

**Core Principle:** Contact and company data should never be a guess. Every field is traceable to a source — a scraped URL, an LLM model, a confidence score, and a timestamp.

---

## Phase 2: Research Engine

### Architecture Overview

Three-stage pipeline orchestrated by BullMQ FlowProducers:

```
ResearchJob (parent)
├── SCRAPE job (child 1)
│   └── FireCrawl / custom scraper → raw HTML → MinIO → pointer
├── PARSE job (child 2)
│   └── Convert HTML → markdown/JSON → MinIO → pointer
└── ENRICH job (child 3)
    └── LLM extract signals (decision makers, revenue, intent) → DataLineage
```

**Why FlowProducers?**
- **Dependency graph:** You cannot enrich what you haven't parsed. Parent job waits for all children.
- **Atomic failure:** If PARSE fails, ENRICH never runs. Job stays in FAILED state until manually retried.
- **Visibility:** One `ResearchJob` ID shows the entire pipeline state. No table joins to understand where a job stalled.
- **Redis safety:** Each job's data is a MinIO pointer (~100 bytes), not the raw HTML (10–100KB). Scales to 10K+ concurrent jobs without bloating Redis.

### Phase 2 Modules

**research-jobs** (`backend/src/modules/research-jobs/`)
- CRUD endpoints: `POST /api/research-jobs` (creates ResearchJob + dispatches FlowProducer)
- Status tracking: `GET /api/research-jobs/:id` (shows PENDING → SCRAPE → PARSE → ENRICH → COMPLETED)
- Target types: contact, company, URL (for custom research)
- Ties into segments: "re-research all contacts in 'Active Targets' segment monthly"

**sources** (`backend/src/modules/sources/`)
- Manages `ResearchSource` records (URL + fetch metadata + MinIO pointers)
- MinIO integration: Upload HTML → get key/bucket → store pointer in DB
- Content retrieval: GET `/api/sources/:id/content` streams from MinIO
- Audit: `fetchedAt`, `httpStatus`, `contentHash` enable deduplication and change tracking

**lineage** (`backend/src/modules/lineage/`)
- Read-only API: `GET /api/lineage?entityType=contact&entityId=X&fieldName=jobTitle`
- Answer: "why does Alice have jobTitle = 'VP Sales'?" → returns ResearchSource + confidence + timestamp
- Critical for trust: "this field came from a LinkedIn scrape with 0.92 confidence" vs. "this field came from a MANUAL_IMPORT"
- Supports audit logs: "our CRM says Alice is a Director, but lineage says she's actually a VP — flag for human review"

**entities** (`backend/src/modules/entities/`)
- Tracks relationships: contact → company, company → competitor, contact → decision-maker
- Queryable graph: "show me all VP-level contacts at companies in the SaaS industry"
- Confidence scoring: relationships from a "LINKEDIN_SCRAPE" have higher confidence than "MANUAL_IMPORT"
- Foundation for Phase 3 account-based orchestration

### Phase 2 Infrastructure

**MinIO Service** (in docker-compose under `phase2` profile)
- Started with: `docker compose --profile phase2 up`
- Stores: raw HTML, parsed content, LLM outputs, embeddings (future)
- Buckets: `raw-content`, `parsed-content`, `embeddings`
- Lifecycle: files auto-expire after 90 days (configurable)
- Backup: operator responsibility; recommend backing up `volumes/sales-minio` to external storage

**Research Queues** (in `core/queues.ts`)
- `queue:research:scrape` — Fetch raw content from URLs
- `queue:research:parse` — Parse HTML/JSON into structured fields
- `queue:research:enrich` — LLM extraction + confidence scoring

**FlowProducer** (new in Phase 2: `core/flows.ts`)
- Instantiated in `workers/index.ts` alongside webhook + segment workers
- Registers flow templates: scrape-parse-enrich pipeline

### Database Forward-Compatibility

Five Phase 2 models are already defined in the Prisma schema (Phase 1):
- `research_jobs` — parent job records
- `research_sources` — scraped URLs + MinIO pointers
- `data_lineage` — every field change (entity + field + source + model + confidence)
- `entity_relationships` — connection graph
- `documents` — related files/PDFs linked to contacts/companies

The Phase 1 initial migration includes all five tables. During Phase 2 implementation, these tables already exist — no blocking migration. Phase 2 just needs:
1. API routes (CRUD for research-jobs, read for lineage)
2. Worker implementations (scrape, parse, enrich)
3. MinIO integration code

---

## Phase 3: Agentic Outreach (Vision)

Not planned for immediate implementation, but documented here so the Phase 2 foundation is built with Phase 3 in mind.

### Architecture

**Agentic Decision Loop**
```
ResearchJob COMPLETED
    ↓
DataLineage written (new intent signals)
    ↓
Contact's segment membership changes (algorithm-driven)
    ↓
Trigger: "VP of Sales just joined; engagement score +50"
    ↓
LLM Agent: "Should we reach out? Via email or LinkedIn?"
    ↓
Dispatch to n8n workflow (agent writes decision)
    ↓
n8n executes: send email, log engagement, schedule follow-up
```

**Agent Inputs**
- Engagement score (Phase 1)
- Last 5 events (Phase 1)
- Research-derived signals: "newly hired", "company just raised funding", "competitor monitoring" (Phase 2)
- Custom rules: "never cold outreach on Fridays", "prioritize companies in CA" (config)

**Agent Outputs**
- Decision: `{ action: 'email', template: 'value-prop-vp', delay: '2h' }`
- n8n webhook call with decision
- Logged as engagement event (Phase 1 EngagementEvent)

### Why Phase 3 Matters

Phase 1 + 2 give you a data pipeline. Phase 3 closes the loop: data → decision → execution → feedback. Without Phase 3, enriched data sits unused.

---

## Threat Model: Data Provenance

> **Never lose track of where a contact field came from.**

### The Rule
Every field update on a contact or company during enrichment MUST be paired with a `DataLineage` record:

```typescript
// BAD: don't do this
await db.contact.update({ where: { id }, data: { jobTitle: 'VP Sales' } })

// GOOD: do this
const result = await db.contact.update({ where: { id }, data: { jobTitle: 'VP Sales' } })
await db.dataLineage.create({
  entityType: 'contact',
  entityId: id,
  fieldName: 'jobTitle',
  valueSnapshot: 'VP Sales',
  sourceId: research_source_id,     // which URL did we scrape?
  jobId: research_job_id,           // which job wrote this?
  modelUsed: 'gpt-4',               // which LLM extracted it?
  modelVersion: '2026-03-15',
  promptHash: sha256(prompt),       // reproducibility: can we re-run the same prompt?
  confidenceScore: 0.92,            // how confident are we?
})
```

### Why This Matters

1. **Debugging:** "Alice's jobTitle says 'VP Sales' but our LinkedIn data says 'Director' — which is right?" Answer: check DataLineage. If it came from a LinkedIn scrape with 0.92 confidence, trust it. If it came from MANUAL_IMPORT with 0.0 confidence, flag for review.

2. **Compliance:** "How did we know to reach out to Alice?" Audit trail: "she matched segment criteria X on 2026-04-10 based on a company scrape from 2026-04-09."

3. **ML feedback:** "LLM confidence scores — which were accurate?" Query DataLineage by confidence bucket and cross-reference with actual outcomes. Use to retrain or adjust threshold.

4. **Replay:** "Did we make the same inference mistake twice?" Hash of the prompt + model version enables identifying duplicate work.

### Implementation Constraints

- `DataLineage.sourceId` is nullable (for manual enrichment, it's NULL)
- `DataLineage.promptHash` is nullable (for non-LLM sources)
- `DataLineage.confidenceScore` defaults to NULL; treated as "unknown confidence" (safer than guessing)
- Immutable: DataLineage records are never updated. A field changed again? Create a new DataLineage record.

---

## What Phase 1 Foundation Enables

### 1. Tenant Isolation (tenantId on every model)
Phase 1 ensured `tenantId` is present on every table: contacts, companies, campaigns, engagements, even API keys. Phase 2 research is fully multi-tenant from day one:
- One MinIO service shared across tenants (buckets scoped by tenantId)
- One queue shared across tenants (job data includes tenantId)
- One ResearchJob can only see contacts/companies from its tenant

### 2. Async Queue Pattern (proven in Phase 1)
Phase 1 already uses BullMQ for webhooks (engagement processing) and segments (evaluation). Phase 2 reuses the exact same pattern:
- Enqueue a pointer (job ID)
- Worker fetches full context from DB
- Worker writes results back
- No raw payloads in Redis

Developers new to Phase 2 can copy the webhook/segment worker as a template.

### 3. Pointer Pattern (Job ID, not Payload)
Phase 1 webhook ingestion stores the full payload once in DB, then enqueues `{ webhookEventId: '...' }`. Phase 2 research follows the same pattern:
- Enqueue `{ researchJobId: '...', sourceId: '...' }`
- Worker resolves from DB
- MinIO keys are pointers, not embedded data

This pattern scales: 10K concurrent research jobs = ~1MB Redis (pointers only), not 100GB.

### 4. Prisma Schema Extensibility
The Phase 1 migration already defines all Phase 2 models in the schema. Phase 2 implementation doesn't need to create migrations — tables already exist. Just add:
- Indexes if needed (can be added post-migration in Phase 2)
- Constraints if business rules change
- Relations to new tables (unlikely; everything is modeled)

### 5. Docker Compose Profile System
Phase 1 set up `docker compose --profile phase2` for MinIO. Developers can:
- Phase 1 dev: `docker compose up` (no MinIO overhead)
- Phase 2 dev: `docker compose --profile phase2 up` (MinIO included)

---

## Next Steps (Phase 2 Implementation)

1. **Hire or allocate 1-2 engineers** for 4–6 weeks
2. **Build research-jobs module** — CRUD + FlowProducer dispatch
3. **Integrate scraper** (FireCrawl API or custom) + MinIO upload
4. **Build parse stage** (HTML → JSON, e.g., with jsdom + LLM)
5. **Build enrich stage** (LLM extraction + DataLineage writes)
6. **Build lineage API** (read-only query interface)
7. **Smoke test** against real contacts (Phase 1 data)
8. **Monitor** — BullMQ dashboards, DataLineage audit logs

---

## References

- Phase 1 Plan: `docs/superpowers/plans/2026-04-05-sales-engine-phase1-revised.md`
- Architectural Decisions: `docs/superpowers/decisions/`
- Prisma Schema (Phase 2 models): Task 2 of Phase 1 plan
- Docker Compose (MinIO): Task 17 of Phase 1 plan
