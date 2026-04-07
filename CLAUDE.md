# Sales Engine

Automated sales outreach backend for appointment-heavy SMBs. Fastify/TypeScript
API with BullMQ workers, PostgreSQL, and Redis. Designed to be orchestrated by
n8n workflows. Twenty CRM, Mautic, and WAHA integrate in Phase 2/3.

## Project Structure

```
sales-engine/
├── backend/
│   ├── src/
│   │   ├── core/              # Singletons: db, redis, logger, metrics, config, queues
│   │   │   └── middleware/    # auth, error-handler, rate-limit
│   │   ├── modules/           # Vertical slices (each is a Fastify plugin)
│   │   │   ├── health/        # routes.ts
│   │   │   ├── contacts/      # schemas.ts, service.ts, routes.ts
│   │   │   ├── companies/     # schemas.ts, service.ts, routes.ts
│   │   │   ├── segments/      # schemas.ts, service.ts, routes.ts, segment.worker.ts
│   │   │   ├── campaigns/     # schemas.ts, service.ts, routes.ts
│   │   │   ├── engagements/   # schemas.ts, service.ts, routes.ts
│   │   │   ├── webhooks/      # schemas.ts, service.ts, routes.ts, webhook.worker.ts
│   │   │   ├── opportunities/ # schemas.ts, service.ts, routes.ts
│   │   │   └── jobs/          # schemas.ts, routes.ts (pointer pattern)
│   │   ├── server.ts          # Fastify app: buildApp(), start()
│   │   └── workers/
│   │       └── index.ts       # BullMQ worker entrypoint
│   ├── prisma/
│   │   └── schema.prisma
│   ├── tests/
│   │   └── unit/
│   ├── Dockerfile             # Multi-stage, ROLE-based entrypoint
│   ├── docker-entrypoint.sh
│   ├── package.json
│   ├── tsconfig.json
│   └── jest.config.ts
├── docs/superpowers/          # Plans, specs, architectural decisions
├── .claude/skills/            # task-implementation-standard, docker
└── .tmp/                      # Scratch files (gitignored)
```

## Tech Stack

- **Runtime:** Node.js 24 LTS, npm 10+
- **Backend:** Fastify 5.2.1, TypeScript 5.5.4
- **ORM:** Prisma 7.1.0 (PostgreSQL)
- **Database:** pgvector/pgvector:pg18 (PostgreSQL 18 + vector extension)
- **Cache/Queue:** Redis 7-alpine, ioredis 5.4.1, BullMQ 5.71.0
- **Validation:** @sinclair/typebox 0.34.13
- **Logging:** pino 9.4.0
- **Monitoring:** prom-client 15.1.3, @sentry/node 8.31.0
- **Testing:** Jest 29.7.0, ts-jest 29.1.5, testcontainers 10.11.2
- **Linting:** ESLint 8.57.1, Prettier 3.3.3, husky 8.1.0, lint-staged 15.2.7

## Port Allocation (bind to 127.0.0.1 only)

| Port | Service | Internal | Phase |
|------|---------|----------|-------|
| 2350-2358 | Reserved | — | Phase 2/3 (Twenty, Mautic, WAHA, n8n) |
| 2359 | Sales Engine API | 3000 | 1 |
| 2360 | Sales Engine PostgreSQL | 5432 | 1 |
| 2361 | Sales Engine Redis | 6379 | 1 |
| 2362 | MinIO API | 9000 | 2 |
| 2363 | MinIO Console | 9001 | 2 |
| 2365 | Prometheus | 9090 | 1 |
| 2366 | Grafana | 3000 | 2 |
| 2367 | Loki | 3100 | 2 |
| 2368 | Metabase | 3000 | 2 |
| 2369-2399 | Reserved | — | Future |

## Commands

