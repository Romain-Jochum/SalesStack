# Task 18: Config Files

**Depends on:** 16
**Parallel with:** 17
**Blocks:** 19
**Outputs:** `config/prometheus/prometheus.yml`, `config/loki/loki.yml`, `config/grafana/provisioning/datasources/datasources.yml`, `config/grafana/provisioning/dashboards/dashboards.yml`, `scripts/db-init.sql`
**Verifies:** Prometheus scrapes /metrics, Grafana datasources configured, Metabase can connect, db-init runs once
**Estimated context:** ~120 lines

## Intent

Create the supporting configuration files that the Docker Compose observability stack (Prometheus, Loki, Grafana) and the database initialization script depend on. These files are mounted as volumes by the compose services defined in Task 17. Prometheus is configured to scrape the Sales Engine API metrics endpoint, Loki provides centralized log aggregation, Grafana auto-provisions both as datasources, and the db-init script creates a read-only PostgreSQL user for Metabase analytics.

## Prerequisites check

- Task 16 (Dockerfile + entrypoint) is committed: `backend/Dockerfile` and `backend/docker-entrypoint.sh` exist.
- Task 17 (Docker Compose) is in progress or committed (can be parallel, but compose references these config paths).
- `sales-db` and `sales-redis` containers can be started from docker-compose.yml.

## Steps

### Step 18.1: Create `config/prometheus/prometheus.yml`

Copy the Prometheus configuration from the extracted artifact:

```
artifacts/prometheus.yml -> config/prometheus/prometheus.yml
```

See `artifacts/prometheus.yml` for the full content. Configures:

- 15-second scrape and evaluation interval.
- `sales-api` job targeting the API container on port 3000 at `/metrics`.
- `prometheus` self-scrape job on `localhost:9090`.

### Step 18.2: Create `config/loki/loki.yml`

Copy the Loki configuration from the extracted artifact:

```
artifacts/loki.yml -> config/loki/loki.yml
```

See `artifacts/loki.yml` for the full content. Configures:

- HTTP on port 3100, gRPC on port 9096.
- Filesystem-based chunk and rule storage under `/loki`.
- In-memory KV store with replication factor 1 (single-node).
- boltdb-shipper index with v12 schema and 24h period.

### Step 18.3: Create `config/grafana/provisioning/datasources/datasources.yml`

Copy the Grafana datasource provisioning from the extracted artifact:

```
artifacts/grafana-datasources.yml -> config/grafana/provisioning/datasources/datasources.yml
```

See `artifacts/grafana-datasources.yml` for the full content. Auto-provisions:

- **Prometheus** datasource (default) at `http://prometheus:9090`.
- **Loki** datasource at `http://loki:3100`.

### Step 18.4: Create `config/grafana/provisioning/dashboards/dashboards.yml`

```yaml
apiVersion: 1

providers:
  - name: Default
    folder: Sales Engine
    type: file
    options:
      path: /etc/grafana/provisioning/dashboards
```

This tells Grafana to load any JSON dashboard files placed in the provisioning directory. Actual dashboards will be added in later phases.

### Step 18.5: Create `scripts/db-init.sql`

```sql
-- Create a read-only user for Metabase
-- This script is run by the sales-db container on first init
-- via docker-entrypoint-initdb.d/

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'metabase_ro') THEN
    CREATE USER metabase_ro;
  END IF;
END
$$;

-- Password is set via ALTER USER to avoid issues with special chars
-- The actual password must be set manually or via a migration after init:
-- ALTER USER metabase_ro WITH PASSWORD '...';

GRANT CONNECT ON DATABASE salesengine TO metabase_ro;
GRANT USAGE ON SCHEMA public TO metabase_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO metabase_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO metabase_ro;
```

**Note:** The `metabase_ro` password must be set after container initialization:

```bash
docker compose exec sales-db psql -U salesengine -c "ALTER USER metabase_ro WITH PASSWORD 'your_metabase_db_pass';"
```

Match the password with `METABASE_DB_PASS` in `.env`.

### Step 18.6: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern.

```bash
# Test 1: Prometheus config is valid YAML and scrapes sales-api
docker compose up -d prometheus
docker compose logs prometheus | grep "sales-api"
# Expected: no config errors, target registered

# Test 2: Prometheus can reach /metrics
curl -s http://127.0.0.1:2365/api/v1/targets | grep -o '"health":"up"'
# Expected: sales-api target shows health "up" (requires sales-api running)

# Test 3: Loki starts without config errors
docker compose --profile phase2 up -d loki
docker compose logs loki | grep "ready"
# Expected: Loki reports ready, no config parse errors

# Test 4: Grafana provisions datasources automatically
docker compose --profile phase2 up -d grafana
curl -s http://127.0.0.1:2366/api/datasources | grep -o '"name":"Prometheus"'
# Expected: both Prometheus and Loki datasources present

# Test 5: db-init.sql creates metabase_ro user (fresh DB only)
docker compose down -v && docker compose up -d sales-db
docker compose exec sales-db psql -U salesengine -c "SELECT rolname FROM pg_roles WHERE rolname='metabase_ro';"
# Expected: metabase_ro row returned

# Test 6: metabase_ro has SELECT-only access
docker compose exec sales-db psql -U salesengine -c "\dp"
# Expected: metabase_ro has SELECT privileges on public tables
```

Specific verifications for this task:

- [ ] Prometheus config parses without errors and registers sales-api target
- [ ] Prometheus scrapes /metrics endpoint successfully when sales-api is running
- [ ] Loki config parses and Loki starts in single-node mode
- [ ] Grafana auto-provisions Prometheus and Loki datasources on startup
- [ ] Dashboard provider config is valid (no Grafana startup errors)
- [ ] db-init.sql creates metabase_ro user idempotently (IF NOT EXISTS)
- [ ] metabase_ro has SELECT-only privileges on public schema

## Commit

```bash
git add config/ scripts/db-init.sql
git commit -m "chore: add Prometheus, Loki, Grafana, and db-init.sql configs"
```

See `shared/commit-conventions.md` for formatting rules.
