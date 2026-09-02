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

SKIP_MIGRATE=0
DO_PULL=0
for arg in "$@"; do
  case "$arg" in
    --no-migrate) SKIP_MIGRATE=1 ;;
    --pull) DO_PULL=1 ;;
    --help|-h)
      echo "Usage: $0 [--pull] [--no-migrate]"
      echo "  --pull        docker compose pull before up (best-effort, no GHCR login)"
      echo "  --no-migrate  skip digihome-migrate one-shot"
      exit 0
      ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Preflight ---
log "==> Preflight checks..."

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found" >&2; exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose (v2) not found" >&2; exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found at $PROJECT_ROOT/$ENV_FILE" >&2; exit 1
fi
if [[ ! -f "config.yaml" ]]; then
  echo "ERROR: config.yaml not found" >&2; exit 1
fi
if [[ ! -f "gateway/nginx.conf" ]]; then
  echo "ERROR: gateway/nginx.conf not found" >&2; exit 1
fi

# Workaround for ollama/docker-compose.ollama.yaml:30 leading space "OLLAMA_MODELS= ${...}" and quoted value in .env
# Ensure OLLAMA_MODELS is exported without leading space/quotes for compose interpolation
# Also handle CRLF (\r) so .env edited on Windows doesn't cause "$'\r': command not found"
# Convert CRLF -> LF in-place if needed (uses portable tools, no external tr required at source time)
if [[ -f "$ENV_FILE" ]] && grep -q $'\r' "$ENV_FILE" 2>/dev/null; then
  log "Stripping CRLF from $ENV_FILE (Windows line endings detected)"
  if command -v sed >/dev/null 2>&1; then
    sed -i 's/\r$//' "$ENV_FILE" 2>/dev/null || sed -i 's/\r//g' "$ENV_FILE"
  elif command -v perl >/dev/null 2>&1; then
    perl -pi -e 's/\r//g' "$ENV_FILE"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import pathlib; p=pathlib.Path('$ENV_FILE'); p.write_bytes(p.read_bytes().replace(b'\r',b''))"
  fi
fi
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  if [[ -n "${OLLAMA_MODELS:-}" ]]; then
    # strip surrounding quotes and trim leading/trailing whitespace
    OLLAMA_MODELS="$(echo "$OLLAMA_MODELS" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    export OLLAMA_MODELS
  fi
fi

if [[ ! -f "cert/server.crt" || ! -f "cert/server.key" ]]; then
  log "cert/server.crt or key missing -> running make cert-gen"
  if command -v make >/dev/null 2>&1; then
    make -C "$PROJECT_ROOT" cert-gen
  elif command -v openssl >/dev/null 2>&1; then
    mkdir -p cert
    openssl req -x509 -newkey rsa:4096 -keyout cert/server.key -out cert/server.crt -days 365 -nodes -subj "/C=ID/ST=Jakarta/L=Jakarta/O=docs-digihome/OU=IT/CN=digihome"
  else
    echo "ERROR: cert missing and neither make nor openssl available" >&2; exit 1
  fi
fi

log "Validating compose config..."
if ! docker compose "${COMPOSE_ARGS[@]}" config -q; then
  echo "ERROR: docker compose config validation failed" >&2; exit 1
fi

if [[ "$DO_PULL" == "1" ]]; then
  log "Pulling images (best-effort, no GHCR login)..."
  docker compose "${COMPOSE_ARGS[@]}" pull --ignore-pull-failures || log "pull failed (ignored, images may be local)"
fi

# --- Phase 1: Infra healthy ---
log "==> Phase 1: Starting infra (digihome-db, digihome-object-storage, ollama)..."
docker compose "${COMPOSE_ARGS[@]}" up -d digihome-db digihome-object-storage ollama

