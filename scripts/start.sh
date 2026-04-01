#!/bin/bash
set -e
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No .env found. Run: ./scripts/generate-secrets.sh"
  exit 1
fi

# Ensure volume directories exist (required for bind mounts)
mkdir -p volumes/{twenty-db,twenty-redis,mautic-db,mautic-data,n8n-db,n8n-data,waha-sessions}

docker compose up -d
echo "Stack starting... Run './scripts/status.sh' to check."
