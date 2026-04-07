# Sales Engine

Automated sales outreach backend for SMBs. Fastify/TypeScript API with BullMQ
workers, PostgreSQL, Redis — orchestrated by n8n workflows.

## Tech Stack

- **Runtime:** Node.js 24 LTS, npm 10+
- **Backend:** Fastify 5.8.4, TypeScript 5.9.3
- **ORM:** Prisma 7.6.0 (PostgreSQL 18 + pgvector)
- **Queue:** BullMQ 5.73.0, ioredis 5.10.1, Redis 7-alpine
- **Validation:** @sinclair/typebox 0.34.49
- **Logging:** pino 10.3.1
- **Testing:** Jest 29.7.0, ts-jest 29.4.9, testcontainers 11.13.0
- **Linting:** ESLint 8.57.1, Prettier 3.8.1, husky 9.1.7, lint-staged 16.4.0
- **Monitoring:** prom-client 15.1.3, @sentry/node 10.47.0

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

## START

- **ALWAYS** enter plan mode before implementing a feature
- **ALWAYS** explore and load relevant skills before starting work
- If a plan task: **ALWAYS** read the CONTEXT.md in the active plan directory before touching code
- If no plan: **ALWAYS** explore existing patterns and files before writing anything new
- If no relevant skill exists, ask whether to search for one

## CODE ANALYSIS

- **ALWAYS** read existing code before modifying anything
- **ALWAYS** follow established patterns for consistency
- **NEVER** assume structure — read it first

## TYPESCRIPT

- **ALWAYS** use strong typing on every interface, function, and return type
- **NEVER** use `any` — use `unknown` and narrow
- **NEVER** use `@ts-ignore` without a `// @ts-ignore — [reason]` comment
- **NEVER** use `console.log` — use the Pino logger

## CODE ARCHITECTURE

- Vertical slice per module: `schemas.ts` → `service.ts` → `routes.ts`
- Services throw typed errors — **NEVER** catch errors in route handlers, let the error middleware handle it
- Error response shape: `{ error: { code, message, details? } }` — codes: `VALIDATION_ERROR`, `NOT_FOUND`, `UNAUTHORIZED`, `RATE_LIMITED`, `INTERNAL_ERROR`
- `tenantId` on every model, every query — unique constraints scoped to tenant
- Long operations: return `202 + jobId`, client polls `GET /api/jobs/:jobId`
- Any read-then-write sequence belongs in a `$transaction` — never split across two queries
- All required env vars validated at startup — process exits immediately if any are missing
- One Dockerfile, two roles — `ROLE` env var selects API or worker entrypoint
- **NEVER** expose ports publicly — always bind to `127.0.0.1`
- **ALWAYS** use `docker compose` (v2), not `docker-compose` (v1)
- All inter-service traffic uses Docker service names (e.g. `redis://sales-redis:6379`)
- Exact dependency pinning — no `^` or `~` in package.json
- **ALWAYS** implement SIGTERM shutdown in order: drain in-flight requests → close DB → close Redis/workers

## SECURITY

- **NEVER** log secrets, API keys, or PII at any log level
- **NEVER** process a webhook payload before verifying its HMAC signature
- **ALWAYS** validate API keys via SHA-256 hash comparison — never store raw keys
- **ALWAYS** test every endpoint without auth and confirm it returns 401
- Rate limiting: 500 req/min per IP — requests exceeding the limit return 429
- Generate secrets with `openssl rand -base64 32` — never use placeholders in production

## TESTING

- **ALWAYS** write a failing test before implementation — RED → GREEN → REFACTOR
- **NEVER** commit code that breaks existing tests
- Coverage targets (enforced in CI): 80% for business logic, 60% for plumbing
- **NEVER** mock PostgreSQL or Redis in integration tests — use real containers (testcontainers)
- **ALWAYS** test at least one unhappy path per endpoint or handler

## GIT

- **NEVER** mention Claude, AI, agent, or co-authored in commits or PRs
- Commit at each tiny implementation change — one logical change per commit
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`
- Subject: max 50 chars, imperative mood, lowercase after prefix, no trailing period
- **NEVER** use emojis in commits
- Branch naming: `<type>/<TASK-ID>-<kebab-slug>` e.g. `feature/P1-007-contacts-crud`
- GitHub Flow: branch off `main`, merge back to `main`
- **NEVER** bypass pre-commit hooks with `--no-verify`

## PULL REQUESTS

- **ALWAYS** keep PRs small — one task per PR, one branch per task
- Title: `<TASK-ID>: short description`
- Body: one-line summary → `## Changes` (bullets) → `## Testing` (at least one curl command showing happy path + observed response)
- **Rebase and merge** into `main` — atomic commits are the audit trail, never squash
- Before merge: rebase onto latest `main`, force-push with `--force-with-lease`, CI green
- **NEVER** mention Claude, AI, agent, or co-authored in PR title or body
- **NEVER** over-explain — no walls of text, no checkbox checklists
