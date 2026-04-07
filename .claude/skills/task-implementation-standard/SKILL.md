---
name: task-implementation-standard
description: > Use when implementing any task from an implementation plan — scaffolding, modules, middleware, workers, Docker, CI/CD, or any feature/fix/refactor. This skill defines the mandatory end-to-end procedure: understand the task, TDD cycle, real-life verification in a running environment, documentation, and review handoff. Trigger this skill whenever you see a task definition with steps/checkboxes, whenever you are about to write implementation code, whenever a subagent is dispatched to implement a plan task, or whenever someone says "implement task N". Also trigger when fixing bugs or applying hotfixes — the same verification standard applies. If you are writing code that will be committed, this skill applies. No exceptions.
---

# Task Implementation Standard

Every task — feature, fix, refactor, config change — follows the same five phases before code is committed. The phases exist because passing unit tests alone does not prove that code works. Mocked databases don't catch real query failures. Stubbed APIs don't surface payload mismatches. The only way to know code works is to run it for real and see it behave. 

Skipping phases creates a false sense of progress: the commit lands, CI is green, and the bug ships to staging where it costs 10× more to diagnose. Follow every phase in order.

---

## Phase 0 — Branch Setup

Every task starts on its own branch. No exceptions, including "small" fixes.

1. **Ensure main is current:** `git checkout main && git pull --ff-only`.
2. **Cut a task branch** using the naming convention:

`<type>/<TASK-ID>-<kebab-slug>`

- `<type>` ∈ `feature`, `fix`, `chore`, `refactor`, `docs`, `test`
- `<TASK-ID>` is the plan task identifier in uppercase: phase prefix + number. Phase 1 task 07 → `P1-007`. Phase 2 task 14 → `P2-014`. Hotfixes outside a plan use `HOTFIX-<date>`, e.g. `HOTFIX-20260407`.
- `<kebab-slug>` is 3–6 words describing the task, lowercase, hyphenated.

Examples:
   - `feature/P1-007-contacts-crud-endpoints`
   - `fix/P1-012-webhook-hmac-timing-attack`
   - `chore/P1-003-docker-compose-pg18`
   - `refactor/P2-021-segment-filter-ast-eval`

3. **Push the branch immediately** with `git push -u origin <branch>` and open a **draft PR** before writing any code. The draft PR is your working log — CI runs on every push, the review template (Phase E) fills in as you go, and work-in-progress is visible to the orchestrator.

4. **One task = one branch = one PR.** If a task grows and needs to be split, stop and escalate with `NEEDS_CONTEXT` — don't quietly widen scope on an existing branch.

## Phase A — Understand

Before reading the task itself, read docs/superpowers/plan/phaseN/CONTEXT.md (project-wide conventions) and docs/superpowers/plan/phaseN/shared/ (templates referenced by tasks). Then read the specific task-NN-*.md file. Do not read sibling task files unless the dependency header lists them — context bloat hurts more than it helps.

1. **Read the task definition** from the implementation plan. Identify every file to create or modify, every dependency involved, and every acceptance criterion (explicit or implied).
2. **Check for library docs** — if the task involves any library where the API surface may have changed, consult `context7` or official docs first. The plan's code snippets are a starting point, not gospel. If the docs show a different API signature, the docs win.
3. **Identify upstream dependencies** — does this task depend on files or modules from a previous task? Verify they exist and are in the expected state. If something is missing, stop and escalate with `NEEDS_CONTEXT` rather than guessing.
4. **Verify dependency versions** — confirm that the version installed in `package.json` matches the docs you consulted. If the plan says "Fastify v5" but `npm ls fastify` shows v4, you're reading the wrong docs and writing code against the wrong API. Pin exact versions in `package.json` (`"fastify": "5.2.1"`, not `"^5.0.0"`) and never install `latest` without checking what version that resolves to. A mismatch between the installed version and the documentation you're referencing is a bug waiting to happen — catch it here, not in Phase C.

The goal of Phase A is to prevent wasted cycles. Five minutes of reading saves an hour of debugging the wrong thing.

---

## Phase B — TDD Cycle

