#!/bin/bash
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ERROR: No .env found."
  exit 1
fi

# shellcheck disable=SC1091
source .env

echo "=== Waiting for services to become healthy ==="
echo ""

SERVICES="twenty-db twenty-redis mautic-db n8n-db twenty-server mautic-web waha n8n"
MAX_WAIT=300
ELAPSED=0

all_healthy() {
  for svc in $SERVICES; do
    status=$(docker compose ps --format '{{.Health}}' "$svc" 2>/dev/null)
    if [ "$status" != "healthy" ]; then
      return 1
    fi
  done
  return 0
}

while ! all_healthy; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "TIMEOUT: Not all services healthy after ${MAX_WAIT}s."
    echo "Check logs: ./scripts/logs.sh <service>"
    echo ""
    echo "Current status:"
    docker compose ps --format "table {{.Name}}\t{{.Status}}"
    exit 1
  fi
  printf "\r  Waiting... %ds / %ds" "$ELAPSED" "$MAX_WAIT"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo ""
echo "All services healthy!"
echo ""

echo "=============================================="
echo "  Sales Stack is running!"
echo "=============================================="
echo ""
echo "  Service URLs:"
echo "    Twenty CRM:  http://localhost:${TWENTY_PORT}"
echo "    Mautic:      http://localhost:${MAUTIC_PORT}"
echo "    WAHA:        http://localhost:${WAHA_PORT}"
echo "    n8n:         http://localhost:${N8N_PORT}"
echo ""
echo "  Database access (debug):"
echo "    Twenty PG:   localhost:${TWENTY_DB_PORT}"
echo "    Mautic MySQL: localhost:${MAUTIC_DB_PORT}"
echo "    n8n PG:      localhost:${N8N_DB_PORT}"
echo "    Twenty Redis: localhost:${TWENTY_REDIS_PORT}"
echo ""
echo "  WAHA credentials:"
echo "    API Key:           ${WAHA_API_KEY}"
echo "    Dashboard user:    ${WAHA_DASHBOARD_USERNAME}"
echo "    Dashboard password: ${WAHA_DASHBOARD_PASSWORD}"
echo ""
echo "=============================================="
echo "  NEXT STEPS"
echo "=============================================="
echo ""
echo "  1. TWENTY CRM — Create admin account"
echo "     Open http://localhost:${TWENTY_PORT}"
echo "     Sign up with your email to create the first admin user."
echo "     Then go to Settings -> APIs & Webhooks -> + Create key"
echo "     to generate an API key for integrations."
echo ""
echo "  2. MAUTIC — Create admin account"
echo "     Open http://localhost:${MAUTIC_PORT}"
echo "     Complete the installation wizard:"
echo "       - DB already configured (skip or verify)"
echo "       - Create your admin user"
echo "       - Enable API in Configuration -> API Settings"
echo "       - Set 'API enabled' = Yes, 'Enable basic auth' = Yes"
echo ""
echo "  3. n8n — Setup account"
echo "     Open http://localhost:${N8N_PORT}"
echo "     Create your owner account on first visit."
echo "     Install community node: n8n-nodes-twenty-dynamic"
echo "       (Settings -> Community Nodes -> Install)"
echo ""
echo "  4. WAHA — Connect WhatsApp"
echo "     Open http://localhost:${WAHA_PORT}"
echo ""
echo "     a) On the login screen, fill in these fields:"
echo "        Server URL: http://localhost:${WAHA_PORT}"
echo "        API Key:    ${WAHA_API_KEY}"
echo "        Username:   ${WAHA_DASHBOARD_USERNAME}"
echo "        Password:   ${WAHA_DASHBOARD_PASSWORD}"
echo ""
echo "     b) After login, create a session and scan the QR code with WhatsApp."
echo ""
echo "  5. UPDATE MCP CONFIGS"
echo "     After creating API keys, update your MCP server configs:"
echo "       - TWENTY_API_KEY in .claude/settings.json"
echo "       - WAHA_API_KEY is already set (see above)"
echo "       - N8N_API_KEY from n8n Settings -> API"
echo "       - MAUTIC credentials from Mautic API settings"
echo ""

# Check if URLs still point to localhost
LOCALHOST_URLS=""
for var in TWENTY_SERVER_URL MAUTIC_SITE_URL WAHA_BASE_URL N8N_WEBHOOK_URL; do
  val=$(eval echo "\$$var")
  if echo "$val" | grep -q "localhost"; then
    LOCALHOST_URLS="$LOCALHOST_URLS  $var=$val\n"
  fi
done
if [ -n "$LOCALHOST_URLS" ]; then
  echo "=============================================="
  echo "  WARNING: URLs still point to localhost"
  echo "=============================================="
  echo ""
  echo "  If running behind a reverse proxy, update"
  echo "  these in .env and restart:"
  printf "$LOCALHOST_URLS"
  echo ""
fi
