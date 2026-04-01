#!/bin/bash
set -e
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  echo "ERROR: .env already exists. Remove it first if you want to regenerate secrets."
  exit 1
fi

echo "Generating secrets..."

# Generate secrets
# URL-safe hex for passwords embedded in database connection URLs
TWENTY_PG_PASSWORD=$(openssl rand -hex 24)
MAUTIC_DB_PASSWORD=$(openssl rand -hex 24)
MAUTIC_DB_ROOT_PASSWORD=$(openssl rand -hex 24)
N8N_PG_PASSWORD=$(openssl rand -hex 24)
# base64 for standalone env vars (not embedded in URLs)
TWENTY_APP_SECRET=$(openssl rand -base64 32)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32)
WAHA_API_KEY=$(openssl rand -base64 32)
WAHA_DASHBOARD_PASSWORD=$(openssl rand -base64 32)

cat > .env << EOF
# =============================================================================
# Sales Stack Environment Configuration
# Generated on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

# !! PRODUCTION: Change these from localhost to your real domains !!
TWENTY_SERVER_URL=http://localhost:2350
MAUTIC_SITE_URL=http://localhost:2351
WAHA_BASE_URL=http://localhost:2352
N8N_WEBHOOK_URL=http://localhost:2353/

# -----------------------------------------------------------------------------
# Twenty CRM
# -----------------------------------------------------------------------------
TWENTY_IMAGE=twentycrm/twenty:v1.20.0
TWENTY_APP_SECRET=${TWENTY_APP_SECRET}
TWENTY_PG_DB=twenty
TWENTY_PG_USER=twenty
TWENTY_PG_PASSWORD=${TWENTY_PG_PASSWORD}
TWENTY_SIGN_IN_PREFILLED=true

# -----------------------------------------------------------------------------
# Mautic
# -----------------------------------------------------------------------------
MAUTIC_IMAGE=mautic/mautic:7-apache
MAUTIC_DB_NAME=mautic
MAUTIC_DB_USER=mautic
MAUTIC_DB_PASSWORD=${MAUTIC_DB_PASSWORD}
MAUTIC_DB_ROOT_PASSWORD=${MAUTIC_DB_ROOT_PASSWORD}

# -----------------------------------------------------------------------------
# WAHA (WhatsApp)
# -----------------------------------------------------------------------------
WAHA_IMAGE=devlikeapro/waha:latest
WAHA_API_KEY=${WAHA_API_KEY}
WAHA_DASHBOARD_USERNAME=admin
WAHA_DASHBOARD_PASSWORD=${WAHA_DASHBOARD_PASSWORD}

# -----------------------------------------------------------------------------
# n8n
# -----------------------------------------------------------------------------
N8N_IMAGE=docker.n8n.io/n8nio/n8n:2.12.3
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_PG_DB=n8n
N8N_PG_USER=n8n
N8N_PG_PASSWORD=${N8N_PG_PASSWORD}
N8N_TIMEZONE=Indian/Mauritius

# -----------------------------------------------------------------------------
# Ports
# -----------------------------------------------------------------------------
TWENTY_PORT=2350
MAUTIC_PORT=2351
WAHA_PORT=2352
N8N_PORT=2353
TWENTY_DB_PORT=2354
MAUTIC_DB_PORT=2355
N8N_DB_PORT=2356
TWENTY_REDIS_PORT=2357
EOF

echo "Generated .env with all secrets."

# Generate .env.example
cat > .env.example << 'EOF'
# =============================================================================
# Sales Stack Environment Configuration — TEMPLATE
# Copy to .env and fill in values, or run: ./scripts/generate-secrets.sh
# =============================================================================

# !! PRODUCTION: Change these from localhost to your real domains !!
TWENTY_SERVER_URL=http://localhost:2350
MAUTIC_SITE_URL=http://localhost:2351
WAHA_BASE_URL=http://localhost:2352
N8N_WEBHOOK_URL=http://localhost:2353/

# -----------------------------------------------------------------------------
# Twenty CRM
# -----------------------------------------------------------------------------
TWENTY_IMAGE=twentycrm/twenty:v1.20.0
TWENTY_APP_SECRET=CHANGE_ME
TWENTY_PG_DB=twenty
TWENTY_PG_USER=twenty
TWENTY_PG_PASSWORD=CHANGE_ME
TWENTY_SIGN_IN_PREFILLED=true

# -----------------------------------------------------------------------------
# Mautic
# -----------------------------------------------------------------------------
MAUTIC_IMAGE=mautic/mautic:7-apache
MAUTIC_DB_NAME=mautic
MAUTIC_DB_USER=mautic
MAUTIC_DB_PASSWORD=CHANGE_ME
MAUTIC_DB_ROOT_PASSWORD=CHANGE_ME

# -----------------------------------------------------------------------------
# WAHA (WhatsApp)
# -----------------------------------------------------------------------------
WAHA_IMAGE=devlikeapro/waha:latest
WAHA_API_KEY=CHANGE_ME
WAHA_DASHBOARD_USERNAME=admin
WAHA_DASHBOARD_PASSWORD=CHANGE_ME

# -----------------------------------------------------------------------------
# n8n
# -----------------------------------------------------------------------------
N8N_IMAGE=docker.n8n.io/n8nio/n8n:2.12.3
N8N_ENCRYPTION_KEY=CHANGE_ME
N8N_PG_DB=n8n
N8N_PG_USER=n8n
N8N_PG_PASSWORD=CHANGE_ME
N8N_TIMEZONE=Indian/Mauritius

# -----------------------------------------------------------------------------
# Ports
# -----------------------------------------------------------------------------
TWENTY_PORT=2350
MAUTIC_PORT=2351
WAHA_PORT=2352
N8N_PORT=2353
TWENTY_DB_PORT=2354
MAUTIC_DB_PORT=2355
N8N_DB_PORT=2356
TWENTY_REDIS_PORT=2357
EOF

echo "Generated .env.example template."
echo ""
echo "Done! Next: ./scripts/start.sh"