This phase applies to **all business logic**: services, middleware, workers, webhook handlers, filter engines, route handlers. For pure scaffolding tasks (project init, tsconfig, Dockerfile, docker-compose, CI config), skip to Phase C — there is no meaningful "failing test" for a config file. 

Invoke `superpowers:test-driven-development` and follow its RED → GREEN → REFACTOR cycle. If the skill is unavailable in your agent's context, apply its principles manually — the process is what matters, not the tooling: write a failing test before any implementation code, always.

1. **RED** — Write a failing test that defines the desired behavior. Run it. Watch it fail. If it passes without your implementation, the test is wrong — it's testing something that already exists or is vacuously true.
2. **GREEN** — Write the minimum implementation to make the test pass. Nothing more. Resist the urge to add "while I'm here" code.
3. **REFACTOR** — Clean up the implementation without changing behavior. Tests must still pass after refactoring.
4. **Repeat** — for each behavior the task defines. One test at a time, not a batch of 10 tests followed by a batch of implementation.

### TypeScript standards during this phase

- Never use `any` — use `unknown` and narrow.
- `@ts-ignore` only with a `// @ts-ignore — [reason]` comment, flagged as tech debt.
- Explicit return types on all exported/public functions. Inference is fine for internal helpers and arrow callbacks.
- No `console.log` — use the project's logger. ESLint `no-console` will catch this, but don't rely on linting as your only guardrail.
- No unused imports or variables.

### Error handling contract

The project follows a "throw and let middleware catch" pattern. Business logic throws typed errors; the Fastify error handler (see `core/middleware/error-handler.ts`) catches them and produces a consistent JSON response. The rules:

- **Throw, don't return error objects.** Services throw; routes don't catch unless they need to transform the error. The error handler is the single place where errors become HTTP responses.
- **Use a standard error shape.** Every error response follows `{ error: { code: string, message: string, details?: unknown } }`. The `code` is a machine-readable enum (`VALIDATION_ERROR`, `NOT_FOUND`, `UNAUTHORIZED`, `RATE_LIMITED`, `INTERNAL_ERROR`). The `message` is human-readable. For 500s, the message is always generic — never leak internal details.
- **Validate inputs at the boundary.** Fastify JSON schema or Zod validates request payloads before they reach service code. Services can assume inputs are structurally valid; they only need to check business rules (e.g., "does this contact exist").
- **Fail at startup, not at first request.** All required environment variables, database connections, and Redis connections must be validated when the service boots. If a required config value is missing, the process exits immediately with a clear message — it does not start serving requests and fail on the first one that needs the missing value.

### Coverage targets

These thresholds are enforced by a coverage gate in CI — not advisory. A PR that lands at 78% when the target is 80% fails the pipeline.

- **80%** for business logic (services, workers, filter engines, webhook handlers, billing/subscription state machines).
- **60%** for plumbing (config, middleware wrappers, route registration, queue constants).

All unit tests must pass before proceeding. No exceptions, no "I'll fix it later" — later never comes. If a test fails once out of ten runs, it is failing — investigate the flakiness before proceeding. Flaky tests are not "mostly passing"; they are evidence of a race condition, shared state leak, or timing dependency that will cause real production bugs. Fix the root cause, don't rerun until green.

---

## Phase C — Real-Life Verification

This is the phase most developers skip, and it's the phase that catches the most expensive bugs. Unit tests prove logic correctness in isolation. Real-life verification proves the code works in an actual running environment with real databases, real queues, and real HTTP requests.

### Time budget

Phase C for a single endpoint or module should take under 15 minutes. If verification is taking longer, that's a signal: either the task scope is too large (split it), the dev environment setup is broken (fix it first), or you're testing too deeply for this phase (save exhaustive testing for integration test suites). Don't spend two hours curling a CRUD endpoint.

### Environment parity

Dev containers must match production versions of Postgres, Redis, and Node within one minor version. If production runs Postgres 18.1, dev must run 18.x — not 16 or 17. Same for Redis 7.x and Node 24.x. Version drift is how you get queries that pass locally and fail in production because a function was added in a minor release you don't have, or a default changed. Verify this once when setting up the project, and re-verify whenever `docker-compose.yml` or `Dockerfile` is modified.

### For every task:

