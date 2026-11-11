#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Keep the observer outside the Valkey reset fault domain.
if [[ "${BETTERDB_ENABLED:-0}" == "1" && -f "${LAB_ROOT}/docker-compose.betterdb.yml" ]]; then
  log "Resetting Valkey nodes while preserving BetterDB and PostgreSQL"

  nodes=("${CORE_NODES[@]}" valkey-7 valkey-8)

  # Stop/remove only the Valkey services, not the Compose project or network.
  "${COMPOSE[@]}" --profile scale rm --stop --force --volumes "${nodes[@]}"

  # `compose rm --volumes` does not reliably remove named Compose volumes.
  # Select only named data volumes belonging to this exact project.
  project="${COMPOSE_PROJECT_NAME:-valkey-resilience-lab}"
  for node in "${nodes[@]}"; do
    volume_key="${node}-data"
    while IFS= read -r volume; do
      [[ -z "$volume" ]] && continue
      log "Removing disposable Valkey data volume: $volume"
      docker volume rm "$volume"
    done < <(docker volume ls --quiet \
      --filter "label=com.docker.compose.project=${project}" \
      --filter "label=com.docker.compose.volume=${volume_key}")
  done

  log "Valkey-only reset complete; BetterDB/PostgreSQL containers preserved"
else
  # Original behavior when BetterDB is disabled or not installed.
  log "Removing lab containers and named data volumes"
  "${COMPOSE[@]}" --profile scale --profile tools down -v --remove-orphans
  log "Lab reset complete"
fi
