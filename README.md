# SalesStack

Self-hosted sales outreach stack running on Docker Compose. Four tools, one network, one command to start.

| Service | Purpose | Local URL |
|---------|---------|-----------|
| [Twenty CRM](https://twenty.com) | CRM / contact management | http://localhost:2350 |
| [Mautic](https://mautic.org) | Email marketing automation | http://localhost:2351 |
| [WAHA](https://waha.devlike.pro) | WhatsApp API (self-hosted) | http://localhost:2352 |
| [n8n](https://n8n.io) | Workflow automation hub | http://localhost:2353 |

## Quick start

```bash
# 1. Generate secrets
./scripts/generate-secrets.sh

# 2. Start the stack (11 containers)
./scripts/start.sh

# 3. Wait for healthy + print credentials
./scripts/post-deploy.sh
```

## Architecture

```
Twenty CRM  <── n8n ──>  Mautic  <── n8n ──>  WAHA
                 │
            (automation hub)
```

- **n8n** bridges Twenty CRM and Mautic (no native integration exists)
- **WAHA** connects to Mautic campaigns for WhatsApp outreach via n8n
- All services communicate over a shared Docker bridge network (`salesstack`)
- All host ports bind to `127.0.0.1` only — never publicly exposed

See [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) for the full integration architecture.

## Services (11 containers)

| Container | Image | Host Port |
|-----------|-------|-----------|
| twenty-server | twentycrm/twenty:v1.20.0 | 2350 |
| twenty-worker | twentycrm/twenty:v1.20.0 | — |
| twenty-db | postgres:16-alpine | 2354 |
| twenty-redis | redis:7-alpine | 2357 |
| mautic-web | mautic/mautic:7-apache | 2351 |
| mautic-cron | mautic/mautic:7-apache | — |
| mautic-worker | mautic/mautic:7-apache | — |
| mautic-db | mysql:latest | 2355 |
| waha | devlikeapro/waha:latest | 2352 |
| n8n | n8nio/n8n:2.12.3 | 2353 |
| n8n-db | postgres:16-alpine | 2356 |

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/generate-secrets.sh` | Generate all secrets, write `.env` and `.env.example` |
| `scripts/start.sh` | Start everything: `docker compose up -d` |
| `scripts/stop.sh` | Stop everything: `docker compose down` |
| `scripts/status.sh` | Show container status and URLs |
| `scripts/logs.sh` | Tail logs (pass service name to filter) |
| `scripts/post-deploy.sh` | Wait for healthy, print credentials and next steps |

## Production deployment

Works on macOS (local dev) and Linux (production) with the same compose files. Only `.env` values change (localhost URLs become real domains).

See [docs/DEPLOY.md](docs/DEPLOY.md) for the full deployment guide with Nginx reverse proxy configs.

## Requirements

- Docker Engine 24+ with Compose v2
- 8 GB RAM minimum (16 GB recommended)
