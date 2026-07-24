#!/usr/bin/env bash
# Trakolo Standalone / On-premise — installer.
# Brings up Postgres + Redis, applies db/schema.sql, then starts the app.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

log(){ printf '\033[1;32m==>\033[0m %s\n' "$1"; }
err(){ printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; }

command -v docker >/dev/null 2>&1 || { err "docker is required — https://docs.docker.com/engine/install/"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "docker compose (v2) is required"; exit 1; }

if [ ! -f .env ]; then
  log "No .env found — creating one from .env.example with a generated database password"
  cp .env.example .env
  GENERATED_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  # portable in-place sed (macOS/BSD sed needs -i '', GNU sed needs -i)
  if sed --version >/dev/null 2>&1; then
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${GENERATED_PASSWORD}/" .env
  else
    sed -i '' "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${GENERATED_PASSWORD}/" .env
  fi
fi

log "Starting database and cache"
docker compose up -d --wait db redis

log "Applying db/schema.sql"
docker compose run --rm migrate

log "Starting the app"
docker compose up -d --wait app

# shellcheck disable=SC1091
source .env
log "Trakolo is up at ${APP_BASE_URL:-http://localhost:${APP_PORT:-8080}}"
echo
echo "Next steps:"
echo "  1. Copy your issued license file to ${LICENSE_FILE:-./license/workspace.trklic}"
echo "     (see cloud-hosting-azure.html > Standalone / on-premise installation for how license files work)"
echo "  2. Sign in with the initial admin account created on first boot"
echo "  3. docker compose logs -f app   — tail logs"
echo "  4. docker compose down          — stop everything (data persists in named volumes)"
