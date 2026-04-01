#!/bin/bash
cd "$(dirname "$0")/.."

echo "=== Sales Stack Status ==="
echo ""
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "=== Service URLs ==="
echo "  Twenty CRM:  http://localhost:2350"
echo "  Mautic:      http://localhost:2351"
echo "  WAHA:        http://localhost:2352"
echo "  n8n:         http://localhost:2353"
