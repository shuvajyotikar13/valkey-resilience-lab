#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

out_dir="${1:?usage: capture-env.sh OUTPUT_DIR}"
mkdir -p "$out_dir"
image="${VALKEY_IMAGE:-valkey/valkey:9.1.2}"
image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo unavailable)"
repo_digest="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}unavailable{{end}}' "$image" 2>/dev/null || echo unavailable)"

{
  printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host_uname=%s\n' "$(uname -a)"
  printf 'docker_version=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
  printf 'valkey_image=%s\n' "$image"
  printf 'valkey_image_id=%s\n' "$image_id"
  printf 'valkey_repo_digest=%s\n' "$repo_digest"
  printf 'target_rps=%s\n' "${TARGET_RPS:-30000}"
  printf 'workers=%s\n' "${WORKERS:-32}"
  printf 'preload_keys=%s\n' "${PRELOAD_KEYS:-250000}"
  printf 'value_sizes=%s\n' "${VALUE_SIZES:-256:70,1024:25,4096:5}"
} >"${out_dir}/environment.txt"

if command -v lscpu >/dev/null 2>&1; then
  lscpu >"${out_dir}/lscpu.txt"
fi
if command -v free >/dev/null 2>&1; then
  free -h >"${out_dir}/memory.txt"
fi

"${COMPOSE[@]}" config >"${out_dir}/compose-resolved.yml"
cli "$(first_running_core)" INFO server >"${out_dir}/valkey-info-server.txt"
cli "$(first_running_core)" CLUSTER NODES >"${out_dir}/cluster-nodes-before.txt"
cli "$(first_running_core)" CONFIG GET \
  appendonly appendfsync save maxmemory maxmemory-policy repl-backlog-size repl-diskless-sync \
  cluster-node-timeout cluster-manual-failover-timeout client-output-buffer-limit \
  >"${out_dir}/valkey-config-before.txt"
