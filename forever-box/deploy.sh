#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HERMES_SOURCE="${HERMES_SOURCE:-$ROOT/../../hermes-agent}"
[[ -f "$HERMES_SOURCE/Dockerfile" ]] || { echo "Hermes source missing at $HERMES_SOURCE" >&2; exit 1; }
[[ -f "$ROOT/.env" ]] || { echo "Create $ROOT/.env from .env.example first" >&2; exit 1; }

docker build -t hermes-agent:local "$HERMES_SOURCE"
docker compose --env-file "$ROOT/.env" -f "$ROOT/docker-compose.yml" build
docker compose --env-file "$ROOT/.env" -f "$ROOT/docker-compose.yml" up -d
