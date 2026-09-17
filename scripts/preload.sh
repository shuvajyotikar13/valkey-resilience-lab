#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
count="${PRELOAD_KEYS:-250000}"
workers="${WORKERS:-32}"
sizes="${VALUE_SIZES:-256:70,1024:25,4096:5}"
sum=0

while IFS= read -r primary; do
  n="$(cli "$primary" DBSIZE | tr -d '\r')"
  sum=$((sum + n))
done < <(primary_services)

threshold=$((count * 9 / 10))
if [[ "${FORCE_PRELOAD:-0}" != "1" && "$sum" -ge "$threshold" ]]; then
  log "Primary key count is already ${sum}; skipping preload"
  exit 0
fi

log "Preloading ${count} keys"
"${COMPOSE[@]}" run --rm --no-deps loadgen \
  --endpoints valkey-1:6379,valkey-2:6379,valkey-3:6379 \
  --workers "$workers" --keyspace "$count" --preload "$count" --preload-only \
  --value-sizes "$sizes" --output /results/preload
log "Preload complete"
