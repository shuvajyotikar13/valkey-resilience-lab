#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE=(docker compose -f "${LAB_ROOT}/docker-compose.yml")
CORE_NODES=(valkey-1 valkey-2 valkey-3 valkey-4 valkey-5 valkey-6)

if [[ -f "${LAB_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${LAB_ROOT}/.env"
  set +a
fi

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

is_running() {
  "${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx "$1"
}

cli() {
  local service="$1"
  shift
  "${COMPOSE[@]}" exec -T "$service" valkey-cli -h 127.0.0.1 -p 6379 --raw "$@"
}

wait_node() {
  local service="$1"
  local attempts="${2:-60}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if is_running "$service" && [[ "$(cli "$service" PING 2>/dev/null || true)" == "PONG" ]]; then
      return 0
    fi
    sleep 1
  done
  printf 'Node did not become ready: %s\n' "$service" >&2
  return 1
}

cluster_state() {
  local service="${1:-valkey-1}"
  cli "$service" CLUSTER INFO 2>/dev/null | awk -F: '$1 == "cluster_state" {gsub(/\r/, "", $2); print $2}'
}

wait_cluster_ok() {
  local attempts="${1:-60}"
  local i service
  for ((i = 1; i <= attempts; i++)); do
    for service in "${CORE_NODES[@]}"; do
      if is_running "$service" && [[ "$(cluster_state "$service" || true)" == "ok" ]]; then
        return 0
      fi
    done
    sleep 1
  done
  printf 'Cluster did not reach cluster_state:ok\n' >&2
  return 1
}

role_of() {
  local service="$1"
  cli "$service" INFO replication 2>/dev/null | awk -F: '$1 == "role" {gsub(/\r/, "", $2); print $2}'
}

primary_services() {
  local service
  for service in "${CORE_NODES[@]}"; do
    if is_running "$service" && [[ "$(role_of "$service" || true)" == "master" ]]; then
      printf '%s\n' "$service"
    fi
  done
}

first_primary() {
  local service
  for service in "${CORE_NODES[@]}"; do
    if is_running "$service" && [[ "$(role_of "$service" || true)" == "master" ]]; then
      printf '%s\n' "$service"
      return 0
    fi
  done
  return 1
}

node_id() {
  cli "$1" CLUSTER MYID | tr -d '\r'
}

wait_for_node_id() {
  local observer="$1"
  local wanted_id="$2"
  local attempts="${3:-30}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if cli "$observer" CLUSTER NODES 2>/dev/null | awk -v id="$wanted_id" '$1 == id {found=1} END {exit !found}'; then
      return 0
    fi
    sleep 1
  done
  printf '%s did not learn cluster node %s\n' "$observer" "$wanted_id" >&2
  return 1
}

replica_for_primary() {
  local primary="$1"
  local primary_id service master_id
  primary_id="$(node_id "$primary")"
  for service in "${CORE_NODES[@]}" valkey-7 valkey-8; do
    if ! is_running "$service" || [[ "$(role_of "$service" || true)" != "slave" ]]; then
      continue
    fi
    master_id="$(cli "$service" CLUSTER NODES 2>/dev/null | awk '$3 ~ /myself/ {print $4}')"
    if [[ "$master_id" == "$primary_id" ]]; then
      printf '%s\n' "$service"
      return 0
    fi
  done
  return 1
}

first_running_core() {
  local service
  for service in "${CORE_NODES[@]}"; do
    if is_running "$service"; then
      printf '%s\n' "$service"
      return 0
    fi
  done
  return 1
}

cluster_cli() {
  local runner
  runner="$(first_running_core)"
  "${COMPOSE[@]}" exec -T "$runner" valkey-cli "$@"
}

ensure_cluster() {
  require_command docker
  if ! wait_cluster_ok 3; then
    printf 'Cluster is not ready. Run: make up\n' >&2
    exit 1
  fi
}