1. **Start the relevant services.** `docker compose up` or local dev server. The database, Redis, and the application must all be running. Never mock Postgres or Redis at this stage — the whole point is catching real connection issues, query failures, and migration problems.
2. **Exercise the happy path.** Make a real HTTP request (curl, httpie, or a test script). For API endpoints: call the endpoint with valid input and verify the response and database state. For workers: enqueue a real job and verify it processes. For webhooks: replay a real payload (from WAHA docs or a captured test-mode event) and verify the full pipeline from ingestion to database write.
3. **Exercise at least one unhappy path.** Send malformed input. Use an expired or missing API key. Send a duplicate webhook event. Simulate a scenario the user will inevitably trigger. The specific unhappy path depends on the task, but the rule is: try to break it at least once.
4. **Test a concurrency scenario** (when applicable). The nastiest production bugs come from concurrent access, not malformed input. For tasks involving shared state, test at least one of these: fire two identical requests simultaneously (double-submit), have two workers pick up related jobs at the same time, or trigger a race condition on an upsert. BullMQ workers and webhook handlers are especially prone — two webhook deliveries arriving within milliseconds of each other is normal, not exceptional. You can simulate this with a simple bash loop: `for i in 1 2; do curl -X POST ... & done; wait`. If the result is inconsistent across runs, you have a concurrency bug. 
  **Transaction boundary rule:** any operation that touches multiple tables or has read-then-write semantics must use a database transaction. Upserts, webhook processing pipelines, and multi-entity writes are the most common cases. If you're reading a row to decide whether to insert or update, that entire sequence belongs in a transaction — otherwise a concurrent request can slip between the read and the write. Prisma's `$transaction` API handles this; use it.
5. **Verify security boundaries.** Every endpoint must be tested without authentication to confirm it returns 401 — not just the endpoints you think require auth, but all of them. For webhook handlers, verify that HMAC rejection works, that oversized payloads are rejected (set a request body size limit), and that the handler doesn't process the payload before verifying the signature. Security verification is not optional for any task that touches an HTTP boundary.
6. **Check log output.** During the happy and unhappy path tests above, watch the application logs. Verify that the correct log level is used (info for normal operations, warn for recoverable issues, error for failures), that structured fields are present (request ID, tenant ID, relevant entity IDs), and that no PII or secrets leak into log output (no raw API keys, no full email addresses in info-level logs). In production, logs are the first thing you reach for when something breaks — if they're wrong or missing, you're debugging blind.

### Task-type-specific verification:

| Task type | Happy path verification | Unhappy path verification |
|---|---|---|
| API CRUD endpoint | Create/read/update/delete via curl, check DB | Invalid payload → 400, missing auth → 401 |
| Middleware (auth) | Valid API key → request passes through | Expired key → 401, revoked key → 401 |
| Middleware (rate limit) | Normal request → 200 | Exceed limit → 429 with correct `Retry-After` |
| Webhook handler | Replay real payload → engagement event in DB | Invalid HMAC → 401, duplicate event → idempotent |
| BullMQ worker | Enqueue job → worker processes → verify side effects | Malformed job data → logged error, no crash |
| Segment filter engine | Evaluate filter against matching contact → included | Non-matching contact → excluded, malformed AST → error |
| Docker/CI config | `docker compose up` → all services healthy | Missing env var → clear error message, not silent crash |
| Database migration | `prisma migrate deploy` → schema matches expected state | Rollback migration → previous state restored |

### For bug fixes specifically:

Add one extra step: **reproduce the original bug first.** Confirm the buggy behavior exists, then apply the fix, then confirm the fix resolves it. Document both states: "before: X happened, after: Y happens." This prevents fix regressions and proves the fix addresses the actual reported issue.

### For n8n integration (Phase 1 smoke tests):

When testing API endpoints that n8n will consume, verify the round trip: set up a simple n8n test workflow that calls your endpoint → confirm n8n receives the response in the expected format → confirm any callbacks or webhooks fire correctly back to n8n. The API exists to serve n8n; if it doesn't work with n8n in practice, passing unit tests is meaningless.

### Rollback and cleanup

When verification fails, do not retry against dirty state. Revert to a known-good state first:

