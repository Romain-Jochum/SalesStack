# Phase 1 Context

Project-wide conventions that every task assumes.

## Tech stack (pinned versions)

- Node.js 24 LTS, npm 10+
- Fastify 5.2.1, TypeScript 5.5.4
- Prisma 7.1.0 (PostgreSQL)
- pgvector/pgvector:pg18 (PostgreSQL 18 + vector extension)
- Redis 7-alpine, ioredis 5.4.1, BullMQ 5.71.0
- @sinclair/typebox 0.34.13
- pino 9.4.0
- prom-client 15.1.3, @sentry/node 8.31.0
- Jest 29.7.0, ts-jest 29.1.5, testcontainers 10.11.2
- ESLint 8.57.1, Prettier 3.3.3, husky 8.1.0, lint-staged 15.2.7

## Architecture conventions

- Vertical slices: `backend/src/modules/[module]/{schemas.ts,service.ts,routes.ts}`
- Core infrastructure: `backend/src/core/{db.ts,redis.ts,logger.ts,metrics.ts,queues.ts,config.ts}`
- Middleware: `backend/src/core/middleware/{auth.ts,error-handler.ts,rate-limit.ts}`
- Workers: `backend/src/workers/index.ts` + module-specific workers
- Tests: `tests/unit/[module]/`
- Single Docker image, two roles via `ROLE` env var (api or worker)

## Error handling contract

Reference `shared/error-contract.md` for the full contract. Summary: throw typed errors -> Fastify error handler -> consistent JSON: `{error: {code, message, details?}}`. Codes: VALIDATION_ERROR, NOT_FOUND, UNAUTHORIZED, RATE_LIMITED, INTERNAL_ERROR, CONFLICT.

## Observability contract

- **Logging:** Pino structured JSON. No `console.log` (ESLint enforced).
- **Metrics:** prom-client -- HTTP request duration histogram by method/route/status, custom counters per module.
- **Error reporting:** Sentry with tagged context (jobId, queue, module).
- **Job tracking:** BullMQ jobs exposed via GET /api/jobs/:jobId.

## Secrets policy

- Environment variables only. Never in code, git, logs, or error responses.
- Generate at deploy: `openssl rand -hex 24` for DB password, `openssl rand -base64 32` for webhook secrets.
- Startup validation: `core/config.ts` throws if required env vars missing.
- API keys: stored as SHA256 hash, prefix in plaintext for lookup.
- Webhook signatures: HMAC-SHA256.

## Database conventions

- Soft delete: `deletedAt: DateTime?` on all entities. All queries filter `WHERE deletedAt IS NULL`.
- Tenant isolation: `tenantId` on all models, all queries scoped.
- Timestamps: `createdAt`, `updatedAt` on all models.
- Primary keys: `@id @default(uuid()) @db.Uuid`.
- Custom fields: `Json` columns for extensibility.
- Embeddings: pgvector `vector(1536)` for AI features.
- Transactions: read-then-write patterns use Prisma transactions.

## API response format

- **Success:** `{data: T, meta?: {total, page, limit}}`
- **Error:** `{error: {code, message, details?}}`
- **Async:** `{jobId, statusUrl}` with 202 Accepted
- **Health:** `{status, uptime, db, redis}`

## Port allocation

| Port | Service | Internal | Phase |
|------|---------|----------|-------|
| 2359 | Sales Engine API | 3000 | 1 |
| 2360 | Sales Engine PostgreSQL | 5432 | 1 |
| 2361 | Sales Engine Redis | 6379 | 1 |
| 2365 | Prometheus | 9090 | 1 |

All ports bind to 127.0.0.1 only.

## Decisions needed

The following are open questions to resolve before or during implementation.

### Backup policy

DECISION NEEDED: What's the Phase 1 stance? "Accept volume-only backup risk" or configure pg_dump cron?

### PII and deletion

DECISION NEEDED: Soft delete exists, but no GDPR/compliance framework. Is "soft delete default, hard delete on request" sufficient for Phase 1?

### API versioning

DECISION NEEDED: All routes are `/api/contacts` with no version prefix. Adopt `/api/v1/` now or defer?

### Performance budgets

DECISION NEEDED: No SLAs defined. Suggested: API p95 <200ms, worker p95 <5s, webhook ingestion <100ms.

### Dependency security

DECISION NEEDED: No `npm audit` in CI. Add to CI pipeline or defer?

### Rate limiting specifics

DECISION NEEDED: Middleware skeleton exists. CLAUDE.md says 500 req/min per IP. Confirm?

### Logging retention

DECISION NEEDED: Loki configured but no retention policy. 30 days default?

### Cache invalidation

DECISION NEEDED: Redis used for queues only. No read caching planned for Phase 1?
