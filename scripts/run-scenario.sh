#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

scenario="${1:-}"
case "$scenario" in
  baseline|replica-partial|replica-full|reshard-atomic|reshard-legacy|bgsave|failover-none|failover-immediate|failover-jitter|add-replicas|hot-skew) ;;
  *)
    printf 'Usage: %s {baseline|replica-partial|replica-full|reshard-atomic|reshard-legacy|bgsave|failover-none|failover-immediate|failover-jitter|add-replicas|hot-skew}\n' "$0" >&2
    exit 2
    ;;
esac

if [[ "${RESET_BEFORE_RUN:-0}" == "1" ]]; then
  bash "${SCRIPT_DIR}/reset.sh"
  bash "${SCRIPT_DIR}/bootstrap.sh"
fi

ensure_cluster
bash "${SCRIPT_DIR}/preload.sh"

warmup="${WARMUP_SECONDS:-30}"
fault="${FAULT_SECONDS:-20}"
recovery="${RECOVERY_SECONDS:-60}"
if [[ "$scenario" == "replica-partial" ]]; then
  fault="${PARTIAL_OUTAGE_SECONDS:-5}"
elif [[ "$scenario" == "replica-full" ]]; then
  fault="${FULL_OUTAGE_SECONDS:-20}"
fi
if [[ "$scenario" == "baseline" || "$scenario" == "hot-skew" ]]; then
  total="${BASELINE_SECONDS:-180}"
else
  total=$((warmup + fault + recovery))
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-${scenario}"
run_dir="${LAB_ROOT}/results/${run_id}"
mkdir -p "$run_dir"
events_csv="${run_dir}/events.csv"
printf '%s\n' 'timestamp,epoch_s,event,details' >"$events_csv"

event() {
  local name="$1"
  local details="${2:-}"
  details="${details//,/;}"
  printf '%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$name" "$details" >>"$events_csv"
  log "${name}: ${details}"
}

has_cluster_flag() {
  local flags="$1"
  local wanted="$2"
  [[ ",${flags}," == *",${wanted},"* ]]
}

info_value() {
  local info="$1"
  local key="$2"
  awk -F: -v wanted="$key" '$1 == wanted {gsub(/\r/, "", $2); print $2; exit}' <<<"$info"
}

primary="$(first_primary)"
replica="$(replica_for_primary "$primary")"
original_backlog="$(cli "$primary" CONFIG GET repl-backlog-size | tail -n 1 | tr -d '\r')"
collector_pid=""
load_pid=""

cleanup() {
  if [[ -n "$collector_pid" ]]; then
    kill "$collector_pid" 2>/dev/null || true
  fi
  if [[ -n "$load_pid" ]]; then
    kill "$load_pid" 2>/dev/null || true
  fi
  for node in "${CORE_NODES[@]}"; do
    "${COMPOSE[@]}" unpause "$node" >/dev/null 2>&1 || true
    if ! is_running "$node"; then
      "${COMPOSE[@]}" start "$node" >/dev/null 2>&1 || true
    fi
  done
  if is_running "$primary" && [[ -n "$original_backlog" ]]; then
    cli "$primary" CONFIG SET repl-backlog-size "$original_backlog" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

bash "${SCRIPT_DIR}/capture-env.sh" "$run_dir"
{
  printf 'scenario=%s\n' "$scenario"
  printf 'primary_under_test=%s\n' "$primary"
  printf 'replica_under_test=%s\n' "$replica"
  printf 'warmup_seconds=%s\n' "$warmup"
  printf 'fault_seconds=%s\n' "$fault"
  printf 'recovery_seconds=%s\n' "$recovery"
} >>"${run_dir}/environment.txt"

target_rps="${TARGET_RPS:-30000}"
workers="${WORKERS:-32}"
keyspace="${KEYSPACE:-${PRELOAD_KEYS:-250000}}"
sizes="${VALUE_SIZES:-256:70,1024:25,4096:5}"
retry_policy="jitter"
max_attempts=3
hot_pct=0
hot_keys="${HOT_KEYS:-8}"

case "$scenario" in
  failover-none)
    retry_policy=none
    max_attempts=1
    ;;
  failover-immediate)
    retry_policy=immediate
    max_attempts="${FAILOVER_MAX_ATTEMPTS:-5}"
    ;;
  failover-jitter)
    retry_policy=jitter
    max_attempts="${FAILOVER_MAX_ATTEMPTS:-5}"
    ;;
  hot-skew)
    hot_pct="${HOT_PCT:-60}"
    ;;
esac

