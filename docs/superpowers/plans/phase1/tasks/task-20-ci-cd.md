# Task 20: GitHub Actions CI/CD

**Depends on:** 19
**Parallel with:** none
**Blocks:** 21
**Outputs:** `.github/workflows/ci.yml`
**Verifies:** Lint job passes, test job passes with coverage, Docker build succeeds on main, artifact uploaded
**Estimated context:** ~80 lines

## Intent

Create the GitHub Actions CI pipeline that runs on every pull request and push to `main`. The workflow has three jobs: (1) lint + typecheck, which runs ESLint, `tsc --noEmit`, and `prisma validate`; (2) unit tests with coverage, which generates the Prisma client and runs `test:unit --coverage`, uploading the coverage report as an artifact; and (3) Docker build + push to GHCR, which only runs on `main` after the first two jobs succeed. The pipeline uses BuildKit layer caching via `type=gha` for fast rebuilds and tags images with both `latest` and the commit SHA.

## Prerequisites check

- Task 19 (Docker Compose) is committed and the full stack starts with `docker compose up`.
- `npm run lint`, `npm run typecheck`, and `npm run test:unit` all pass locally.
- `docker build -t sales-engine:test backend/` succeeds locally.
- Repository is hosted on GitHub with GHCR (GitHub Container Registry) enabled.

## Steps

### Step 20.1: Create `.github/workflows/ci.yml`

Copy the workflow file verbatim from the extracted artifact:

```
artifacts/ci.yml -> .github/workflows/ci.yml
```

See `artifacts/ci.yml` for the full content. The three jobs are:

1. **lint-and-typecheck** -- Checkout, setup Node 24, `npm ci`, then run `lint`, `typecheck`, and `prisma validate`.
2. **test** -- Checkout, setup Node 24, `npm ci`, generate Prisma client, run `test:unit --coverage`, upload coverage artifact.
3. **build-docker** -- Runs only on `main` after lint and test pass. Uses `docker/setup-buildx-action`, logs into GHCR, builds and pushes the image with `latest` and SHA tags, with GHA layer caching.

Key design choices:

- Both `lint-and-typecheck` and `test` run in parallel (no `needs` dependency between them).
- `build-docker` uses `needs: [lint-and-typecheck, test]` so it only runs when both pass.
- `if: github.ref == 'refs/heads/main'` gates the Docker build to avoid pushing images from PRs.
- `cache-dependency-path: backend/package-lock.json` ensures npm caching works correctly in the monorepo layout.

### Step 20.2: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern. This task verifies CI infrastructure rather than HTTP endpoints.

```bash
# Test 1: Validate the workflow YAML syntax
cd /Users/rj/Work/Slotwise/sales-engine
cat .github/workflows/ci.yml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin)" && echo "Valid YAML"
# Expected: "Valid YAML"

# Test 2: Verify lint passes locally (mirrors lint-and-typecheck job)
cd backend && npm run lint && npm run typecheck && npx prisma validate
# Expected: all three pass with no errors

# Test 3: Verify tests pass with coverage (mirrors test job)
cd backend && npx prisma generate && npm run test:unit -- --coverage
# Expected: all tests pass, coverage/ directory created

# Test 4: Verify Docker build succeeds (mirrors build-docker job)
cd backend && docker build -t sales-engine:ci-test .
# Expected: multi-stage build completes, no errors

# Test 5: Push to GitHub and observe pipeline execution
git push origin main
# Expected: GitHub Actions runs all three jobs; lint-and-typecheck and test run
# in parallel, build-docker runs after both succeed. All jobs green.
```

Specific verifications for this task:

- [ ] `.github/workflows/ci.yml` is valid YAML
- [ ] Workflow triggers on `pull_request` to `main` and `push` to `main`
- [ ] `lint-and-typecheck` job runs lint, typecheck, and prisma validate
- [ ] `test` job generates Prisma client, runs unit tests with coverage, uploads artifact
- [ ] `build-docker` job only runs on `main` (gated by `if` condition)
- [ ] `build-docker` depends on both lint and test jobs passing
- [ ] Docker image is tagged with both `latest` and commit SHA
- [ ] GHA cache is configured for both npm and Docker layers

## Commit

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions pipeline (lint, typecheck, test, Docker build)"
```

See `shared/commit-conventions.md` for formatting rules.
