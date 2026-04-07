# Task 21: End-to-End Smoke Test

**Depends on:** 20
**Parallel with:** none
**Blocks:** none (final task)
**Outputs:** `backend/README.md`, full stack verification
**Verifies:** Full stack boots, contacts + companies + campaigns CRUD work, webhooks ingest, n8n integrates, Grafana loads
**Estimated context:** ~450 lines

## Intent

This is the final task in Phase 1 and serves as the comprehensive Phase C
verification for the entire stack. It boots all Phase 1 services via Docker
Compose, validates health endpoints, exercises the full CRUD lifecycle for
contacts/companies/campaigns, tests webhook ingestion with HMAC signatures,
confirms n8n can orchestrate multi-step workflows against the API, verifies
Grafana and Prometheus load correctly, and produces the `backend/README.md`
developer setup guide as the final deliverable.

Task 21.5 (Integration Tests) is folded into this task. Any integration test
setup with Testcontainers that was planned separately is included here.

## Prerequisites check

- Task 20 (CI/CD) is committed and the GitHub Actions workflow exists.
- All Phase 1 modules (Tasks 4-15) are implemented, tested, and committed.
- Docker image builds successfully (Task 16).
- `docker-compose.yml` defines all Phase 1 services (Task 17).
- Environment variable validation works (Task 19).
- `.env` file exists with all required variables.

## Steps

### Step 21.1: Start the full stack

```bash
# Generate secrets if .env doesn't have SALES_PG_PASSWORD yet
openssl rand -hex 24  # paste as SALES_PG_PASSWORD
openssl rand -base64 32  # paste as WAHA_WEBHOOK_SECRET
openssl rand -base64 32  # paste as CAL_WEBHOOK_SECRET

# Start Phase 1 services only
docker compose up -d sales-db sales-redis sales-api sales-worker
```

Expected: all 4 containers healthy within 60 seconds.

### Step 21.2: Verify health endpoints

```bash
curl http://localhost:2359/health
# Expected: {"status":"ok","uptime":...}

curl http://localhost:2359/ready
# Expected: {"status":"ready","db":"ok","redis":"ok"}
```

### Step 21.3: Create an API key in the database

```bash
# Generate key
KEY="sk_live_$(openssl rand -hex 12)"
PREFIX="${KEY:0:8}"
HASH=$(echo -n "$KEY" | openssl dgst -sha256 -hex | awk '{print $2}')

docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "INSERT INTO api_keys (id, name, key_hash, key_prefix, scopes) \
   VALUES (gen_random_uuid(), 'n8n-integration', '$HASH', '$PREFIX', '{contacts:read,contacts:write,campaigns:write}');"

echo "Your API key: $KEY"
```

### Step 21.4: Test contact creation

```bash
API_KEY="sk_live_..."   # from step above

curl -X POST http://localhost:2359/api/contacts \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Alice","lastName":"Smith","email":"alice@test.com","jobTitle":"CTO"}'
```

Expected: `{"data":{"id":"...","firstName":"Alice","email":"alice@test.com",...}}`

### Step 21.5: Test contact retrieval

```bash
curl http://localhost:2359/api/contacts \
  -H "Authorization: Bearer $API_KEY"
```

Expected: `{"data":[{"id":"...","firstName":"Alice",...}],"meta":{"total":1,...}}`

### Step 21.6: Test Cal.com webhook ingestion

```bash
CAL_SECRET="${CAL_WEBHOOK_SECRET}"
PAYLOAD='{"triggerEvent":"BOOKING_CREATED","payload":{"uid":"booking123","attendees":[{"email":"alice@test.com","name":"Alice Smith"}]}}'
SIG=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$CAL_SECRET" -hex | awk '{print $2}')

curl -X POST http://localhost:2359/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: $SIG" \
  -d "$PAYLOAD"
```

Expected: `{"received":true}`

### Step 21.7: Start monitoring stack

```bash
docker compose up -d prometheus grafana loki sales-metabase
```

### Step 21.8: Verify Grafana loads

Open `http://localhost:2366` in browser. Login with admin / `GRAFANA_ADMIN_PASSWORD`.
Prometheus datasource should be pre-configured.

### Step 21.9: Create n8n test workflow

Log into n8n at `http://localhost:2353` (or your configured n8n instance).

Create a new workflow named "Sales Engine Phase 1 Test":

1. Add a **Trigger** node: Manual Trigger
2. Add an **HTTP Request** node:
   - Method: `POST`
   - URL: `http://sales-api:3000/api/contacts` (or `http://localhost:2359/api/contacts` if testing locally)
   - Authentication: Bearer token
   - Headers: `Content-Type: application/json`
   - Body:
   ```json
   {
     "firstName": "n8n-test",
     "lastName": "workflow",
     "email": "n8n-test@example.com",
     "jobTitle": "Test"
   }
   ```
   - Add Authorization header with your API key: `Bearer sk_live_...`

