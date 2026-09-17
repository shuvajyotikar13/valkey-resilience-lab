# Valkey resilience test catalog

This runbook lists the resilience conditions supported by the lab, the command for each test, the signals to inspect, and the conclusion each test can support.

The tests are designed for the failure chain discussed in **Beyond Throughput: Production Lessons from Running Write-Heavy Valkey Clusters**:

> sustained writes → replication debt → operational work consumes headroom → expensive recovery → client amplification

## Safety and interpretation

- Run these commands only against the Docker Compose cluster in this repository.
- `RESET_BEFORE_RUN=1` removes and recreates this lab's containers and named data volumes.
- Do not publish Docker Desktop or laptop results as general Valkey performance claims.
- Use the same server version, dataset, workload, client configuration and offered rate for every comparison.
- Repeat conference-grade experiments at least five times and publish the median with the observed range.
- Label controlled fault injection separately from a naturally observed failure.

## One-time setup

```bash
cp .env.example .env
make build
make up
make preload
make status
```

The default topology contains three primaries and one replica per primary. Two additional empty nodes are started only by the replica-addition test.

Before running failure tests, use the capacity-envelope test to select `TARGET_RPS`. A reasonable starting point is approximately 60% of the lowest repeatable saturation point across multiple runs.

## Quick test catalog

| ID | Resilience condition | Command | Main comparison |
|---|---|---|---|
| E0 | Healthy capacity envelope | `make envelope` | Offered rate vs achieved rate and tail latency |
| B0 | Sustained healthy baseline | `RESET_BEFORE_RUN=1 make baseline` | Normal latency, replication, memory and connection bands |
| R1 | Replica outage inside backlog coverage | `RESET_BEFORE_RUN=1 make replica-partial` | Partial synchronization and catch-up time |
| R2 | Replica outage beyond backlog coverage | `RESET_BEFORE_RUN=1 make replica-full` | Full synchronization cost |
| S1 | Atomic slot migration under writes | `RESET_BEFORE_RUN=1 make reshard-atomic` | Baseline vs migration resource consumption |
| S2 | Legacy slot migration under writes | `RESET_BEFORE_RUN=1 make reshard-legacy` | Atomic vs legacy migration behavior |
| M1 | Snapshot/COW under writes | `RESET_BEFORE_RUN=1 make bgsave` | Dataset memory vs RSS and COW |
| F1 | Primary loss without application retry | `RESET_BEFORE_RUN=1 make failover-none` | Server/topology recovery window |
| F2 | Primary loss with immediate retry | `RESET_BEFORE_RUN=1 make failover-immediate` | Retry amplification and connection spike |
| F3 | Primary loss with bounded jitter | `RESET_BEFORE_RUN=1 make failover-jitter` | Immediate vs distributed retry load |
| A1 | Add empty replicas under writes | `RESET_BEFORE_RUN=1 make add-replicas` | Redundancy benefit vs synchronization cost |
| H1 | Hot-slot traffic skew | `RESET_BEFORE_RUN=1 make hot-skew` | Cluster average vs hottest-shard behavior |

## E0 — Find the healthy workload envelope

**Question:** At what offered rate does the healthy cluster stop behaving predictably?

```bash
make envelope
```

Override the offered-rate stages and duration:

```bash
ENVELOPE_RPS="20000 40000 60000 80000 100000" \
ENVELOPE_STAGE_SECONDS=120 \
make envelope
```

Inspect:

- offered rate versus achieved logical operations per second;
- dropped offered-load tokens;
- p99 and p99.9 latency;
- error rate;
- per-node CPU, memory and network utilization;
- replication offset-gap behavior.

Interpretation:

- Tail latency, queueing or replication debt may deteriorate before throughput plateaus.
- Select the resilience-test rate below the lowest repeatable saturation point.
- If tokens are dropped, the load generator has reached its own scheduling/buffering limit; do not attribute the result only to Valkey.

## B0 — Establish the sustained baseline

**Question:** What does stable behavior look like before a fault or administrative operation?

```bash
RESET_BEFORE_RUN=1 BASELINE_SECONDS=600 make baseline
```

Inspect:

- achieved logical operations per second;
- p99 and p99.9 latency;
- error rate;
- primary-replica offset gaps;
- estimated replication-stream bytes per second;
- estimated backlog coverage;
- `used_memory`, RSS and connection-creation rate.

Interpretation:

- Define the normal band for every signal used in later recovery calculations.
- Promotion or migration is not complete operationally until the signals return to this band for a sustained interval.

## R1 — Replica recovery inside backlog coverage

**Question:** Can a disconnected replica recover incrementally from retained history?

```bash
RESET_BEFORE_RUN=1 \
PARTIAL_OUTAGE_SECONDS=5 \
make replica-partial
```

