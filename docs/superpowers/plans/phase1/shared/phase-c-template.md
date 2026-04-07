# Phase C: Real-Life Verification Template

> Every module task follows this procedure BEFORE committing. Each task file
> references this template and lists only its SPECIFIC endpoints and scenarios.

## Prerequisites

1. Ensure `sales-db` and `sales-redis` containers are running and healthy:

```bash
docker compose up -d sales-db sales-redis
# Wait for health checks (30-60 sec)
docker compose ps  # Both should show "healthy"
```

2. Start the dev API server in a separate terminal:

```bash
cd backend && npm run dev:api
```

   The server should log `Sales Engine API started` with no connection errors.
   For tasks that include BullMQ workers, also start the worker:

```bash
cd backend && npm run dev:worker
```

## Verification Steps

### Step 1: Happy-path testing

Make actual HTTP requests against the running server using `curl`. For each
endpoint the task introduces, verify:

- Correct HTTP status code (201 for creation, 200 for retrieval, 204 for
  deletion, 202 for async jobs)
- Response body matches the expected schema (correct fields, types, nesting)
- IDs are valid UUIDs
- Timestamps are ISO 8601 strings

### Step 2: Unhappy-path testing

For every endpoint, test at least these failure modes:

| Scenario | Expected status | Expected error code |
|----------|----------------|---------------------|
| Missing required fields in POST/PATCH body | 400 | `VALIDATION_ERROR` |
| Non-existent resource ID (random UUID) | 404 | `NOT_FOUND` |
| Missing `Authorization` header | 401 | `UNAUTHORIZED` |
| Invalid `Authorization` header value | 401 | `UNAUTHORIZED` |
| Duplicate unique constraint (where applicable) | 409 | `CONFLICT` |

Use a known non-existent UUID for 404 testing:

```bash
curl http://localhost:2359/api/<resource>/00000000-0000-0000-0000-000000000000 \
  -H "Authorization: Bearer $API_KEY"
# Expected: 404 {"error":{"code":"NOT_FOUND","message":"..."}}
```

### Step 3: Database state verification

Connect to `sales-db` and confirm rows were created, updated, or soft-deleted:

```bash
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, created_at, deleted_at FROM <table_name> ORDER BY created_at DESC LIMIT 5;"
```

Verify:
- New rows exist after POST
- Updated fields reflect PATCH changes
- `deleted_at` is set (not NULL) after DELETE (soft-delete)
- No orphaned rows or missing foreign key references

### Step 4: Log verification

Check the API server terminal for Pino structured JSON log output:

- Each request should produce a log line with `method`, `url`, `status`, and
  `duration` fields
- Error responses (4xx/5xx) should include error details
- No unexpected stack traces or unhandled promise rejections

### Step 5: Document results

After completing verification, record a checklist of what was verified. Example:

```
- [ ] POST /api/<resource> creates resource with valid input
- [ ] GET /api/<resource> lists all non-deleted resources
- [ ] GET /api/<resource>/:id retrieves single resource
- [ ] PATCH /api/<resource>/:id updates resource
- [ ] PATCH /api/<resource>/:id rejects invalid input (400)
- [ ] DELETE /api/<resource>/:id soft-deletes resource (404 after)
- [ ] Non-existent ID returns 404
- [ ] Missing auth returns 401
- [ ] DB reflects all changes (actual PostgreSQL rows)
- [ ] Logs show structured request/response entries
```

## API Key Setup (one-time)

If no API key exists yet, create one before testing authenticated endpoints:

```bash
API_KEY="sk_live_test1234567890"
PREFIX="${API_KEY:0:8}"
HASH=$(echo -n "$API_KEY" | openssl dgst -sha256 -hex | awk '{print $2}')

docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "INSERT INTO api_keys (id, name, key_hash, key_prefix, scopes) \
   VALUES (gen_random_uuid(), 'test-key', '$HASH', '$PREFIX', \
   '{contacts:read,contacts:write,companies:read,companies:write,campaigns:write,segments:write}');"
```

Then use in all curl commands:

```bash
curl -H "Authorization: Bearer $API_KEY" http://localhost:2359/api/...
```

## Notes

- The dev server runs on port 3000 internally. When testing via Docker Compose,
  the external port is 2359 (mapped in `docker-compose.yml`). When testing with
  `npm run dev:api` directly, use port 3000.
- Phase C is not a substitute for unit tests. It complements them by validating
  the full request lifecycle: HTTP parsing, auth, validation, service logic,
  database I/O, and response serialization.
- If Phase C reveals issues, fix them and re-run the relevant unit tests before
  proceeding to commit.