3. Add a **GET** HTTP Request node:
   - Method: `GET`
   - URL: `http://sales-api:3000/api/contacts`
   - Authentication: Same bearer token
   - Store the result

4. Save and execute the workflow

Expected results:
- POST returns `201 Created` with contact object
- GET returns `200 OK` with contact list containing the newly created contact

Document what was verified:
- n8n can authenticate to Sales Engine API with Bearer token
- POST /api/contacts successfully creates contact from n8n
- GET /api/contacts returns created contact
- API responses are compatible with n8n HTTP nodes
- Multi-step workflow execution succeeds (POST followed by GET)

Save the workflow in n8n for future regression testing.

### Step 21.10: Create `backend/README.md`

Create `backend/README.md` with the following content:

```markdown
# Sales Engine Backend

A high-performance, solo-maintainable outreach platform built with Fastify, Prisma, and BullMQ.

## Quick Start

### Prerequisites

- Node.js 24 LTS
- Docker & Docker Compose v2
- PostgreSQL 18+ (via Docker Compose)
- Redis 7+ (via Docker Compose)

### Local Development

1. **Clone and install dependencies:**

```bash
cd backend
npm install
```

2. **Set up environment variables:**

Create a `.env` file in `backend/` with:

```bash
NODE_ENV=development
DATABASE_URL="postgresql://salesengine:changeme@localhost:2360/salesengine"
REDIS_URL="redis://localhost:2361"
PORT=3000
LOG_LEVEL=info
SENTRY_DSN=  # Optional
WAHA_WEBHOOK_SECRET=$(openssl rand -base64 32)
CAL_WEBHOOK_SECRET=$(openssl rand -base64 32)
EMAIL_PROVIDER_WEBHOOK_SECRET=$(openssl rand -base64 32)
```

3. **Start the infrastructure stack:**

From the repo root:

```bash
docker compose up -d sales-db sales-redis
```

Wait for health checks (30-60 seconds).

4. **Run migrations and generate Prisma client:**

```bash
cd backend
npx prisma migrate dev
npx prisma generate
```

5. **Start the API server:**

Development mode (with auto-reload):
```bash
npm run dev:api
```

Or production mode:
```bash
npm run build && npm start
```

6. **Verify it's running:**

```bash
curl http://localhost:3000/health
# Expected: {"status":"ok","uptime":...}
```

## Creating API Keys

To call the API, you need an API key stored in the database:

```bash
# Generate a new API key
KEY="sk_live_$(openssl rand -hex 12)"
PREFIX="${KEY:0:8}"
HASH=$(echo -n "$KEY" | openssl dgst -sha256 -hex | awk '{print $2}')

# Insert into database
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "INSERT INTO api_keys (id, name, key_hash, key_prefix, scopes) \
   VALUES (gen_random_uuid(), 'my-key', '$HASH', '$PREFIX', '{contacts:read,contacts:write}');"

echo "Your API key: $KEY"

# Use it in requests
curl -H "Authorization: Bearer $KEY" http://localhost:3000/api/contacts
```

## Testing

### Unit Tests

```bash
npm run test:unit
```

### Integration Tests (requires real DB + Redis)

```bash
npm run test:integration
```

### All Tests

```bash
npm test
```

## Linting & Type Checking

```bash
npm run lint      # ESLint
npm run typecheck # TypeScript
```

## Workers

Run BullMQ workers for async jobs:

```bash
npm run dev:worker
```

Workers process:
- Webhook ingestion -> Engagement events
- Segment evaluation -> Membership updates
- Bulk operations -> Asynchronous job queues

## Monitoring

### Prometheus Metrics

Metrics are exposed at `GET /metrics` (Prometheus text format).

Start Prometheus + Grafana:

```bash
docker compose up -d prometheus grafana
```

Then open `http://localhost:2366` (Grafana).

### Database

Prisma Studio (web interface):

```bash
npx prisma studio
```

Opens at `http://localhost:5555`

### Health Check

```bash
curl http://localhost:3000/health    # Liveness probe
curl http://localhost:3000/ready     # Readiness probe (includes DB + Redis)
```

## Architecture

- **Vertical slices:** Each module (contacts, campaigns, segments, etc.) is self-contained
- **API-first:** All business logic exposed via REST + Fastify schemas
- **Async-by-default:** BullMQ workers process webhooks, segment evaluation, bulk operations
- **Pointer pattern:** Webhook payloads stored once, jobs reference by ID (not duplicated)
- **Engagement scoring:** Automatic score deltas on webhook events
- **Filter engine:** Dynamic segment membership based on AST evaluation

## Deployment

### Docker