event scenario_start "duration=${total}s target_rps=${target_rps} retry=${retry_policy}"
bash "${SCRIPT_DIR}/collect.sh" "$run_dir" 1 "$total" &
collector_pid=$!

"${COMPOSE[@]}" run --rm --no-deps loadgen \
  --endpoints valkey-1:6379,valkey-2:6379,valkey-3:6379 \
  --duration "${total}s" --workers "$workers" --rps "$target_rps" --keyspace "$keyspace" \
  --update-pct "${UPDATE_PCT:-85}" --insert-pct "${INSERT_PCT:-10}" --delete-pct "${DELETE_PCT:-5}" \
  --hot-pct "$hot_pct" --hot-keys "$hot_keys" --value-sizes "$sizes" \
  --timeout "${REQUEST_TIMEOUT:-250ms}" --retry-policy "$retry_policy" --max-attempts "$max_attempts" \
  --retry-base "${RETRY_BASE:-10ms}" --retry-cap "${RETRY_CAP:-250ms}" \
  --sample-every "${SAMPLE_EVERY:-10}" --output "/results/${run_id}" \
  >"${run_dir}/loadgen.log" 2>&1 &
load_pid=$!

if [[ "$scenario" != "baseline" && "$scenario" != "hot-skew" ]]; then
  sleep "$warmup"
fi