wait_healthy() {
  local svc="$1"
  local timeout="${2:-180}"
  local elapsed=0
  local interval=5
  log "Waiting for $svc to be healthy (timeout ${timeout}s)..."
  while true; do
    local status
    status="$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "no-health")"
    if [[ "$status" == "healthy" ]]; then
      log "$svc is healthy"
      return 0
    fi
    if [[ "$status" == "no-health" || "$status" == "none" ]]; then
      # No healthcheck defined (e.g., ollama earlier versions) - fallback to running check
      if docker inspect --format='{{.State.Running}}' "$svc" 2>/dev/null | grep -q "true"; then
        log "$svc has no healthcheck but is running (fallback)"
        return 0
      fi
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      echo "ERROR: $svc not healthy after ${timeout}s (last status: $status)" >&2
      docker inspect --format='{{json .State.Health}}' "$svc" 2>/dev/null || true
      docker logs --tail=50 "$svc" 2>&1 || true
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

wait_healthy "digihome-db" 90
wait_healthy "digihome-object-storage" 180

# Ollama has no healthcheck in compose - poll API
log "Waiting for ollama API http://localhost:11434/api/tags (timeout 90s)..."
elapsed=0
until curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1; do
  if [[ "$elapsed" -ge 90 ]]; then
    log "WARNING: ollama API not responding after 90s, continuing anyway"
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
log "Ollama ready (or timeout reached)"

# --- Phase 2: Migrate (always, unless --no-migrate) ---
if [[ "$SKIP_MIGRATE" == "1" ]]; then
  log "==> Phase 2: Skipped digihome-migrate (--no-migrate)"
else
  log "==> Phase 2: Running migrate (digihome-migrate, restart: no)..."
  # run --rm ensures one-shot container removed; depends_on digihome-db healthy ensures DB ready
  if ! docker compose "${COMPOSE_ARGS[@]}" run --rm digihome-migrate; then
    echo "ERROR: migration failed" >&2
    docker logs digihome-migrate 2>&1 | tail -n 100 || true
    exit 1
  fi
  log "Migrate done"
  # cleanup any leftover exited container
  docker rm -f digihome-migrate 2>/dev/null || true
fi

# --- Phase 3: ollama-init blocking ---
log "==> Phase 3: Pulling ollama models (ollama-init, blocking)..."
# Remove stale init container if exists
docker rm -f ollama-init 2>/dev/null || true
docker compose "${COMPOSE_ARGS[@]}" up -d ollama-init
# Block until it exits (models bge-m3 qwen3.5:0.8b can be large, timeout 900s)
log "Waiting for ollama-init to complete (timeout 900s)..."
if docker wait ollama-init >/dev/null 2>&1; then
  code="$(docker inspect --format='{{.State.ExitCode}}' ollama-init 2>/dev/null || echo 0)"
  docker logs ollama-init 2>&1 | tail -n 50 || true
  if [[ "$code" != "0" ]]; then
    echo "ERROR: ollama-init failed with exit $code" >&2
    exit 1
  fi
  log "ollama-init completed"
else
  # Fallback: poll until not running
  elapsed=0
  while docker inspect --format='{{.State.Running}}' ollama-init 2>/dev/null | grep -q "true"; do
    if [[ "$elapsed" -ge 900 ]]; then
      echo "ERROR: ollama-init timeout after 900s" >&2
      docker logs ollama-init 2>&1 | tail -n 100 || true
      exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  log "ollama-init completed (poll)"
fi
docker rm -f ollama-init 2>/dev/null || true

# --- Phase 4: App ---
log "==> Phase 4: Starting backend + frontend..."
docker compose "${COMPOSE_ARGS[@]}" up -d digihome-backend-service digihome-fronted-service

# --- Phase 5: Gateway last ---
log "==> Phase 5: Starting gateway..."
docker compose "${COMPOSE_ARGS[@]}" up -d digihome-gateway

log "==> All phases done"
docker compose "${COMPOSE_ARGS[@]}" ps -a || true
log "Gateway: https://localhost:8080 (maps to 443 inside container)"
log "Done."
