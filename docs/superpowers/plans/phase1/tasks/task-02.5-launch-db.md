# Task 02.5: Launch Database and Redis

**Depends on:** 02
**Parallel with:** none
**Blocks:** 03
**Outputs:** Running sales-db and sales-redis containers, migrations applied
**Verifies:** Both containers healthy, migrations applied, ready for Phase C testing in Tasks 4–13
**Estimated context:** ~33 lines

## Intent

Make sales-db and sales-redis available for Phase C (real-life verification) testing in Tasks 4–21. This is a critical gate — no module task can run Phase C without live database and Redis.

## Prerequisites check

- Task 02 complete (schema.prisma exists)
- Docker running
- docker-compose.yml has sales-db and sales-redis service definitions

## Steps

- [ ] **Step 2.5.1: Start services**

```bash
docker compose up -d sales-db sales-redis
```

Expected: Both containers running and healthy.

- [ ] **Step 2.5.2: Wait for databases to be ready**

```bash
sleep 10 && docker compose exec sales-db pg_isready -U salesengine && docker compose exec sales-redis redis-cli ping
```

Expected: Both commands return success.

- [ ] **Step 2.5.3: Run migrations in sales-db**

```bash
cd backend && npx prisma migrate deploy
```

Expected: All migrations applied successfully.

Keep these containers running throughout implementation. Database is now available for Phase C testing in Tasks 4–13.

## Phase C verification

- `pg_isready -U salesengine` returns success
- `redis-cli ping` returns PONG
- `npx prisma migrate deploy` applies all migrations
- Containers stay healthy for 60 seconds

## Commit

No commit needed — this task only starts containers and applies existing migrations.
