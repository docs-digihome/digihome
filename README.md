# digihome-deploy

Deployment orchestration for DigiHome stack (frontend, backend, postgres+pgvector, RustFS, Ollama, migrations) behind an Nginx TLS gateway on a single `digihome-network`.

## Architecture

```
                :8080 (443)               :8080         :11434
gateway/nginx ──> frontend ─┐
              ├──> backend ──┼─> db:5432 (pgvector)
              └──> rustfs:9000/9001
                          └──> ollama + ollama-init (bge-m3, qwen3.5:0.8b)
                  migrate (one-shot, ghcr.io/docs-digihome/digihome-be migrations)
```

Compose files are split but merged at runtime via `bin/start.sh` against root `docker-compose.yml:1` network:

- `docker-compose.yml` - `digihome` network
- `db/docker-compose.psql.yaml` - `pgvector/pgvector:pg18-trixie` + healthcheck
- `object_storage/docker-compose.rustfs.yaml` - `rustfs/rustfs:1.0.0-rc.4` (9000/9001)
- `ollama/docker-compose.ollama.yaml` - `ollama:0.33.2` + `ollama-init` pulls `OLLAMA_MODELS`
- `migration/docker-compose.migration.yaml` - `migrate/migrate:v4.18.2` from GitHub archive
- `app/docker-compose.be.yaml` / `app/docker-compose.fe.yaml` - `ghcr.io/docs-digihome/*`
- `gateway/docker-compose.nginx.yaml` + `gateway/nginx.conf:1` - `nginx:1.28.0-alpine-slim` TLS, routes `/documents/`, `/api/`, `/`

Config: `config.yaml:1` (viper source of truth, DB/LLM/RustFS/JWT), env template `.env.example:1`.

## Prerequisites

- Docker Engine + Compose v2
- `make` + `openssl` (for `make cert-gen`), or `openssl` alone
- Ports free: `8080`, `5432`, `9000/9001`, `11434`

## Quick Start

```bash
cp .env.example .env
# edit DB_USER/DB_PASSWORD/DB_NAME, DATABASE_URL, OS_ROOT_*, VITE_* as needed
# .env is gitignored via .gitattributes LF handling - handles CRLF on Windows

make cert-gen          # creates cert/server.crt + cert/server.key (4096-bit, 365d) - also auto-run by start.sh
bin/start.sh           # full phased bring-up
bin/start.sh --pull    # pull images first (best-effort GHCR)
bin/start.sh --no-migrate  # skip migration
bin/stop.sh            # down --remove-orphans (volumes preserved)
bin/restart.sh [--pull] [--no-migrate]
```

Gateway: `https://localhost:8080` (container `443` mapped). Accept self-signed cert.

### Env

See `.env.example:1`:
- `VITE_BASE_URL`, `VITE_API_BASE_URL`, `VITE_ASSETS_BASE_URL`
- `BACKEND_ENV`, `DB_USER/DB_PASSWORD/DB_NAME`, `DATABASE_URL`, `MIGRATIONS_GIT_REF`
- `OS_ROOT_USER/OS_ROOT_PASSWORD`, `OLLAMA_MODELS="bge-m3 qwen3.5:0.8b"` (quoted, CRLF-safe via `bin/start.sh:61`)

### Phases (`bin/start.sh:105`)

1. Infra `digihome-db`, `digihome-object-storage`, `ollama` + `wait_healthy` (90s/180s) + Ollama API poll
2. `digihome-migrate` `run --rm` (unless `--no-migrate`)
3. `ollama-init` blocking `docker wait` (900s) for model pulls
4. `digihome-backend-service` + `digihome-fronted-service`
5. `digihome-gateway` last, then `ps -a`

Line endings normalized to LF via `.gitattributes:1` (`*.sh`, `*.yaml`, `config.yaml`).

## Config

`config.yaml:1` defaults: `digihome-db:5432`, `ollama:11434` (`bge-m3` embed, `qwen3.5:0.8b` chat `num_ctx 16384`), `digihome-object-storage:9000`, `app.base.url https://localhost/api`, `auth.jwt 15m/7d`.

## Useful Commands

```bash
docker compose --env-file .env -f docker-compose.yml -f db/docker-compose.psql.yaml -f object_storage/docker-compose.rustfs.yaml -f ollama/docker-compose.ollama.yaml -f migration/docker-compose.migration.yaml -f app/docker-compose.be.yaml -f app/docker-compose.fe.yaml -f gateway/docker-compose.nginx.yaml config -q
docker compose -f docker-compose.yml -f ... ps -a
docker logs -f digihome-backend-service
docker logs ollama-init
```
