#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_command podman
require_command curl
ensure_cluster

# Deliberately external to the lab Compose project to retain incident history.
BETTERDB_VOLUME="valkey-resilience-lab-betterdb-pgdata"

if ! podman volume exists "$BETTERDB_VOLUME"; then
  podman volume create "$BETTERDB_VOLUME" >/dev/null
fi
monitor_compose=("${COMPOSE[@]}" -f "${LAB_ROOT}/docker-compose.betterdb.yml" --profile betterdb)
"${monitor_compose[@]}" up -d betterdb

for ((attempt=1; attempt<=45; attempt++)); do
  if curl --silent --show-error --fail --max-time 2 http://127.0.0.1:3001/api/health >/dev/null 2>&1; then
    log "BetterDB ready at http://localhost:3001"
    exit 0
  fi
  sleep 1
done
"${monitor_compose[@]}" logs --tail=80 betterdb betterdb-postgres >&2 || true
printf 'BetterDB did not become ready; check the Compose logs above.\n' >&2
exit 1
