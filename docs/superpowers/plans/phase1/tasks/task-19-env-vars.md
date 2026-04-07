# Task 19: Environment Variables

**Depends on:** 18
**Parallel with:** none
**Blocks:** 20
**Outputs:** `.env.example`
**Verifies:** All required vars documented, secrets flagged, port ranges reserved, example values safe
**Estimated context:** ~80 lines

## Intent

Populate `.env.example` with every environment variable the stack needs across
Phase 1 and placeholders for Phase 2. Secrets use `CHANGE_ME_*` sentinel values
so `grep CHANGE_ME` can audit before first deploy. Port assignments follow the
2350–2399 allocation table in the project CLAUDE.md.

## Prerequisites check

- Task 18 (Docker Compose) is committed: `docker-compose.yml` references these
  variables via `${VAR}` interpolation.
- The port allocation table (2350–2399) is agreed and documented.

## Steps

### Step 19.1: Add new variables to `.env.example`

Append the following blocks to the existing `.env.example`:

```bash
# ── Sales Engine ─────────────────────────────────────────────────────────────
SALES_PG_DB=salesengine
SALES_PG_USER=salesengine
SALES_PG_PASSWORD=CHANGE_ME_openssl_rand_hex_24
SALES_DB_PORT=2360
SALES_REDIS_PORT=2361
SALES_API_PORT=2359

# ── MinIO (Phase 2) ───────────────────────────────────────────────────────────
MINIO_ACCESS_KEY=CHANGE_ME_minio_access_key
MINIO_SECRET_KEY=CHANGE_ME_openssl_rand_base64_32
MINIO_API_PORT=2362
MINIO_CONSOLE_PORT=2363

# ── Monitoring ────────────────────────────────────────────────────────────────
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=CHANGE_ME_openssl_rand_base64_16
GRAFANA_PORT=2366
PROMETHEUS_PORT=2365
LOKI_PORT=2367

# ── Metabase ──────────────────────────────────────────────────────────────────
METABASE_PORT=2368
METABASE_DB_PASS=CHANGE_ME_openssl_rand_hex_16

# ── Webhooks ──────────────────────────────────────────────────────────────────
WAHA_WEBHOOK_SECRET=CHANGE_ME_openssl_rand_base64_32
CAL_WEBHOOK_SECRET=CHANGE_ME_openssl_rand_base64_32
EMAIL_PROVIDER_WEBHOOK_SECRET=CHANGE_ME_openssl_rand_base64_32

# ── External APIs (Phase 2) ───────────────────────────────────────────────────
ANTHROPIC_API_KEY=sk-ant-...
SENTRY_DSN=https://...@sentry.io/...
```

## Phase C verification

1. **Grep audit:** `grep CHANGE_ME .env.example` — confirm every secret has a
   `CHANGE_ME_*` sentinel, never a real credential.
2. **Port check:** verify all port values fall within the 2350–2399 reserved
   range documented in `CLAUDE.md`.
3. **No duplicates:** confirm no variable name appears twice in the file.
4. **Docker Compose reference:** run `docker compose config` and confirm it
   resolves all `${VAR}` references without warnings (requires `.env` copied
   from `.env.example`).

## Commit

```bash
git add .env.example
git commit -m "chore: add Phase 1 environment variables to .env.example"
```
