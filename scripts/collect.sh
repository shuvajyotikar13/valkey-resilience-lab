#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

out_dir="${1:?usage: collect.sh OUTPUT_DIR [INTERVAL_SECONDS] [DURATION_SECONDS]}"
interval="${2:-1}"
duration="${3:-0}"
mkdir -p "$out_dir"
server_csv="${out_dir}/server.csv"
links_csv="${out_dir}/replication-links.csv"
docker_stats="${out_dir}/docker-stats.log"

printf '%s\n' 'timestamp,epoch_s,node,role,master_link_status,master_sync_in_progress,master_last_io_seconds_ago,connected_slaves,master_repl_offset,slave_repl_offset,repl_backlog_size,repl_backlog_histlen,sync_full,sync_partial_ok,sync_partial_err,used_memory,used_memory_rss,used_memory_dataset,maxmemory,mem_not_counted_for_evict,mem_replication_backlog,mem_total_replication_buffers,mem_clients_normal,mem_clients_slaves,mem_aof_buffer,current_cow_peak,current_cow_size,latest_fork_usec,evicted_keys,total_eviction_exceeded_time,instantaneous_ops_per_sec,instantaneous_input_kbps,instantaneous_output_kbps,connected_clients,total_connections_received,rejected_connections,cluster_connections,total_net_input_bytes,total_net_output_bytes,cluster_state,cluster_slots_fail,cluster_known_nodes' >"$server_csv"
printf '%s\n' 'timestamp,epoch_s,primary,replica_ip,replica_port,state,primary_offset,replica_offset,gap_bytes,reported_lag_s,backlog_size,backlog_histlen' >"$links_csv"
: >"$docker_stats"

