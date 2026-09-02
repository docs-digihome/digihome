#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
ENV_FILE="${ENV_FILE:-.env}"

COMPOSE_ARGS=(
  --env-file "$ENV_FILE"
  -f docker-compose.yml
  -f db/docker-compose.psql.yaml
  -f object_storage/docker-compose.rustfs.yaml
  -f ollama/docker-compose.ollama.yaml
  -f migration/docker-compose.migration.yaml
  -f app/docker-compose.be.yaml
  -f app/docker-compose.fe.yaml
  -f gateway/docker-compose.nginx.yaml
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      echo "Usage: $0"
      echo "  Stops all services via 'docker compose down --remove-orphans' (preserves volumes)"
      exit 0
      ;;
  esac
done

log "==> Stopping digihome stack (down, preserve volumes)..."

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found" >&2; exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose (v2) not found" >&2; exit 1
fi

# down with merged compose - idempotent, preserves volumes (no -v)
if docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans --timeout 30 2>&1; then
  log "compose down completed"
else
  log "compose down returned non-zero (possibly already stopped) - continuing"
fi

# Cleanup one-shot leftovers if still present (restart: "no" containers)
docker rm -f digihome-migrate ollama-init 2>/dev/null || true

log "==> Stopped (volumes preserved: digihome_db_data, digihome_object_storage_data, ollama_data)"
docker compose "${COMPOSE_ARGS[@]}" ps -a 2>&1 || true