```bash
docker build -t sales-engine:latest backend/
```

Two containers share one image, differentiated by `ROLE`:

- `ROLE=api` -> Fastify server (migrations run at startup)
- `ROLE=worker` -> BullMQ worker processes

See `docker-compose.yml` for full stack.

### Environment Variables

See `.env.example` for all required variables.

## Contributing

- Follow Conventional Commits format: `feat:`, `chore:`, `fix:`, `test:`
- Pre-commit hooks enforce linting (ESLint + Prettier)
- All tests must pass before merging
- Phase C verification required: run code against real DB, test happy + unhappy paths
- JSDoc on all exported functions

## API Endpoints (Phase 1)

### Contacts
- `GET /api/contacts` -- List
- `POST /api/contacts` -- Create
- `GET /api/contacts/:id` -- Get
- `PATCH /api/contacts/:id` -- Update
- `DELETE /api/contacts/:id` -- Soft delete
- `POST /api/contacts/bulk` -- Bulk upsert

### Companies
- `GET /api/companies` -- List
- `POST /api/companies` -- Create
- `GET /api/companies/:id` -- Get
- `GET /api/companies/:id/contacts` -- Contacts at company
- `PATCH /api/companies/:id` -- Update
- `DELETE /api/companies/:id` -- Soft delete

### Segments
- `GET /api/segments` -- List
- `POST /api/segments` -- Create (with filter rules)
- `GET /api/segments/:id/contacts` -- Members
- `POST /api/segments/:id/contacts/:contactId` -- Add member
- `DELETE /api/segments/:id/contacts/:contactId` -- Remove member
- `POST /api/segments/evaluate` -- Trigger evaluation

### Campaigns
- `GET /api/campaigns` -- List
- `POST /api/campaigns` -- Create
- `GET /api/campaigns/:id` -- Get
- `PATCH /api/campaigns/:id` -- Update
- `POST /api/campaigns/:id/enroll` -- Enroll contact
- `GET /api/campaigns/:id/contacts` -- Enrolled contacts

### Engagements
- `POST /api/engagements` -- Log single event
- `POST /api/engagements/bulk` -- Queue bulk events

### Webhooks
- `POST /api/webhooks/cal` -- Cal.com bookings
- `POST /api/webhooks/waha` -- WhatsApp messages
- `POST /api/webhooks/email` -- Email events (Postmark, Mailgun)

### Other
- `GET /health` -- Liveness
- `GET /ready` -- Readiness (DB + Redis check)
- `GET /metrics` -- Prometheus metrics
- `GET /api/jobs/:jobId` -- Job status

## Troubleshooting

### "Cannot connect to database"
- Ensure `sales-db` container is healthy: `docker compose ps`
- Check `DATABASE_URL` in `.env`
- Migrations not run: `npx prisma migrate dev`

### "Cannot connect to Redis"
- Ensure `sales-redis` container is healthy: `docker compose ps`
- Check `REDIS_URL` in `.env`

### Tests failing
- Clear node_modules and reinstall: `npm install`
- Regenerate Prisma client: `npx prisma generate`
- Check that DB migrations are applied

### Port conflicts
- Default ports: API=3000, DB=2360, Redis=2361
- Change in `.env` or `docker-compose.yml`

## Phase 2 (Research Engine)

Phase 1 provides the foundation. Phase 2 will add:
- Research job orchestration (FireCrawl, Apollo, LLM enrichment)
- Data lineage tracking (sources -> contacts)
- MinIO document storage
- Entity relationship mapping

See `docs/superpowers/specs/` for Phase 2 design documents.
```

## Phase C verification

This task IS Phase C -- the entire task is the end-to-end verification of the
full Phase 1 stack. The steps above (21.1 through 21.9) constitute the Phase C
checklist. Record results in the execution log.

Summary checklist:

- [ ] All 4 Phase 1 containers boot and become healthy within 60 seconds
- [ ] `GET /health` returns `{"status":"ok"}`
- [ ] `GET /ready` returns `{"status":"ready","db":"ok","redis":"ok"}`
- [ ] API key creation and authentication works end-to-end
- [ ] `POST /api/contacts` creates a contact with valid input
- [ ] `GET /api/contacts` lists contacts with pagination metadata
- [ ] `POST /api/webhooks/cal` accepts HMAC-signed Cal.com webhook payload
- [ ] Prometheus scrapes metrics from `GET /metrics`
- [ ] Grafana loads and displays Prometheus datasource
- [ ] n8n workflow can POST and GET contacts via Bearer token auth
- [ ] n8n multi-step workflow executes successfully
- [ ] `backend/README.md` is accurate and complete

## Commit

```bash
git add backend/README.md
git commit -m "docs: add backend/README.md with setup, testing, monitoring, and API reference"
```
