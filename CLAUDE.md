# Sales Stack Project — CLAUDE.md

## Project context
This project sets up a self-hosted sales outreach stack using Docker Compose.
The stack consists of: Twenty CRM, Mautic, WAHA (WhatsApp), and n8n.
All services run on a shared Docker bridge network called `salesstack`.

## Port allocation (host-side, bind to 127.0.0.1 only)
- 2350: Twenty CRM (internal 3000)
- 2351: Mautic (internal 80)
- 2352: WAHA (internal 3000)
- 2353: n8n (internal 5678)
- 2354: Twenty PostgreSQL (internal 5432)
- 2355: Mautic MySQL (internal 3306)
- 2356: n8n PostgreSQL (internal 5432)
- 2357: Twenty Redis (internal 6379)
- 2358-2399: Reserved for future services

## Key rules
- NEVER expose ports publicly. Always bind to 127.0.0.1.
- All inter-service communication uses Docker service names (e.g., http://twenty-server:3000).
- The stack must be portable: works on macOS locally and on a Linux server with the same compose files.
- On the production server, Nginx handles TLS/SSL and reverse proxying. This local setup has NO Nginx.
- Use `docker compose` (v2), not `docker-compose` (v1).
- Generate all secrets with `openssl rand -base64 32` — never use placeholder passwords.
- The PRD is at ./prd-setup.md — read it for the full integration architecture.

## Documentation access
- Use Context7 MCP to fetch docs: `use context7` for Docker, n8n, etc.
- Twenty CRM API docs: https://docs.twenty.com/developers/extend/capabilities/apis
- Twenty webhooks: https://docs.twenty.com/developers/extend/capabilities/webhooks
- Mautic API docs: https://developer.mautic.org/ and https://devdocs.mautic.org/
- WAHA docs: https://waha.devlike.pro/docs/overview/quick-start/
- n8n docs: https://docs.n8n.io/

## MCP servers available
- context7: Library documentation (npx @upstash/context7-mcp)
- twenty-crm: Twenty CRM API (configure TWENTY_API_KEY after first run)
- waha: WAHA WhatsApp API (configure WAHA_API_KEY after first run)
- mautic: Mautic API via mantic-MCP (configure OAuth2 credentials after first run)
- n8n: n8n workflow API via n8n-mcp-server (configure N8N_API_KEY after first run)
- n8n-docs: n8n documentation via n8n-mcp
- openapi-bridge: Generic OpenAPI-to-MCP bridge for any tool's Swagger spec

---

## Sales Engine Backend (Phase 1+)

Built alongside the existing stack. See `backend/` directory.

### Port allocation (new services)
- 2359: Sales Engine API (Fastify, internal 3000)
- 2360: Sales Engine PostgreSQL (pgvector/pgvector:pg18, internal 5432)
- 2361: Sales Engine Redis 7 (internal 6379)
- 2362: MinIO API (Phase 2, internal 9000)
- 2363: MinIO Console (Phase 2, internal 9001)
- 2365: Prometheus (internal 9090)
- 2366: Grafana (internal 3000)
- 2367: Loki (internal 3100)
- 2368: Metabase (internal 3000)

### Phase 1 plan
`docs/superpowers/plans/2026-04-05-sales-engine-phase1-revised.md`

### Phase 2/3 architecture
`docs/superpowers/specs/2026-04-05-phase2-phase3-architecture.md`

### Architectural decisions log
`docs/superpowers/decisions/`

### Key design principles (carry into all phases)
- Vertical slices: each module is `schemas.ts` + `service.ts` + `routes.ts`
- Pointer pattern: BullMQ jobs carry IDs, never raw payloads
- Exact dependency pinning: no `^` or `~` in package.json
- Phase C verification: every task requires real-environment testing before commit
- Tenant isolation: `tenantId` on every model, every query

### MCP status for Sales Engine implementation
- context7: Active — use for Fastify v5, Prisma v7, BullMQ v5.71+ docs
- n8n: Active (docs + live testing for smoke test Task 21)
- twenty-crm: Deactivated for Phase 1
- mautic: Deactivated for Phase 1