- **Database migrations:** if a migration is half-applied or verification reveals a schema problem, run `prisma migrate reset` (dev only) or roll back the specific migration before re-attempting. Never layer a "fix" migration on top of a broken one — that compounds the problem.
- **Docker containers:** if a service is in a bad state (crashed worker, corrupted Redis data), tear down and recreate: `docker compose down -v` then `docker compose up`. The `-v` flag removes volumes, giving you a genuinely clean slate.
- **Test data:** if manual testing created records that interfere with subsequent tests, truncate the relevant tables or use a seed script that resets to a known baseline. Stale test data is a common source of "it worked yesterday" confusion.

**Migration safety for production.** Even in Phase 1 dev, write migrations as if zero-downtime deploys are already in place — retrofitting this later is painful. The rules: never rename or drop a column in a single migration (add the new column → migrate data → deploy code that uses the new column → drop the old column in a later migration). Every migration must be backward-compatible with the previous application version, because during a rolling deploy both versions run simultaneously. If a migration requires locking a large table, flag it in the PR as a potential downtime risk.

The principle: every verification attempt must start from a reproducible state. If you can't describe the state your environment is in, you can't trust the results you get from it.

### Future evolution: automated integration tests

Phase C is manual today. As the project grows beyond a small team, manual verification won't scale — you can't ask ten developers to each spend 15 minutes curling endpoints for every PR. The path forward is to automate Phase C verifications as integration tests that run against real containerized dependencies (Testcontainers handles this). When you write a Phase C verification and find yourself running the same curl sequence for the third time, that's the signal to convert it into an automated integration test. The manual discipline comes first; the automation encodes what you learned from doing it by hand.

---

## Phase D — Document & Commit

Before committing, invoke `superpowers:verification-before-completion` to force a final check that everything actually works.

1. **Add JSDoc to all exported functions.** These are the API surface that other modules and external consumers (n8n) will call. They must be self-documenting. Internal helpers don't need JSDoc unless the logic is genuinely complex.

2. **Add inline comments sparingly.** Only on complex logic — filter engine AST evaluation, HMAC verification math, retry backoff calculations. Never add comments that restate what the code does. If the code needs a comment to be understood, consider whether the code should be clearer instead.

3. **Write a test summary** for the commit/PR description. This is not optional — it creates accountability and gives reviewers confidence. Use this format:

   ```
   Manual testing performed:
   - [What you did] → [What you observed]
   - [What you did] → [What you observed]
   - [Unhappy path tested] → [What you observed]
   ```

   **Example:**
   ```
   Manual testing performed:
   - POST /api/contacts with valid payload → 201, contact in DB with correct fields
   - POST /api/contacts with missing required field → 400 with VALIDATION_ERROR
   - GET /api/contacts without auth header → 401 UNAUTHORIZED
   - Duplicate POST with same email → upsert succeeded, no duplicate row
   ```

4. **Commit atomically at step boundaries, not task boundaries.**

A task from the plan typically has numbered steps (1.1, 1.2, 1.3…). Each step is a commit. A good commit is one that a reviewer can understand in isolation and that leaves the codebase in a buildable, test-passing state.

Natural commit boundaries inside a task:

- Each completed RED → GREEN → REFACTOR cycle from Phase B (one behavior = one commit; the failing test and its implementation land together — never commit a red test alone on a shared branch)
- Schema / migration additions (separate from code that uses them)
- Scaffolding (tsconfig, folder layout, plugin registration)
- Each unhappy-path branch once its test exists
- Documentation (JSDoc, README updates) as its own commit at the end

**Anti-pattern:** one giant `feat(contacts): implement CRUD` commit with 14 files. **Correct:** five commits — schema, service happy path, service error cases, routes, docs.

**Commit message format:** Follow `CLAUDE.md → ## GIT`. Commits are atomic —
one tiny logical change per commit, not one per phase or task step.

5. **Push after every commit.** Draft PR CI will run; flaky-on-push is cheaper to catch now than at review time.

---

## Phase E — Review Handoff

Invoke `superpowers:requesting-code-review` to format the work summary. The review request should include:

