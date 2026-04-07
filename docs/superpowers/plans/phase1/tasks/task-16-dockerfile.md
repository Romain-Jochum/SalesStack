# Task 16: Dockerfile + Entrypoint

**Depends on:** 15
**Parallel with:** none
**Blocks:** 17, 18
**Outputs:** `backend/Dockerfile`, `backend/docker-entrypoint.sh`
**Verifies:** Multi-stage build succeeds, image ~200MB, ROLE=api runs migrations, ROLE=worker starts workers
**Estimated context:** ~120 lines

## Intent

Create the multi-stage Dockerfile and ROLE-based entrypoint script that package the Sales Engine backend into a single production image serving both the API server and BullMQ worker roles. The Dockerfile uses four stages (base, deps, builder, runner) to produce a minimal Alpine image with only production dependencies. The entrypoint script reads the `ROLE` environment variable to decide whether to run Prisma migrations and start the API server (`api`) or launch the BullMQ worker process (`worker`), failing fast on any unrecognized role.

## Prerequisites check

- Task 15 (server entrypoint) is committed: `backend/src/server.ts` exists with `buildApp()` and `start()`.
- `npm run build` succeeds (TypeScript compiles to `dist/`).
- `npx prisma generate` succeeds (Prisma client generates).
- `sales-db` and `sales-redis` containers are running and healthy.

## Steps

### Step 16.1: Create `backend/Dockerfile`

Copy the Dockerfile verbatim from the extracted artifact:

```
artifacts/Dockerfile -> backend/Dockerfile
```

See `artifacts/Dockerfile` for the full content. The four stages are:

1. **base** -- Node 24 Alpine with openssl and curl.
2. **deps** -- `npm ci --frozen-lockfile` with all dependencies.
3. **builder** -- TypeScript compile + Prisma generate.
4. **runner** -- Production-only deps, compiled output, Prisma client, entrypoint.

### Step 16.2: Create `backend/docker-entrypoint.sh`

```bash
#!/bin/sh
set -e

echo "[entrypoint] ROLE=${ROLE}"

case "$ROLE" in
  api)
    echo "[entrypoint] Running Prisma migrations..."
    npx prisma migrate deploy
    echo "[entrypoint] Starting API server..."
    exec node dist/server.js
    ;;
  worker)
    echo "[entrypoint] Starting BullMQ workers..."
    exec node dist/workers/index.js
    ;;
  *)
    echo "[entrypoint] ERROR: ROLE must be 'api' or 'worker'. Got: '${ROLE}'"
    exit 1
    ;;
esac
```

### Step 16.3: Test Docker build locally

```bash
cd backend && docker build -t sales-engine:test .
```

Expected: successful multi-stage build, no errors. Final image should be approximately 200MB.

### Step 16.4: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern.

```bash
# Test 1: Image builds successfully
docker build -t sales-engine:test backend/
# Expected: all 4 stages complete, no errors

# Test 2: Check image size
docker images sales-engine:test --format '{{.Size}}'
# Expected: ~200MB (under 300MB is acceptable)

# Test 3: ROLE=api starts correctly (requires DB + Redis)
docker run --rm -e ROLE=api -e DATABASE_URL="..." -e REDIS_URL="..." sales-engine:test
# Expected: "[entrypoint] ROLE=api", runs migrations, "Sales Engine API started"

# Test 4: ROLE=worker starts correctly (requires Redis)
docker run --rm -e ROLE=worker -e DATABASE_URL="..." -e REDIS_URL="..." sales-engine:test
# Expected: "[entrypoint] ROLE=worker", "Starting BullMQ workers..."

# Test 5: Invalid ROLE fails fast
docker run --rm -e ROLE=invalid sales-engine:test
# Expected: "[entrypoint] ERROR: ROLE must be 'api' or 'worker'. Got: 'invalid'", exit 1

# Test 6: Missing ROLE fails fast
docker run --rm sales-engine:test
# Expected: "[entrypoint] ERROR: ROLE must be 'api' or 'worker'. Got: ''", exit 1
```

Specific verifications for this task:

- [ ] Docker build completes all 4 stages without errors
- [ ] Final image size is under 300MB
- [ ] ROLE=api runs `prisma migrate deploy` then `node dist/server.js`
- [ ] ROLE=worker runs `node dist/workers/index.js`
- [ ] Invalid or missing ROLE prints error and exits with code 1
- [ ] Entrypoint uses `exec` so Node receives signals directly (graceful shutdown)

## Commit

```bash
git add backend/Dockerfile backend/docker-entrypoint.sh
git commit -m "chore: add multi-stage Dockerfile and ROLE-based entrypoint"
```

See `shared/commit-conventions.md` for formatting rules.
