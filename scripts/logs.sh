#!/bin/bash
cd "$(dirname "$0")/.."
SERVICE=${1:-}
if [ -z "$SERVICE" ]; then
  docker compose logs -f --tail=50
else
  docker compose logs -f --tail=50 "$SERVICE"
fi
