#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
"${SCRIPT_DIR}/preload.sh"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-envelope"
run_dir="${LAB_ROOT}/results/${run_id}"
mkdir -p "$run_dir"
"${SCRIPT_DIR}/capture-env.sh" "$run_dir"

stages="${ENVELOPE_RPS:-10000 20000 40000 80000 0}"
duration="${ENVELOPE_STAGE_SECONDS:-60}"
workers="${WORKERS:-32}"
keyspace="${KEYSPACE:-${PRELOAD_KEYS:-250000}}"
sizes="${VALUE_SIZES:-256:70,1024:25,4096:5}"

for rps in $stages; do
  stage="rps-${rps}"
  stage_dir="${run_dir}/${stage}"
  mkdir -p "$stage_dir"
  log "Envelope stage ${stage} for ${duration}s"
  "${SCRIPT_DIR}/collect.sh" "$stage_dir" 1 "$duration" &
  collector_pid=$!
  "${COMPOSE[@]}" run --rm --no-deps loadgen \
    --endpoints valkey-1:6379,valkey-2:6379,valkey-3:6379 \
    --duration "${duration}s" --workers "$workers" --rps "$rps" --keyspace "$keyspace" \
    --update-pct 95 --insert-pct 0 --delete-pct 5 --value-sizes "$sizes" \
    --retry-policy none --max-attempts 1 --output "/results/${run_id}/${stage}" \
    >"${stage_dir}/loadgen.log" 2>&1
  wait "$collector_pid" || true
  python3 "${SCRIPT_DIR}/report.py" "$stage_dir" || true
done

log "Envelope results: ${run_dir}"