start="$(date +%s)"
iteration=0
while true; do
  now="$(date +%s)"
  if [[ "$duration" -gt 0 && $((now - start)) -ge "$duration" ]]; then
    break
  fi
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  for node in "${CORE_NODES[@]}" valkey-7 valkey-8; do
    if ! is_running "$node"; then
      continue
    fi
    info="$(cli "$node" INFO ALL 2>/dev/null || true)"
    cluster="$(cli "$node" CLUSTER INFO 2>/dev/null || true)"
    if [[ -z "$info" ]]; then
      continue
    fi
    printf '%s\n%s\n' "$info" "$cluster" | awk -F: \
      -v ts="$timestamp" -v epoch="$now" -v node="$node" \
      -v server_file="$server_csv" -v links_file="$links_csv" '
      function clean(v) { gsub(/\r/, "", v); return v }
      function value_or_zero(v) { return v == "" ? 0 : v }
      $1 == "role" { role=clean($2) }
      $1 == "master_link_status" { master_link_status=clean($2) }
      $1 == "master_sync_in_progress" { master_sync=clean($2) }
      $1 == "master_last_io_seconds_ago" { master_last_io=clean($2) }
      $1 == "connected_slaves" { connected_slaves=clean($2) }
      $1 == "master_repl_offset" { master_offset=clean($2) }
      $1 == "slave_repl_offset" { slave_offset=clean($2) }
      $1 == "repl_backlog_size" { backlog_size=clean($2) }
      $1 == "repl_backlog_histlen" { backlog_histlen=clean($2) }
      $1 == "sync_full" { sync_full=clean($2) }
      $1 == "sync_partial_ok" { sync_partial_ok=clean($2) }
      $1 == "sync_partial_err" { sync_partial_err=clean($2) }
      $1 == "used_memory" { used_memory=clean($2) }
      $1 == "used_memory_rss" { used_memory_rss=clean($2) }
      $1 == "used_memory_dataset" { used_memory_dataset=clean($2) }
      $1 == "maxmemory" { maxmemory=clean($2) }
      $1 == "mem_not_counted_for_evict" { mem_not_counted=clean($2) }
      $1 == "mem_replication_backlog" { mem_backlog=clean($2) }
      $1 == "mem_total_replication_buffers" { mem_repl_buffers=clean($2) }
      $1 == "mem_clients_normal" { mem_clients_normal=clean($2) }
      $1 == "mem_clients_slaves" { mem_clients_slaves=clean($2) }
      $1 == "mem_aof_buffer" { mem_aof_buffer=clean($2) }
      $1 == "current_cow_peak" { current_cow_peak=clean($2) }
      $1 == "current_cow_size" { current_cow_size=clean($2) }
      $1 == "latest_fork_usec" { latest_fork_usec=clean($2) }
      $1 == "evicted_keys" { evicted_keys=clean($2) }
      $1 == "total_eviction_exceeded_time" { eviction_time=clean($2) }
      $1 == "instantaneous_ops_per_sec" { ops=clean($2) }
      $1 == "instantaneous_input_kbps" { input_kbps=clean($2) }
      $1 == "instantaneous_output_kbps" { output_kbps=clean($2) }
      $1 == "connected_clients" { connected_clients=clean($2) }
      $1 == "total_connections_received" { total_connections=clean($2) }
      $1 == "rejected_connections" { rejected_connections=clean($2) }
      $1 == "cluster_connections" { cluster_connections=clean($2) }
      $1 == "total_net_input_bytes" { net_in=clean($2) }
      $1 == "total_net_output_bytes" { net_out=clean($2) }
      $1 == "cluster_state" { cluster_state=clean($2) }
      $1 == "cluster_slots_fail" { cluster_slots_fail=clean($2) }
      $1 == "cluster_known_nodes" { cluster_known_nodes=clean($2) }
      $1 ~ /^slave[0-9]+$/ { slave_line[++slave_count]=clean($2) }
      END {
        OFS=",";
        print ts,epoch,node,role,master_link_status,value_or_zero(master_sync),value_or_zero(master_last_io),
          value_or_zero(connected_slaves),value_or_zero(master_offset),value_or_zero(slave_offset),
          value_or_zero(backlog_size),value_or_zero(backlog_histlen),value_or_zero(sync_full),
          value_or_zero(sync_partial_ok),value_or_zero(sync_partial_err),value_or_zero(used_memory),
          value_or_zero(used_memory_rss),value_or_zero(used_memory_dataset),value_or_zero(maxmemory),
          value_or_zero(mem_not_counted),value_or_zero(mem_backlog),value_or_zero(mem_repl_buffers),
          value_or_zero(mem_clients_normal),value_or_zero(mem_clients_slaves),value_or_zero(mem_aof_buffer),
          value_or_zero(current_cow_peak),value_or_zero(current_cow_size),value_or_zero(latest_fork_usec),
          value_or_zero(evicted_keys),value_or_zero(eviction_time),value_or_zero(ops),value_or_zero(input_kbps),
          value_or_zero(output_kbps),value_or_zero(connected_clients),value_or_zero(total_connections),
          value_or_zero(rejected_connections),value_or_zero(cluster_connections),value_or_zero(net_in),
          value_or_zero(net_out),cluster_state,value_or_zero(cluster_slots_fail),value_or_zero(cluster_known_nodes) >> server_file;

        if (role == "master") {
          for (i=1; i<=slave_count; i++) {
            split(slave_line[i], pieces, ",");
            delete attrs;
            for (j in pieces) {
              split(pieces[j], pair, "=");
              attrs[pair[1]]=pair[2];
            }
            gap=value_or_zero(master_offset)-value_or_zero(attrs["offset"]);
            if (gap < 0) gap=0;
            print ts,epoch,node,attrs["ip"],attrs["port"],attrs["state"],value_or_zero(master_offset),
              value_or_zero(attrs["offset"]),gap,value_or_zero(attrs["lag"]),value_or_zero(backlog_size),
              value_or_zero(backlog_histlen) >> links_file;
          }
        }
      }'
  done

  if ((iteration % 5 == 0)); then
    printf '[%s]\n' "$timestamp" >>"$docker_stats"
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}' \
      $("${COMPOSE[@]}" ps -q 2>/dev/null) >>"$docker_stats" 2>/dev/null || true
  fi
  iteration=$((iteration + 1))
  sleep "$interval"
done