case "$scenario" in
  baseline)
    event steady_state "No fault injected"
    ;;
  hot-skew)
    event hot_skew "${hot_pct}% of operations target ${hot_keys} hash tags"
    ;;
  replica-partial)
    event replica_stopped "$replica; backlog=${original_backlog}"
    "${COMPOSE[@]}" stop -t 1 "$replica" >/dev/null
    sleep "$fault"
    "${COMPOSE[@]}" start "$replica" >/dev/null
    wait_node "$replica"
    event replica_restarted "Expected outcome: partial resynchronization if backlog still covers outage"
    ;;
  replica-full)
    cli "$primary" CONFIG SET repl-backlog-size "${FULL_SYNC_BACKLOG:-1mb}" >/dev/null
    event backlog_reduced "$primary backlog=${FULL_SYNC_BACKLOG:-1mb}"
    event replica_stopped "$replica"
    "${COMPOSE[@]}" stop -t 1 "$replica" >/dev/null
    sleep "$fault"
    "${COMPOSE[@]}" start "$replica" >/dev/null
    wait_node "$replica"
    event replica_restarted "Expected outcome: sync_full increments after backlog is overwritten"
    ;;
  reshard-atomic|reshard-legacy)
    primaries=()
    while IFS= read -r item; do
      primaries+=("$item")
    done < <(primary_services)
    source_primary="${primaries[0]}"
    target_primary="${primaries[1]}"
    source_id="$(node_id "$source_primary")"
    target_id="$(node_id "$target_primary")"
    event reshard_started "source=${source_primary} target=${target_primary} slots=${RESHARD_SLOTS:-1024} mode=${scenario#reshard-}"
    reshard_args=(--cluster reshard valkey-1:6379 --cluster-from "$source_id" --cluster-to "$target_id" --cluster-slots "${RESHARD_SLOTS:-1024}" --cluster-yes)
    if [[ "$scenario" == "reshard-atomic" ]]; then
      reshard_args+=(--cluster-use-atomic-slot-migration)
    fi
    if cluster_cli "${reshard_args[@]}" >"${run_dir}/reshard.log" 2>&1; then
      event reshard_completed "mode=${scenario#reshard-}"
    else
      event reshard_failed "See reshard.log"
    fi
    ;;
  bgsave)
    previous_lastsave="$(cli "$primary" LASTSAVE | tr -d '\r')"
    bgsave_epoch="$(date +%s)"
    event bgsave_requested "$primary"
    cli "$primary" BGSAVE >/dev/null
    event bgsave_started "Watch current_cow_peak latest_fork_usec and RSS"
    bgsave_deadline=$((bgsave_epoch + fault))
    bgsave_completed=0
    while (( $(date +%s) < bgsave_deadline )); do
      persistence="$(cli "$primary" INFO persistence 2>/dev/null || true)"
      last_save="$(info_value "$persistence" rdb_last_save_time)"
      in_progress="$(info_value "$persistence" rdb_bgsave_in_progress)"
      if [[ -n "$last_save" && "$last_save" -gt "$previous_lastsave" && "${in_progress:-0}" == "0" ]]; then
        now_epoch="$(date +%s)"
        last_cow="$(info_value "$persistence" rdb_last_cow_size)"
        fork_usec="$(info_value "$persistence" latest_fork_usec)"
        event bgsave_completed "elapsed=$((now_epoch - bgsave_epoch))s rdb_last_cow_size=${last_cow:-0} latest_fork_usec=${fork_usec:-0}"
        bgsave_completed=1
        break
      fi
      sleep 1
    done
    if [[ "$bgsave_completed" == "0" ]]; then
      event bgsave_completion_not_observed "Check INFO persistence and loadgen duration"
    fi
    remaining=$((bgsave_deadline - $(date +%s)))
    if (( remaining > 0 )); then
      sleep "$remaining"
    fi
    ;;
  failover-none|failover-immediate|failover-jitter)
    failed_primary_id="$(node_id "$primary")"
    promotion_candidate_id="$(node_id "$replica")"
    "${COMPOSE[@]}" stop -t 1 "$primary" >/dev/null
    failure_epoch="$(date +%s)"
    event primary_stopped "$primary; retry=${retry_policy}"

    fault_deadline=$((failure_epoch + fault))
    failure_detected=0
    promotion_detected=0
    while (( $(date +%s) < fault_deadline )); do
      observer="$(first_running_core)"
      nodes="$(cli "$observer" CLUSTER NODES 2>/dev/null || true)"
      failed_flags="$(awk -v id="$failed_primary_id" '$1 == id {print $3; exit}' <<<"$nodes")"
      candidate_flags="$(awk -v id="$promotion_candidate_id" '$1 == id {print $3; exit}' <<<"$nodes")"
      now_epoch="$(date +%s)"

      if [[ "$failure_detected" == "0" ]] && has_cluster_flag "$failed_flags" fail; then
        event failure_detected "$primary; elapsed=$((now_epoch - failure_epoch))s observer=${observer}"
        failure_detected=1
      fi
      if [[ "$promotion_detected" == "0" ]] && has_cluster_flag "$candidate_flags" master; then
        event replica_promoted "$replica; elapsed=$((now_epoch - failure_epoch))s observer=${observer}"
        promotion_detected=1
      fi
      if [[ "$failure_detected" == "1" && "$promotion_detected" == "1" ]]; then
        break
      fi
      sleep 1
    done

    if [[ "$failure_detected" == "0" ]]; then
      event failure_detection_not_observed "$primary within ${fault}s"
    fi
    if [[ "$promotion_detected" == "0" ]]; then
      event promotion_not_observed "$replica within ${fault}s"
    fi

    remaining=$((fault_deadline - $(date +%s)))
    if (( remaining > 0 )); then
      sleep "$remaining"
    fi
    "${COMPOSE[@]}" start "$primary" >/dev/null
    wait_node "$primary"
    event old_primary_restarted "$primary"
    ;;
  add-replicas)
    primary_id="$(node_id "$primary")"
    primary_ip="$(cli "$primary" CLUSTER NODES | awk -v id="$primary_id" '$1 == id {split($2,a,"@"); split(a[1],b,":"); print b[1]}')"
    "${COMPOSE[@]}" --profile scale up -d valkey-7 valkey-8 >/dev/null
    wait_node valkey-7
    wait_node valkey-8
    cli valkey-7 CLUSTER RESET HARD >/dev/null || true
    cli valkey-8 CLUSTER RESET HARD >/dev/null || true
    cli valkey-7 CLUSTER MEET "$primary_ip" 6379 >/dev/null
    cli valkey-8 CLUSTER MEET "$primary_ip" 6379 >/dev/null
    wait_for_node_id valkey-7 "$primary_id" 30
    wait_for_node_id valkey-8 "$primary_id" 30
    event replicas_joining "valkey-7 and valkey-8 -> ${primary}"
    cli valkey-7 CLUSTER REPLICATE "$primary_id" >/dev/null
    cli valkey-8 CLUSTER REPLICATE "$primary_id" >/dev/null
    event replica_sync_started "Two new replicas synchronized concurrently"
    ;;
esac

set +e
wait "$load_pid"
load_status=$?
set -e
load_pid=""
wait "$collector_pid" || true
collector_pid=""
event scenario_end "loadgen_exit=${load_status}"

runner="$(first_running_core)"
cli "$runner" CLUSTER NODES >"${run_dir}/cluster-nodes-after.txt" || true
cli "$runner" CONFIG GET repl-backlog-size maxmemory maxmemory-policy appendonly appendfsync \
  >"${run_dir}/valkey-config-after.txt" || true
python3 "${SCRIPT_DIR}/report.py" "$run_dir" || true

trap - EXIT INT TERM
cleanup
log "Scenario results: ${run_dir}"
exit "$load_status"
