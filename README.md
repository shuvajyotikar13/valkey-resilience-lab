# Valkey write-heavy resilience lab

This kit tests the argument behind **Beyond Throughput: Production Lessons from Running Write-Heavy Valkey Clusters**:

> A write-heavy cluster becomes unsafe when maintenance and recovery operations consume the same replication, memory, network, and connection headroom needed to sustain the workload.

It provisions Valkey 9.1.2 as a three-primary cluster with one replica per primary, generates a production-inspired CDC workload, records one-second server/client signals, injects controlled failures, and creates a compact run report.

The Docker topology is for fast functional reproduction and rehearsal. Do not publish laptop or Docker Desktop results as Valkey performance claims. The final talk measurements should run on dedicated Linux hosts or comparable isolated VMs.

## What is included

- Pinned Valkey 9.1.2 six-node cluster, plus two optional empty replica nodes
- Cluster-aware Go workload generator using `valkey-go` 1.0.77
- Controlled offered-rate generation that includes scheduler queueing in latency
- CDC-shaped operation mix: 85% updates, 10% inserts and 5% deletes by default
- Weighted value-size distribution and optional hot-slot skew
- Three retry modes: none, immediate and bounded exponential backoff with jitter
- One-second collection of replication, memory, fork/COW, eviction, network and connection metrics
- Atomic and legacy resharding scenarios
- Markdown report plus an optional four-panel PNG chart

See [docs/test-matrix.md](docs/test-matrix.md) for the experiment hypotheses and interpretation rules.

## Fast boot

Prerequisites:

- Docker Engine or Docker Desktop with Compose v2
- At least 8 GB available memory for a comfortable local run
- Python 3 for the report summary
- Optional: `pip install -r requirements-report.txt` for PNG charts

Start with:

```bash
cp .env.example .env
make build
make up
make preload
make baseline
```

Results are written beneath `results/<timestamp>-<scenario>/`. Each run retains the resolved Compose configuration, Valkey configuration, topology, one-second CSVs, workload summary, event timeline and generated report.
The environment capture also records the local image ID and repository digest so charts can be traced back to the exact server build.

To rebuild a completely fresh test cluster before a scenario:

```bash
RESET_BEFORE_RUN=1 make replica-partial
```

`make reset` deletes only this lab's containers and named volumes.

## Recommended execution order

### 1. Find the workload envelope

```bash
make envelope
```

The default stages are 10k, 20k, 40k, 80k RPS and then a closed-loop run. Override them as needed:

```bash
ENVELOPE_RPS="20000 40000 60000 80000 100000" ENVELOPE_STAGE_SECONDS=120 make envelope
```

Choose the resilience-test rate at roughly 60% of the **lowest repeatable saturation point** across multiple runs. Put that value in `.env` as `TARGET_RPS`. The objective is to leave measurable headroom for recovery, not to run every fault at maximum throughput.

### 2. Establish the sustained baseline

```bash
RESET_BEFORE_RUN=1 BASELINE_SECONDS=600 make baseline
```

Use this run to define the normal p99, error-rate, replication-gap, RSS and connection bands.

### 3. Test backlog coverage

```bash
RESET_BEFORE_RUN=1 PARTIAL_OUTAGE_SECONDS=5 make replica-partial
RESET_BEFORE_RUN=1 FULL_OUTAGE_SECONDS=30 FULL_SYNC_BACKLOG=1mb make replica-full
```

The first test should usually recover incrementally. The second deliberately shrinks the primary backlog before disconnecting its replica, making full synchronization likely once the write stream overwrites retained history. Verify the outcome from `sync_partial_ok`, `sync_partial_err` and `sync_full`; do not infer it only from elapsed time.

### 4. Compare slot-migration modes

```bash
RESET_BEFORE_RUN=1 RESHARD_SLOTS=1024 make reshard-atomic
RESET_BEFORE_RUN=1 RESHARD_SLOTS=1024 make reshard-legacy
```

Atomic migration is explicitly requested through Valkey 9.1's `--cluster-use-atomic-slot-migration` CLI option. Keep the exact version and mode on the published chart.

### 5. Measure memory amplification

```bash
RESET_BEFORE_RUN=1 make bgsave
```

Watch `used_memory`, `used_memory_rss`, `current_cow_peak`, `latest_fork_usec`, `mem_not_counted_for_evict`, replication buffers and evictions together. Increase `PRELOAD_KEYS` and the container limit cautiously if the local dataset is too small to produce visible COW behavior.

To test AOF rewrite separately, set `APPENDONLY=yes`, rebuild a fresh cluster, and replace the injected `BGSAVE` command with `BGREWRITEAOF` in a copied scenario. Do not combine the two mechanisms in the first experiment.

