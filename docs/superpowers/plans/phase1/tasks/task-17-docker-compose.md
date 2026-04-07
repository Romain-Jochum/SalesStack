# Task 17: Docker Compose Additions

**Depends on:** 16
**Parallel with:** 18
**Blocks:** 19
**Outputs:** `docker-compose.yml` (volumes + service definitions for sales-api, sales-worker, and supporting services)
**Verifies:** All Phase 1 containers (sales-db, sales-redis, sales-api, sales-worker) healthy, networking functional
**Estimated context:** ~100 lines

## Intent

Extend `docker-compose.yml` with all the service definitions needed for Phase 1 and beyond: the Sales Engine database (pgvector), Redis, API server, BullMQ worker, MinIO (Phase 2 profile), Prometheus, Grafana, Loki, and Metabase. Each service gets a named bind-mount volume under `volumes/`, health checks, and ports bound to the project's reserved port range (2359-2368). The API and worker containers share the same image built in Task 16, differentiated by the `ROLE` environment variable. Phase 2 services use Docker Compose profiles so they stay dormant until explicitly activated.

## Prerequisites check

- Task 16 (Dockerfile + entrypoint) is committed: `backend/Dockerfile` and `backend/docker-entrypoint.sh` exist.
- `docker build -t sales-engine:test backend/` succeeds.
- An existing `docker-compose.yml` is present with at least a `networks:` section defining `salesstack`.
- `scripts/start.sh` exists (created in an earlier task).

## Steps

### Step 17.1: Add new volumes to `docker-compose.yml`

In the `volumes:` section, add bind-mount volume definitions for all services:

- `sales-db-data` -- PostgreSQL data directory
- `sales-redis-data` -- Redis AOF persistence
- `sales-minio-data` -- MinIO object storage (Phase 2)
- `prometheus-data`, `grafana-data`, `loki-data` -- Monitoring stack
- `metabase-data` -- Business intelligence

Each volume uses `driver: local` with `type: none` and `o: bind`, pointing at `${PWD}/volumes/<name>`.

See `artifacts/docker-compose.snippet.yml` for the exact YAML to add.

### Step 17.2: Add new services to `docker-compose.yml`

Add the following service blocks after existing services. The full YAML is in `artifacts/docker-compose.snippet.yml` -- copy verbatim.

**Phase 1 services (always active):**

| Service | Image | Internal Port | Host Port | Health check |
|---|---|---|---|---|
| `sales-db` | `pgvector/pgvector:pg18` | 5432 | `${SALES_DB_PORT:-2360}` | `pg_isready` |
| `sales-redis` | `redis:7-alpine` | 6379 | `${SALES_REDIS_PORT:-2361}` | `redis-cli ping` |
| `sales-api` | `${SALES_IMAGE:-sales-engine:latest}` | 3000 | `${SALES_API_PORT:-2359}` | `curl /health` |
| `sales-worker` | `${SALES_IMAGE:-sales-engine:latest}` | -- | -- | -- |
| `prometheus` | `prom/prometheus:latest` | 9090 | `${PROMETHEUS_PORT:-2365}` | -- |

**Phase 2 / monitoring services:**

| Service | Image | Profile | Host Port |
|---|---|---|---|
| `sales-minio` | `minio/minio:latest` | `phase2` | `${MINIO_API_PORT:-2362}`, `${MINIO_CONSOLE_PORT:-2363}` |
| `grafana` | `grafana/grafana:latest` | -- | `${GRAFANA_PORT:-2366}` |
| `loki` | `grafana/loki:latest` | -- | `${LOKI_PORT:-2367}` |
| `sales-metabase` | `metabase/metabase:latest` | -- | `${METABASE_PORT:-2368}` |

Key details:

- `sales-api` and `sales-worker` both use `depends_on` with `condition: service_healthy` on `sales-db` and `sales-redis`.
- `sales-api` sets `ROLE: api`, `sales-worker` sets `ROLE: worker`.
- `sales-redis` runs with `--maxmemory 512mb --maxmemory-policy allkeys-lru --appendonly yes`.
- `sales-db` mounts `scripts/db-init.sql` into `/docker-entrypoint-initdb.d/`.

### Step 17.3: Update `scripts/start.sh` to create volume directories

Add to the `mkdir -p` section in `scripts/start.sh`:

```bash
mkdir -p volumes/sales-db volumes/sales-redis volumes/sales-minio \
         volumes/prometheus volumes/grafana volumes/loki volumes/metabase
```

### Step 17.4: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern.

```bash
# Test 1: Volume directories created
./scripts/start.sh
ls -d volumes/sales-db volumes/sales-redis volumes/prometheus
# Expected: all directories exist

# Test 2: Infrastructure containers start and become healthy
docker compose up -d sales-db sales-redis
docker compose ps
# Expected: sales-db (healthy), sales-redis (healthy)

# Test 3: API container starts, runs migrations, becomes healthy
docker compose up -d sales-api
docker compose logs -f sales-api  # wait for healthy
curl -f http://127.0.0.1:2359/health
# Expected: {"status":"ok", ...}

# Test 4: Worker container starts
docker compose up -d sales-worker
docker compose logs sales-worker
# Expected: "[entrypoint] ROLE=worker", "Starting BullMQ workers..."

# Test 5: Inter-service networking
docker compose exec sales-api sh -c 'curl -s http://sales-redis:6379 || echo "redis reachable"'
docker compose exec sales-api sh -c 'pg_isready -h sales-db -U salesengine || echo "check pg_isready"'
# Expected: services can resolve each other by Docker service name

# Test 6: Prometheus scrapes API metrics
docker compose up -d prometheus
curl -s http://127.0.0.1:2365/api/v1/targets | grep sales-api
# Expected: sales-api target is listed (may be "up" or "down" depending on config)
```

Specific verifications for this task:

- [ ] `docker compose config` validates without errors
- [ ] `sales-db` and `sales-redis` reach "healthy" status
- [ ] `sales-api` runs Prisma migrations on startup and responds on `/health`
- [ ] `sales-worker` starts BullMQ workers successfully
- [ ] All services are on the `salesstack` network and can resolve each other
- [ ] Port bindings match the port allocation table (2359-2368)
- [ ] Phase 2 services do not start without `--profile phase2`

## Commit

```bash
git add docker-compose.yml scripts/start.sh
git commit -m "feat: add sales-db, sales-redis, sales-api, sales-worker, monitoring, metabase to Docker Compose"
```

See `shared/commit-conventions.md` for formatting rules.
