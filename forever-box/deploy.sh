#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HERMES_SOURCE="${HERMES_SOURCE:-$ROOT/../../hermes-agent}"
[[ -f "$HERMES_SOURCE/Dockerfile" ]] || { echo "Hermes source missing at $HERMES_SOURCE" >&2; exit 1; }
[[ -f "$ROOT/.env" ]] || { echo "Create $ROOT/.env from .env.example first" >&2; exit 1; }

# Hermes' Dockerfile uses COPY --chmod, which requires BuildKit.  Older Docker
# hosts still default to the legacy builder, so make the requirement explicit.
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"
export COMPOSE_DOCKER_CLI_BUILD="${COMPOSE_DOCKER_CLI_BUILD:-1}"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "Docker Compose is required (docker compose or docker-compose)." >&2
  exit 1
fi

docker build -t hermes-agent:local "$HERMES_SOURCE"
"${COMPOSE[@]}" --env-file "$ROOT/.env" -f "$ROOT/docker-compose.yml" build
"${COMPOSE[@]}" --env-file "$ROOT/.env" -f "$ROOT/docker-compose.yml" up -d
