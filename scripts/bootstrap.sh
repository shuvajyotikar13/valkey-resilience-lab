#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_command docker
log "Starting six Valkey nodes"
"${COMPOSE[@]}" up -d "${CORE_NODES[@]}"

for node in "${CORE_NODES[@]}"; do
  wait_node "$node"
done

if wait_cluster_ok 2; then
  log "Cluster already initialized and healthy"
  exit 0
fi

known_nodes="$(cli valkey-1 CLUSTER INFO 2>/dev/null | awk -F: '$1 == "cluster_known_nodes" {gsub(/\r/, "", $2); print $2}')"
if [[ -n "$known_nodes" && "$known_nodes" != "1" ]]; then
  printf 'A partial cluster configuration exists. Run make reset, then make up.\n' >&2
  exit 1
fi

log "Creating a three-primary, one-replica-per-primary cluster"
"${COMPOSE[@]}" exec -T valkey-1 valkey-cli --cluster create \
  valkey-1:6379 valkey-2:6379 valkey-3:6379 \
  valkey-4:6379 valkey-5:6379 valkey-6:6379 \
  --cluster-replicas 1 --cluster-yes

wait_cluster_ok 60
log "Cluster is ready"
primary_services | sed 's/^/  primary: /'
