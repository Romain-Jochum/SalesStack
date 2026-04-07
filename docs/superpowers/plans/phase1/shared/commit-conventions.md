# Commit Conventions

> All commits in this project follow Conventional Commits with strict formatting
> rules enforced by review.

## Format

```
type(scope): description

Optional body wrapping at 72 characters. Explain the "why" rather than
the "what" -- the diff already shows what changed.

Optional footer (e.g., Closes #123, BREAKING CHANGE: ...)
```

## Types

| Type | When to use |
|------|-------------|
| `feat` | New feature or module (schemas, service, routes) |
| `fix` | Bug fix |
| `chore` | Tooling, config, dependencies, scaffolding |
| `docs` | Documentation only |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `test` | Adding or updating tests |
| `ci` | CI/CD pipeline changes |

## Rules

1. **50/72 rule:** Subject line under 50 characters, body wraps at 72
2. **Imperative mood:** "Add feature" not "Added feature" or "Adds feature"
3. **Atomic commits:** One logical change per commit. Do not bundle unrelated
   changes.
4. **No trailing period** on the subject line
5. **Lowercase** subject after the type prefix (e.g., `feat: add contacts
   module`, not `feat: Add Contacts Module`)

## Scope (optional)

Use scope to narrow the area of change when helpful:

- `feat(contacts): add bulk upsert endpoint`
- `fix(auth): handle expired API keys`
- `chore(deps): update Prisma to 7.1.1`

For Phase 1 tasks, scope is often omitted since each commit covers a full
module.

## Examples from Phase 1

```
chore: pre-setup for Phase 1 -- deactivate MCPs, add env template
chore: scaffold backend with Node 24, pinned versions, husky pre-commit hooks
feat: add Prisma schema with all Phase 1 models
feat: add core singletons + env validation (db, redis, logger, metrics, queues, config)
feat: add auth, error-handler, rate-limit middleware with Phase C verification
feat: add health, ready, and metrics endpoints with Phase C verification
feat: add contacts module (schemas, service, routes) with Phase C verification
feat: add companies module (schemas, service, routes) with Phase C verification
feat: add segments module with FilterRuleGroup AST evaluator and BullMQ worker with Phase C verification
feat: add campaigns module with enrollment logic with Phase C verification
feat: add engagements module with score delta tracking and unit tests with Phase C verification
feat: add webhooks module with HMAC verification and idempotent ingestion with Phase C verification
feat: add opportunities module (CRUD) with Phase C verification
feat: add job status endpoint (GET /api/jobs/:jobId) with Phase C verification
feat: add workers entry (webhook + segment workers)
feat: add Fastify server entrypoint wiring all module plugins
chore: add multi-stage Dockerfile (Node 24) and entrypoint with ROLE switching
feat: add sales-db, sales-redis, sales-api, sales-worker, monitoring, metabase to Docker Compose
chore: add Prometheus, Loki, Grafana, and db-init.sql configs
chore: add Phase 1 environment variables to .env.example
ci: add GitHub Actions pipeline (lint, typecheck, test, Docker build)
```

## Pre-commit Hooks

husky + lint-staged run on every commit:

- ESLint with `--fix` on `src/**/*.ts` and `tests/**/*.ts`
- Prettier on `**/*.ts`

If the pre-commit hook fails, fix the linting/formatting issues and commit
again. Do not bypass hooks with `--no-verify`.
