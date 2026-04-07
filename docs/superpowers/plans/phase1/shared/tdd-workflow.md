# TDD Workflow: RED-GREEN-REFACTOR

> Every module task follows this cycle. Write the test first, watch it fail,
> then write the minimum implementation to make it pass.

## The Cycle

### 1. RED: Write the failing test

Define expected behavior through assertions. The test file goes in
`backend/tests/unit/<module>/` following the naming convention
`<subject>.test.ts`.

- Import from the source module (e.g., `../../../src/modules/contacts/service`)
- Mock dependencies (Prisma client, queues) using `jest.fn()`
- Write `describe` blocks for each function, `it` blocks for each behavior
- Use `expect` assertions that describe the contract, not the implementation

### 2. Run tests -- verify the test fails for the RIGHT reason

```bash
cd backend && npm run test:unit -- --testPathPattern=tests/unit/<module>/ --no-coverage
```

Expected failure: `Cannot find module '../../../src/modules/<module>/<file>'`
(module not yet implemented).

This confirms the test is wired correctly. If the test fails for a different
reason (syntax error, wrong import path, misconfigured mock), fix the test
before proceeding.

### 3. GREEN: Write the minimum implementation

Create the source file(s) that make the test pass. Follow the vertical slice
pattern:

- `schemas.ts` -- TypeBox request/response schemas
- `service.ts` -- Business logic (Prisma queries, no HTTP concerns)
- `routes.ts` -- Fastify route handlers (delegates to service)

Write only enough code to satisfy the assertions. Do not add features the
tests do not cover yet.

### 4. Run tests -- verify the test passes

```bash
cd backend && npm run test:unit -- --testPathPattern=tests/unit/<module>/ --no-coverage
```

Expected: all tests PASS. If any test fails, fix the implementation (not the
test) unless the test itself has a bug.

### 5. REFACTOR: Clean up without changing behavior

- Extract shared logic into helper functions
- Remove duplication between test cases
- Ensure naming is consistent and self-documenting
- Add JSDoc comments on exported functions
- Run tests again to confirm nothing broke:

```bash
cd backend && npm run test:unit -- --testPathPattern=tests/unit/<module>/ --no-coverage
```

## Commands Reference

| Command | When to use |
|---------|-------------|
| `npm run test:unit` | Run all unit tests |
| `npm run test:unit -- --testPathPattern=tests/unit/<module>/` | Run tests for a specific module |
| `npm run test:unit -- --no-coverage` | Skip coverage report (faster) |
| `npm run test:integration -- --runInBand` | Integration tests (sequential, requires real DB + Redis) |
| `npm run test` | Run all tests (unit + integration, sequential) |
| `npm run typecheck` | TypeScript type checking (no emit) |
| `npm run lint` | ESLint check |
| `npm run lint:fix` | ESLint auto-fix |

## Mock Patterns

### Mocking the Prisma client

```typescript
const mockDb = {
  contact: {
    create: jest.fn(),
    findFirst: jest.fn(),
    findMany: jest.fn(),
    update: jest.fn(),
    count: jest.fn(),
  },
  $transaction: jest.fn(),
} as unknown as PrismaClient

beforeEach(() => jest.clearAllMocks())
```

### Mocking BullMQ queues

Queue interactions are tested indirectly. Service functions accept a `db`
parameter (dependency injection), and queue side effects are verified in
integration tests. Unit tests focus on the service logic and database calls.

## Iteration

Repeat the RED-GREEN-REFACTOR cycle for each function or behavior within a
module. A typical module task involves 3-8 cycles:

1. Schema validation (if complex)
2. Create operation
3. Read (single) operation
4. Read (list) with pagination/filtering
5. Update operation
6. Soft-delete operation
7. Edge cases (duplicate detection, score deltas, filter evaluation)

After all cycles pass, proceed to Phase C (real-life verification).
