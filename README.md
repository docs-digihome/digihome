# DigiHome — Deploy

> One-command deployment for the full DigiHome stack: AI smart-home assistant with RAG-powered document chat.

DigiHome is a self-hosted smart-home assistant that lets you chat with an LLM grounded in your own PDF documents. This repository orchestrates the entire stack — frontend, backend, database, object storage, and local LLM — behind a single Nginx TLS gateway.

**Related repositories:**
- [digihome-fe](https://github.com/docs-digihome/digihome-fe) — React 19 chat frontend
- [digihome-be](https://github.com/docs-digihome/digihome-be) — Go backend (Chi + pgvector + RustFS + Ollama)

---

## How It Works

```
                    ┌─────────────────────────────────────────────┐
                    │         Nginx Gateway (TLS) :8080            │
                    │  /  → Frontend   /api/ → Backend            │
                    │  /documents/ → RustFS (S3)                   │
                    └──────┬──────────────────┬───────────────────┘
                           │                  │
              ┌────────────▼──────┐  ┌────────▼────────┐
              │  Frontend (React) │  │  Backend (Go)   │
              │  ghcr.io/.../fe   │  │ ghcr.io/.../be  │
              └───────────────────┘  └─┬──────┬──────┬─┘
                                      │      │      │
                          ┌───────────▼─┐ ┌──▼───┐ ┌▼────────┐
                          │  PostgreSQL │ │RustFS│ │ Ollama  │
                          │  + pgvector │ │ S3   │ │bge-m3 / │
                          │  :5432      │ │:9000 │ │qwen3.5  │
                          └─────────────┘ └──────┘ └─────────┘
```

| Service | Image | Purpose |
|---|---|---|
| **gateway** | `nginx:1.28.0-alpine-slim` | TLS termination & reverse proxy |
| **frontend** | `ghcr.io/docs-digihome/digihome-fe` | React chat UI |
| **backend** | `ghcr.io/docs-digihome/digihome-be` | REST API, RAG, auth, chat |
| **db** | `pgvector/pgvector:pg18-trixie` | Vector store + relational data |
| **object-storage** | `rustfs/rustfs:1.0.0-rc.4` | S3-compatible PDF storage |
| **ollama** | `ollama:0.33.2` | Local LLM — embeddings (`bge-m3`) & chat (`qwen3.5:0.8b`) |
| **migrate** | `migrate/migrate:v4.18.2` | One-shot DB migrations |

All services share a single Docker network `digihome-network` — compose files are split by concern and merged at runtime.

## Features

- **Document-grounded chat** — upload PDFs, get answers grounded in your documents via RAG (pgvector similarity search + Ollama)
- **Single-command deploy** — `bin/start.sh` handles phased bring-up with health checks and model pre-pulling
- **Fully self-hosted LLM** — no external API keys required; runs `bge-m3` for embeddings and `qwen3.5:0.8b` for chat locally via Ollama (also supports OpenAI-compatible endpoints)
- **S3-compatible storage** — RustFS for document persistence, proxied through the gateway
- **TLS out of the box** — self-signed cert generation via `make cert-gen`, Nginx gateway on `:8080` (maps to container `:443`)
- **Single-thread chat UX** — infinite scroll history, optimistic updates, and light/dark/system theme (frontend)

## Prerequisites

- **Docker Engine** + **Compose v2**
- `make` + `openssl` (for `make cert-gen`) — or `openssl` alone
- Free ports: `8080`, `5432`, `9000`/`9001`, `11434`

> [!NOTE]
> On Windows, line endings are normalized to LF via `.gitattributes` — no manual conversion needed.

## Quick Start

```bash
# 1. Configure environment
cp .env.example .env
# Edit .env — set DB_USER, DB_PASSWORD, DB_NAME, DATABASE_URL, OS_ROOT_*, VITE_* as needed

# 2. Generate TLS certificate (also auto-run by start.sh if missing)
make cert-gen

# 3. Bring up the full stack
bin/start.sh

# Options:
bin/start.sh --pull        # pull latest images first (best-effort GHCR)
bin/start.sh --no-migrate  # skip DB migrations
```

Open **https://localhost:8080** and accept the self-signed certificate.

### Stop & Restart

```bash
bin/stop.sh                          # down --remove-orphans (volumes preserved)
bin/restart.sh                       # stop + start
bin/restart.sh --pull --no-migrate   # with options
```

## Configuration

### Environment Variables

Copy `.env.example` → `.env`:

| Variable | Description | Default |
|---|---|---|
| `VITE_BASE_URL` | Frontend base URL | `https://localhost:8080` |
| `VITE_API_BASE_URL` | Backend API URL | `http://localhost:8080/api` |
| `VITE_ASSETS_BASE_URL` | Object storage URL | `http://localhost:8080/assets` |
| `BACKEND_ENV` | Backend env (`production`/`development`) | `production` |
| `DB_USER` / `DB_PASSWORD` / `DB_NAME` | Postgres credentials | `myusername` / `password` / `digihome` |
| `DATABASE_URL` | Full DB connection string for migrations | — |
| `MIGRATIONS_GIT_REF` | Git ref for migration files | `main` |
| `OS_ROOT_USER` / `OS_ROOT_PASSWORD` | RustFS S3 credentials | `ROOTUSER` / `CHANGEME123` |
| `OLLAMA_MODELS` | Space-separated models to pull | `"bge-m3 qwen3.5:0.8b"` |
| `BACKEND_IMAGE_TAG` / `FRONTEND_IMAGE_TAG` | Image tags | `latest` |

### Central Config — `config.yaml`

Single source of truth consumed by the backend via [Viper](https://github.com/spf13/viper) at [`config.yaml:1`](config.yaml) and mounted read-only into the backend container:

```yaml
database.sql:  { host: digihome-db, port: 5432 }
llm.embed:     { model: bge-m3, endpoint: http://localhost:11434/api/embed }
llm.chat:      { model: qwen3.5:0.8b, num_ctx: 16384, top_k_documents: 3 }
rustfs:        { host: digihome-object-storage, port: 9000 }
auth.jwt:      { access_token_ttl: 15m, refresh_token_ttl: 7d }
```

Override by editing `config.yaml` or switching to OpenAI-compatible endpoints via `LLM_EMBED_API_KEY` / `LLM_CHAT_API_KEY`.

> [!TIP]
> For production, copy `config.yaml` and adjust `database`, `llm`, and `auth.jwt` values. For tests, use `config.test.yaml`.

## Project Structure

```
digihome-deploy/
├── docker-compose.yml                    # Root network definition
├── config.yaml                           # Central app config (Viper)
├── .env.example                          # Environment template
├── Makefile                              # cert-gen target
├── bin/
│   ├── start.sh    # Phased bring-up with health checks
│   ├── stop.sh     # Graceful teardown
│   └── restart.sh  # stop + start
├── gateway/
│   ├── docker-compose.nginx.yaml
│   └── nginx.conf                        # TLS + routing (/api/, /documents/, /)
├── db/
│   └── docker-compose.psql.yaml          # pgvector + healthcheck
├── object_storage/
│   └── docker-compose.rustfs.yaml
├── ollama/
│   └── docker-compose.ollama.yaml        # ollama + ollama-init model pull
├── migration/
│   └── docker-compose.migration.yaml     # one-shot migrate from GitHub archive
├── app/
│   ├── docker-compose.be.yaml
│   └── docker-compose.fe.yaml
└── cert/
    ├── server.crt
    └── server.key                        # generated by make cert-gen
```

## Startup Phases

`bin/start.sh` orchestrates a phased bring-up:

1. **Infrastructure** — `digihome-db`, `digihome-object-storage`, `ollama` → waits for healthy status (90s/180s timeout) + Ollama API poll
2. **Migrations** — `digihome-migrate` one-shot run (skipped with `--no-migrate`)
3. **Model init** — `ollama-init` blocking `docker wait` (900s) to pull `OLLAMA_MODELS`
4. **Application** — `digihome-backend-service` + `digihome-fronted-service`
5. **Gateway** — `digihome-gateway` last, then `docker compose ps -a`

## Frontend & Backend

### Frontend — [digihome-fe](https://github.com/docs-digihome/digihome-fe)

React 19 + TypeScript + Vite, Tailwind v4, shadcn/ui (base-nova), TanStack Query, React Router.

- **Chat** — `useInfiniteQuery` history (`GET /chat?before=`), `POST /chat {prompt}` with optimistic updates, IntersectionObserver infinite scroll
- **Documents** — PDF dropzone (max 10, preview), `POST /rag/document`, `POST /rag/seed` sync
- **Theme** — light/dark/system via `html.dark` class

```bash
# Standalone frontend dev
git clone https://github.com/docs-digihome/digihome-fe && cd digihome-fe
cp .env.example .env
bun install && bun dev  # http://localhost:5173
```

### Backend — [digihome-be](https://github.com/docs-digihome/digihome-be)

Go 1.25 — Chi router, pgx/pgvector, RustFS (minio-go), langchaingo, Uber Fx DI.

- **REST API** — `POST /chat`, `GET /chat`, `POST /rag/document`, `POST /rag/seed`, JWT auth (15m access / 7d refresh)
- **RAG pipeline** — PDF ingestion → chunking → `bge-m3` embeddings → pgvector search (`top_k=3`) → `qwen3.5:0.8b` grounded generation
- **Config** — Viper + `config.yaml`, supports local Ollama or OpenAI-compatible endpoints

```bash
# Standalone backend dev
git clone https://github.com/docs-digihome/digihome-be && cd digihome-be
cp config.yaml.example config.yaml
go run ./cmd/server
```

## Useful Commands

```bash
# Validate merged compose config
docker compose --env-file .env \
  -f docker-compose.yml -f db/docker-compose.psql.yaml \
  -f object_storage/docker-compose.rustfs.yaml -f ollama/docker-compose.ollama.yaml \
  -f migration/docker-compose.migration.yaml -f app/docker-compose.be.yaml \
  -f app/docker-compose.fe.yaml -f gateway/docker-compose.nginx.yaml config -q

# Status & logs
docker compose -f docker-compose.yml -f db/docker-compose.psql.yaml -f ... ps -a
docker logs -f digihome-backend-service
docker logs ollama-init
docker logs -f digihome-gateway

# Regenerate TLS cert
make cert-gen
```

> [!WARNING]
> The default TLS certificate is self-signed (4096-bit RSA, 365 days). For production, replace `cert/server.crt` and `cert/server.key` with a CA-signed certificate.

## Troubleshooting

| Issue | Fix |
|---|---|
| `port already allocated` | Ensure `8080`, `5432`, `9000`, `11434` are free: `docker ps`, `netstat -tulpn` |
| `ollama-init` timeout | Models are large — increase the 900s wait in `bin/start.sh` or pull manually: `docker exec ollama ollama pull bge-m3` |
| CRLF issues on Windows | Handled automatically via `.gitattributes` and `OLLAMA_MODELS` quoting in `bin/start.sh` |
| GHCR pull fails | Images may require `docker login ghcr.io`; `--pull` is best-effort |