```bash
# Backend dev
cd backend
npm install
npm run dev:api                # Fastify dev server (tsx watch)
npm run dev:worker             # BullMQ worker dev (tsx watch)
npm run build                  # TypeScript compile
npm run start:api              # Production API
npm run start:worker           # Production worker

# Testing
npm run test:unit              # Unit tests
npm run test:integration       # Integration tests (--runInBand)
npm run test                   # All tests
npm run lint                   # ESLint
npm run lint:fix               # ESLint auto-fix
npm run format                 # Prettier
npm run typecheck              # tsc --noEmit

# Prisma
npm run prisma:migrate         # Dev: create + apply migration
npm run prisma:deploy          # Prod: apply migrations
npm run prisma:studio          # Open Prisma Studio
npm run prisma:generate        # Regenerate client

# Docker
docker compose up -d sales-db sales-redis           # Start infra
docker compose up -d sales-api sales-worker          # Start app
docker compose --profile phase2 up -d                # Include Phase 2 services
docker compose logs -f sales-api                     # Tail API logs
docker compose exec sales-db psql -U salesengine -d salesengine
```

## Git & PR Practices

### Commit Conventions
- **Conventional Commits** required:
  `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`
- **50/72 rule:** subject under 50 chars, body wraps at 72
- **Imperative mood:** "Add feature" not "Added feature"
- **Atomic commits:** one logical change per commit

### Branching
- **GitHub Flow:** branch off `main`, merge back to `main`
- **Branch naming:** `feature/<desc>`, `bugfix/<desc>`, `hotfix/<desc>` (hyphen-separated, lowercase)

### Pull Requests
- Small, focused PRs — break large features into chunks
- Descriptive summary: what, why, and how to test
- Squash and merge into `main`

## Key Rules

- **NEVER** expose ports publicly. Always bind to `127.0.0.1`.
- All inter-service communication uses Docker service names (e.g., `redis://sales-redis:6379`).
- Stack must be portable: macOS locally, Linux server with same compose files.
- Use `docker compose` (v2), not `docker-compose` (v1).
- Generate secrets with `openssl rand -base64 32` — never use placeholders in production.
- Exact dependency pinning: no `^` or `~` in package.json.
- No `console.log` — use Pino logger. ESLint `no-console` enforces this.
- No `any` — use `unknown` and narrow. No `@ts-ignore` without a justification comment.

## Architecture

### Vertical Slices
Each module is a self-contained Fastify plugin:
- `schemas.ts` — TypeBox request/response schemas
- `service.ts` — Business logic (Prisma queries, no HTTP concerns)
- `routes.ts` — Fastify route handlers

### Pointer Pattern
Long operations return `202 Accepted` + job ID. Client polls `GET /api/jobs/:jobId`.
BullMQ jobs carry IDs, never raw payloads.

### Tenant Isolation
`tenantId` on every model, every query. Unique constraints scoped to tenant.

### Error Handling
Throw typed errors → Fastify error handler catches → consistent JSON response:
`{ error: { code, message, details? } }`. Codes: `VALIDATION_ERROR`, `NOT_FOUND`,
`UNAUTHORIZED`, `RATE_LIMITED`, `INTERNAL_ERROR`.

### Security
- Helmet (CORS, CSP, HSTS)
- Rate limiting: 500 req/min per IP
- API key auth via SHA-256 hashing
- HMAC signature validation for webhooks
- Fail at startup if required env vars missing

### Graceful Shutdown
SIGTERM → close app → disconnect DB → close Redis/workers. Wait for in-flight requests.

### Single Image, Two Roles
One Dockerfile builds both API and worker. `ROLE` env var selects entrypoint.

## Environment Variables

Required:
- `DATABASE_URL` — PostgreSQL connection string
- `REDIS_URL` — Redis connection string

Optional (with defaults):
- `PORT` (3000), `HOST` (0.0.0.0), `NODE_ENV` (development), `LOG_LEVEL` (debug)
- `ROLE` (api|worker), `SALES_API_PORT` (2359), `SALES_DB_PORT` (2360), `SALES_REDIS_PORT` (2361)
- `SENTRY_DSN`, `CORS_ORIGIN`, webhook secrets, `N8N_BASE_URL`, `N8N_API_KEY`

## Documentation

- **Phase 1 plan:** `docs/superpowers/plans/2026-04-05-sales-engine-phase1-revised.md`
- **Phase 2/3 architecture:** `docs/superpowers/specs/2026-04-05-phase2-phase3-architecture.md`
- **Architectural decisions:** `docs/superpowers/decisions/`

## MCP Servers

- **context7:** Active — Fastify v5, Prisma v7, BullMQ v5.71+ docs
- **n8n:** Active for Phase 1 smoke tests (docs + live testing)
- **twenty-crm, mautic, waha:** Deactivated until Phase 2/3