### 6. Compare client recovery policies

```bash
RESET_BEFORE_RUN=1 make failover-none
RESET_BEFORE_RUN=1 make failover-immediate
RESET_BEFORE_RUN=1 make failover-jitter
```

All three tests stop a primary and allow the cluster to detect and promote a replica. Compare physical attempts per logical operation, connection-attempt rate, p99, errors and time to return to the baseline band. `SET` and `DEL` are used so bounded retries are idempotent for this laboratory workload; do not generalize that safety to arbitrary application commands.

### 7. Measure replica-creation cost and skew

```bash
RESET_BEFORE_RUN=1 make add-replicas
RESET_BEFORE_RUN=1 HOT_PCT=60 HOT_KEYS=8 make hot-skew
```

The replica test attaches two empty replicas to one primary while writes continue. The skew test sends 60% of operations to eight hash tags, exposing per-shard saturation hidden by cluster-wide averages.

## Useful configuration knobs

Workload values belong in `.env`:

```dotenv
TARGET_RPS=30000
WORKERS=32
PRELOAD_KEYS=250000
KEYSPACE=250000
VALUE_SIZES=256:70,1024:25,4096:5
```

Server values can also be changed in `.env`; the Compose command overrides the corresponding values in `configs/valkey.conf`:

```dotenv
NODE_MEMORY_LIMIT=768m
VALKEY_MAXMEMORY=512mb
VALKEY_MAXMEMORY_POLICY=allkeys-lru
REPL_BACKLOG_SIZE=64mb
APPENDONLY=no
CLUSTER_NODE_TIMEOUT_MS=3000
```

The weighted value sizes must total 100. Keep the update/insert/delete percentages totaling 100 when overriding `UPDATE_PCT`, `INSERT_PCT` or `DELETE_PCT`.

## Reporting

Every scenario automatically runs the report generator. To regenerate with explicit acceptance gates:

```bash
python3 scripts/report.py results/<run-directory> \
  --slo-p99-ms 10 \
  --slo-error-rate 0.001 \
  --max-amplification 1.20
```

The error rate is a fraction: `0.001` means 0.1%.
The report estimates replication-stream bytes per second from primary offset growth and converts the configured backlog into an approximate coverage window. Treat it as a sizing estimate and validate it against the observed partial/full synchronization outcome.

The main raw files are:

| File | Purpose |
|---|---|
| `workload.csv` | Logical ops, physical attempts, connection attempts, errors and sampled latency per second |
| `server.csv` | Per-node replication, memory, fork, eviction, traffic and connection metrics |
| `replication-links.csv` | Primary-to-replica offset gap and backlog state |
| `events.csv` | Exact intervention timeline |
| `summary.json` | Workload configuration and totals |
| `report.md` | Run-level interpretation sheet |
| `overview.png` | Optional chart when Matplotlib is installed |

## Conference-grade topology

For defensible results, move from the local Compose topology to:

- Six dedicated Valkey hosts: three primaries and three replicas
- Two independent load-generator hosts
- A separate collection host if monitoring overhead is material
- Synchronized clocks and a fixed-duration warm-up
- Fixed CPU placement/frequency policy where the environment allows it
- No swap and enough physical memory for the dataset plus buffers and worst-case COW
- Recorded network bandwidth and RTT between every primary/replica pair

Run each scenario at least five times. Publish the median together with the observed range, and preserve every raw run. Clearly distinguish production-derived workload characteristics from failures reproduced in this controlled Valkey environment.

## Important limitations

- The local workload approximates CDC shape; it is not a replay of your production event stream.
- The generator counts application-level attempts and TCP dials. A client library may also perform internal cluster redirects; those should be correlated with server/client logs if exact redirect counts are required.
- Docker resource isolation, virtualized networking and host scheduling can distort absolute performance.
- `MONITOR` is intentionally not used because it materially changes the workload being measured.
- The scenario scripts intentionally stop nodes and remove lab volumes only when explicitly asked through `make reset` or `RESET_BEFORE_RUN=1`. Never point these scripts at a production Compose project.

## Source references

- [Valkey benchmarking guidance](https://valkey.io/topics/benchmark/)
- [Valkey replication](https://valkey.io/topics/replication/)
- [Valkey atomic slot migration](https://valkey.io/topics/atomic-slot-migration/)
- [Valkey `INFO` metrics](https://valkey.io/commands/info/)
- [Valkey key eviction and non-evictable memory](https://valkey.io/topics/lru-cache/)
- [Valkey `CLUSTER FAILOVER`](https://valkey.io/commands/cluster-failover/)
- [`valkey-go`](https://github.com/valkey-io/valkey-go)