- **What changed** — files created/modified, new dependencies added.
- **How it was tested** — the test summary from Phase D (both automated and manual).
- **Known limitations** — anything that's intentionally deferred, any `@ts-ignore` with its justification, any edge case you chose not to handle and why.
- **Dependencies for reviewer** — what the reviewer needs running to reproduce (Docker, env vars, API keys).

The reviewer's job is to pull the branch, run it, and verify at least the happy path works. If setup is painful, that's a signal the dev environment docs need improvement — flag it.

Before requesting review, update plan state **on the feature branch** as the final commit — not after merge. Specifically:

1. Update `docs/superpowers/plan/phaseN/STATUS.md` to reflect the task's new state (in-review, blocked, or done-pending-merge).
2. Append an entry to `docs/superpowers/plan/phaseN/task-NN-*.LOG.md` summarizing what was built, what was verified in Phase C, and any deferred work.
3. Commit these changes as a single isolated commit:

```
chore: mark task <TASK-ID> ready for review
Refs: <TASK-ID>
```

4. Push, then move the PR from draft to ready-for-review.

**Why on the branch, not after merge:** plan state and code state must land together. If the plan update happens as a follow-up commit on `main` after merge, there is always a window — sometimes permanent, when someone forgets — where `main` claims a task is incomplete while the code for it is already deployed, or vice versa. Keeping the plan update as the last commit on the feature branch means one rebase-merge atomically updates both the implementation and its record in the plan. The log entry also becomes part of the PR diff, so the reviewer sees (and can challenge) your self-assessment of what was done.

**Do not** amend the plan update into an earlier implementation commit — keep it isolated. Mixing plan churn into implementation commits pollutes `git blame` on source files with plan-doc edits.

---

## Skill chaining reference

This skill orchestrates other superpowers skills. Here is the invocation order:

```
Phase 0
    ↓
Phase A: [understand task]
    ↓
Phase B: superpowers:test-driven-development
    ↓   (if stuck → superpowers:systematic-debugging, try once, then NEEDS_CONTEXT)
Phase C: [real-life verification — no skill, just discipline]
    ↓
Phase D: superpowers:verification-before-completion
    ↓
Phase E: superpowers:requesting-code-review
```

When receiving feedback after review, invoke `superpowers:receiving-code-review` — verify suggestions are technically sound before applying them.

If a referenced skill is unavailable in the agent's context, apply its principles manually (as noted in Phase B). The skills formalize good practices — the practices still apply without the formal skill loaded.

---

## Partial implementation and blocking dependencies

Sometimes a task can't be fully completed because a downstream dependency isn't ready — an API it calls doesn't exist yet, a schema it references hasn't been migrated, or a service it integrates with is in a later phase. The rules for partial implementation:

- **Commit what works, stub what doesn't.** If 80% of a task is implementable and testable, implement it. For the remaining 20%, create an explicit stub or interface that defines the contract (function signature, expected input/output types) without the real implementation. Mark stubs clearly: `// TODO(phase-2): implement real WAHA integration`.
- **Never commit dead code behind "I'll finish this later."** A stub with a clear contract is not dead code — it's a defined integration point. A half-written function with no tests and no contract is dead code. The difference is whether someone else could implement the stub from its signature alone.
- **Feature flags are for runtime behavior, not incomplete code.** Use feature flags when a complete feature needs to be deployed but not yet activated (e.g., a new endpoint that shouldn't receive traffic yet). Don't use feature flags to hide broken or untested code paths.
- **Document what's deferred in the PR.** The "Known limitations" section of the review handoff (Phase E) is where you explicitly state what was deferred and why. This prevents the next person from wondering whether the stub is intentional or a bug.

---

## Escalation policy

If a subagent gets stuck — tests fail unexpectedly, types don't resolve, a dependency is missing:

1. **First:** invoke `superpowers:systematic-debugging`. Follow its 4-phase methodology (reproduce → isolate → diagnose → fix).
2. **If still blocked after one full diagnostic cycle:** escalate with `NEEDS_CONTEXT`. Include what was tried, what was found, and what remains unclear. Do not spin for 30 minutes on a problem that the orchestrator could resolve in 2.

---

## The one rule

If it doesn't work in a running environment, it doesn't get committed. Tests passing in isolation is necessary but not sufficient. Every implementation must survive contact with real infrastructure.