The test stops one replica briefly, continues writes, restarts it and observes catch-up.

Inspect:

- offset gap while the replica is stopped;
- backlog size and history length;
- `sync_partial_ok`, `sync_partial_err` and `sync_full`;
- replica catch-up time;
- primary output bandwidth and foreground p99.

Expected result:

- `sync_partial_ok` increases;
- `sync_full` does not increase;
- the gap returns to the baseline band within the recovery objective.

## R2 — Replica recovery beyond backlog coverage

**Question:** What is the cost when the missing replication history has been overwritten?

```bash
RESET_BEFORE_RUN=1 \
FULL_OUTAGE_SECONDS=30 \
FULL_SYNC_BACKLOG=1mb \
make replica-full
```

The test deliberately reduces the primary backlog, disconnects a replica and allows sustained writes to overwrite the required history.

Inspect:

- `sync_full` and `sync_partial_err` counter changes;
- snapshot/fork activity;
- primary network-output spike;
- replication buffers and COW memory;
- p99, errors and time back to baseline.

Expected result:

- full synchronization occurs;
- recovery consumes materially more network, memory and time than R1.

Use R1 and R2 together to demonstrate that backlog is a recovery window rather than an arbitrary memory setting.

## S1 — Atomic resharding under sustained writes

**Question:** How much production headroom does online slot migration consume?

```bash
RESET_BEFORE_RUN=1 \
RESHARD_SLOTS=1024 \
make reshard-atomic
```

Inspect:

- source and target network throughput;
- migration duration;
- replication offset gaps;
- RSS and COW memory;
- replication/migration buffers;
- p99, p99.9 and error rate;
- per-node load rather than only cluster averages.

Interpretation:

- Application throughput can remain stable while replication, network and memory headroom deteriorate.
- Treat resharding as production workload and gate it on observed headroom.

## S2 — Legacy versus atomic migration

**Question:** How does the slot-migration mechanism affect clients and servers?

```bash
RESET_BEFORE_RUN=1 RESHARD_SLOTS=1024 make reshard-legacy
RESET_BEFORE_RUN=1 RESHARD_SLOTS=1024 make reshard-atomic
```

Keep the dataset, offered rate and number of slots identical.

Inspect:

- migration duration;
- p99 and errors;
- source/target resource use;
- topology refresh and redirect behavior;
- replication gaps.

Interpretation:

- Pin conclusions to the exact Valkey version and migration mode.
- Treat this as a controlled mechanism comparison, not a universal product claim.

## M1 — Snapshot and copy-on-write pressure

**Question:** Why can physical memory become unsafe while logical dataset memory remains below `maxmemory`?

```bash
RESET_BEFORE_RUN=1 make bgsave
```

Inspect:

- `used_memory` and `used_memory_rss`;
- `current_cow_peak` and `current_cow_size`;
- `latest_fork_usec`;
- `mem_not_counted_for_evict`;
- replication and client buffers;
- container memory and OOM events;
- foreground p99.

Interpretation:

- Dataset capacity and process/container capacity are different budgets.
- Claim an OOM-driven failure only when the container state or kernel/runtime event confirms it.

## F1 — Primary loss without application retries

**Question:** What is the underlying failure-detection and topology-recovery window?

```bash
RESET_BEFORE_RUN=1 make failover-none
```

Inspect:

- primary-stop timestamp;
- failure-detection and replica-promotion timing;
- offset of the promoted replica;
- logical error window;
- topology refresh and connection attempts;
- time until p99 and errors return to baseline.

Interpretation:

- This is the control for F2 and F3.
- Separate time-to-promotion from time-to-application-recovery.

## F2 — Primary loss with immediate retries

**Question:** Do synchronized retries reduce errors or create additional recovery load?

```bash
RESET_BEFORE_RUN=1 \
FAILOVER_MAX_ATTEMPTS=5 \
make failover-immediate
```

Inspect:

- physical attempts versus logical operations;
- peak attempt amplification;
- TCP dials and new server connections;
- p99, p99.9 and errors;
- rejected connections;
- time back to the baseline band.

Interpretation:

```text
attempt amplification = physical attempts / logical operations
```

Immediate retries may hide some logical errors while increasing instantaneous pressure on the recovering cluster.

## F3 — Primary loss with bounded exponential backoff and jitter

**Question:** Can the same retry budget be distributed without a synchronized storm?

```bash
RESET_BEFORE_RUN=1 \
FAILOVER_MAX_ATTEMPTS=5 \
RETRY_BASE=10ms \
RETRY_CAP=250ms \
make failover-jitter
```

Compare directly with F2 using the same maximum attempts and request timeout.

