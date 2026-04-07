# Task 00: Pre-Implementation Setup

**Depends on:** none
**Parallel with:** none
**Blocks:** 01
**Outputs:** modified `CLAUDE.md`, created `backend/.env`, created `backend/.gitignore`, created volume directories
**Verifies:** Node 24, Docker, and Docker Compose are installed; MCP config is updated; `.env` and `.gitignore` exist; volume directories are present
**Estimated context:** ~150 lines

## Intent

Prepare the local development environment before any code is written. This task
verifies toolchain prerequisites (Node 24, Docker, Docker Compose), deactivates
MCP server references that are irrelevant to Phase 1 (Twenty CRM, Mautic),
creates the backend environment file and gitignore, and sets up Docker volume
directories.

## Prerequisites check

- Node.js 24.x and npm 10+ are installed locally
- Docker and Docker Compose (v2) are installed and running
- The repository is cloned and you are on the `main` branch
- No uncommitted changes in the working tree

## Steps

### Step 0.1: Verify local environment

```bash
node --version   # Should be v24.x.x
npm --version    # Should be v10+
docker --version
docker-compose --version
```

Expected: All commands succeed. If Node 24 not installed, halt and install before
proceeding.

### Step 0.2: Update `CLAUDE.md` — deactivate irrelevant MCPs

Open `CLAUDE.md`. Under the `## MCP servers available` section, comment out or
remove references to `twenty-crm` and `mautic`. They're not part of Phase 1
(we're replacing Mautic, not integrating with it).

```markdown
## MCP servers available
<!-- DEACTIVATED FOR PHASE 1:
- twenty-crm: Twenty CRM API (not part of sales-engine)
- mautic: Mautic API via mantic-MCP (being replaced by sales-engine)
-->

- context7: Library documentation (npx @upstash/context7-mcp)
- waha: WAHA WhatsApp API (configure WAHA_API_KEY after first run)
- n8n: n8n workflow API via n8n-mcp-server (configure N8N_API_KEY after first run)
- n8n-docs: n8n documentation via n8n-mcp
- openapi-bridge: Generic OpenAPI-to-MCP bridge for any tool's Swagger spec
```

### Step 0.3: Create `backend/.env` for local development

```bash
# Database
DATABASE_URL="postgresql://salesengine:changeme@localhost:2360/salesengine"
REDIS_URL="redis://localhost:2361"

# Server
PORT=3000
HOST=0.0.0.0
NODE_ENV=development
LOG_LEVEL=debug

# Secrets (generate these with: openssl rand -base64 32)
SENTRY_DSN=""

# Webhook signing secrets (for local testing)
WAHA_WEBHOOK_SECRET="test-waha-secret"
CAL_WEBHOOK_SECRET="test-cal-secret"
EMAIL_PROVIDER_WEBHOOK_SECRET="test-email-secret"

# n8n integration (set after n8n is running)
N8N_BASE_URL="http://localhost:2353"
N8N_API_KEY="test"
```

### Step 0.4: Create `backend/.gitignore`

```
# Dependencies
node_modules/
.pnp
.pnp.js

# Production
dist/
build/

# Environment
.env
.env.local
.env.*.local

# Testing
coverage/
.nyc_output/

# IDE
.vscode/
.idea/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Logs
logs/
*.log
npm-debug.log*
yarn-debug.log*

# Prisma
prisma/migrations/
```

### Step 0.5: Create required volume directories

```bash
mkdir -p volumes/sales-db volumes/sales-redis volumes/sales-minio volumes/prometheus volumes/grafana volumes/loki volumes/metabase
```

Expected: All directories created without errors.

### Step 0.6: Commit pre-setup

```bash
git add CLAUDE.md backend/.env backend/.gitignore
git commit -m "chore: pre-setup for Phase 1 — deactivate MCPs, add env template, create volume dirs"
```

## Phase C verification

> See `shared/phase-c-template.md` for the general verification procedure.

Task 00 has no API endpoints or database tables. Verification is limited to:

- [ ] `node --version` outputs v24.x.x
- [ ] `npm --version` outputs v10+
- [ ] `docker --version` succeeds
- [ ] `docker compose version` succeeds
- [ ] `CLAUDE.md` no longer lists `twenty-crm` or `mautic` as active MCPs
- [ ] `backend/.env` exists and contains `DATABASE_URL` and `REDIS_URL`
- [ ] `backend/.gitignore` exists and includes `node_modules/`, `dist/`, `.env`
- [ ] All volume directories exist under `volumes/`

## Commit

```
chore: pre-setup for Phase 1 — deactivate MCPs, add env template, create volume dirs
```