Inspect:

- peak attempts per second;
- total attempt amplification;
- connection-attempt rate;
- logical error rate;
- p99 and recovery duration.

Expected result:

- retry work is spread across a wider interval;
- instantaneous connection and attempt peaks are lower than F2;
- topology has more time to converge.

## A1 — Add replicas while writes continue

**Question:** Can creating redundancy temporarily reduce resilience?

```bash
RESET_BEFORE_RUN=1 make add-replicas
```

The test attaches two empty replicas to one primary concurrently.

Inspect:

- full synchronization count;
- primary output bandwidth;
- replication buffers and RSS/COW;
- existing-replica offset gap;
- foreground p99;
- time until both replicas are usable.

Interpretation:

- More replicas improve future promotion options.
- Initial synchronization consumes the same resources required by foreground writes and existing replicas.

## H1 — Hot-slot and shard-skew behavior

**Question:** Can cluster-wide averages hide an overloaded shard?

```bash
RESET_BEFORE_RUN=1 \
HOT_PCT=60 \
HOT_KEYS=8 \
make hot-skew
```

Inspect:

- per-primary operations and network throughput;
- replication gap per primary/replica link;
- per-node RSS and evictions;
- cluster-average versus maximum per-node utilization;
- p99 and p99.9.

Interpretation:

- Size and alert on the hottest failure domain rather than only cluster averages.
- Use this run to justify why a reshard was already in progress in the talk's reconstructed incident.

## Recommended talk evidence sequence

Run these first if the objective is to create the conference evidence rather than exercise every scenario:

```bash
make envelope
RESET_BEFORE_RUN=1 BASELINE_SECONDS=600 make baseline
RESET_BEFORE_RUN=1 make replica-partial
RESET_BEFORE_RUN=1 FULL_OUTAGE_SECONDS=30 FULL_SYNC_BACKLOG=1mb make replica-full
RESET_BEFORE_RUN=1 RESHARD_SLOTS=1024 make reshard-atomic
RESET_BEFORE_RUN=1 make bgsave
RESET_BEFORE_RUN=1 make failover-none
RESET_BEFORE_RUN=1 FAILOVER_MAX_ATTEMPTS=5 make failover-immediate
RESET_BEFORE_RUN=1 FAILOVER_MAX_ATTEMPTS=5 make failover-jitter
```

The primary talk comparisons should be:

1. E0/B0 — healthy throughput versus predictable operation;
2. R1/R2 — partial versus full synchronization;
3. B0/S1/M1 — application load versus operational memory and network work;
4. F1/F2/F3 — promotion versus complete client recovery.

Use A1, H1 and S2 as supporting or backup evidence.

## Common workload controls

Set these in `.env` or provide them for an individual command:

```dotenv
TARGET_RPS=30000
WORKERS=32
PRELOAD_KEYS=250000
KEYSPACE=250000
VALUE_SIZES=256:70,1024:25,4096:5
```

Server controls:

```dotenv
NODE_MEMORY_LIMIT=768m
VALKEY_MAXMEMORY=512mb
VALKEY_MAXMEMORY_POLICY=allkeys-lru
REPL_BACKLOG_SIZE=64mb
APPENDONLY=no
CLUSTER_NODE_TIMEOUT_MS=3000
```

Change one causal variable at a time. If the workload, dataset and server configuration all change together, the comparison cannot establish which change caused the result.

## Results and reports

Each scenario writes to:

```text
results/<timestamp>-<scenario>/
```

Important files:

| File | Contents |
|---|---|
| `workload.csv` | Logical operations, physical attempts, dials, errors and sampled latency |
| `server.csv` | Per-node replication, memory, fork, eviction, network and connection metrics |
| `replication-links.csv` | Offset gaps and backlog state for each primary-replica link |
| `events.csv` | Exact intervention timeline |
| `summary.json` | Workload configuration and totals |
| `report.md` | Generated run summary and interpretation checklist |
| `overview.png` | Optional four-panel chart when Matplotlib is installed |

Regenerate a report with explicit gates:

```bash
python3 scripts/report.py results/<run-directory> \
  --slo-p99-ms 10 \
  --slo-error-rate 0.001 \
  --max-amplification 1.20
```

The error-rate argument is a fraction: `0.001` means 0.1%.

## Minimum comparison checklist

Before accepting a result, confirm:

- the environment and image digest were recorded;
- warm-up completed before fault injection;
- achieved rate stayed close to the intended offered rate;
- dropped offered-load tokens did not invalidate the run;
- baseline and fault runs used the same dataset and workload;
- the intervention timestamp appears in `events.csv`;
- recovery is measured back to the baseline band, not only until promotion or command completion;
- the result is repeatable across multiple runs.
