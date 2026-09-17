# Failure-oriented Valkey benchmark matrix

Use the same hardware, Valkey build, dataset, value distribution, client count, pipeline behavior, and offered rate for every comparison. Start each scenario from a fresh cluster and repeat it at least five times.

## Core test sequence

| ID | Scenario | Controlled intervention | Hypothesis | Primary evidence | Successful interpretation |
|---|---|---|---|---|---|
| E0 | Capacity envelope | Step offered load from low RPS to closed-loop saturation | Tail latency rises before peak throughput becomes useful as a capacity target | Achieved RPS, p99/p99.9, CPU, network, errors | Choose a resilience-test rate near 60% of the lowest repeatable saturation point—not 60% of the single best run |
| B0 | Sustained baseline | Hold the selected rate with no administrative action | A healthy cluster should reach a stable latency, replication-gap, memory and connection band | p99/p99.9, offset gap, RSS, connections | Establish the pre-fault band used by every recovery-time calculation |
| R1 | Replica interruption inside backlog | Stop one replica briefly, then restart it | The retained replication history is sufficient for incremental catch-up | `sync_partial_ok`, offset gap, catch-up time | No `sync_full` increment; gap returns to baseline within the recovery objective |
| R2 | Replica interruption beyond backlog | Reduce backlog, stop a replica until history is overwritten, restart it | Recovery crosses from partial to full synchronization | `sync_full`, primary output bandwidth, RSS/COW, foreground p99 | Quantify the cost and time of full state transfer rather than treating it as a binary event |
| S1 | Atomic reshard under writes | Move 1,024 slots between primaries using atomic migration | Snapshot and mutation streaming spend CPU, memory and network headroom | Migration duration, COW, replication buffers, p99, error rate | Compare against B0 using identical offered load and dataset |
| S2 | Legacy reshard under writes | Repeat S1 without atomic migration | Migration mechanism changes client and server impact | `ASK`/`MOVED`, duration, p99, errors | Treat this as a version/mode comparison, not a universal product claim |
| M1 | Snapshot under writes | Trigger `BGSAVE` on one primary | Fork/COW and snapshot work can increase RSS independently of logical dataset memory | `current_cow_peak`, `latest_fork_usec`, RSS, `used_memory` | Demonstrate why `used_memory < maxmemory` does not prove physical-memory safety |
| F1 | Failover, no application retry | Stop one primary | Server-side promotion is only part of application recovery | Error window, new primary time, steady-state recovery time | Establish the irreducible failure window without retry amplification |
| F2 | Failover, immediate retry | Repeat F1 with five immediate attempts | Retries increase physical work during the recovery window | Attempts/logical operation, connection attempts, errors, p99 | Show whether retries reduce logical errors or simply move pressure onto the recovering cluster |
| F3 | Failover, jittered retry | Repeat F1 with bounded exponential backoff and jitter | Spreading retry work reduces synchronization and connection peaks | Attempt amplification, connection creation rate, time to steady state | Compare directly with F2; keep total retry budget identical |
| A1 | Add two replicas under writes | Attach two empty replicas to one primary concurrently | More promotion options impose immediate synchronization cost | `sync_full`, output bandwidth, buffers, p99, sync duration | Separate steady-state redundancy benefit from replica-creation cost |
| H1 | Hot-slot skew | Direct 60% of writes to eight hash tags | Aggregate headroom can hide a saturated shard | Per-node ops, network, memory, p99 | Size for the hottest shard, not only cluster-wide averages |

## Required calculations

### Replication debt

For each primary-replica link:

\[
\text{offset gap bytes} = \text{primary offset} - \text{replica offset}
\]

Report both the maximum gap and how long it takes to return to the baseline band.

### Backlog coverage

\[
\text{coverage seconds} \approx
\frac{\text{usable backlog bytes}}
{\text{replication-stream bytes per second}}
\]

Measure stream byte rate from offset growth during the stable baseline. Do not calculate it from logical operations per second alone.

### Retry amplification

\[
\text{attempt amplification} =
\frac{\text{physical request attempts}}
{\text{logical CDC operations}}
\]

An amplification of 2.4 means the cluster received, on average, 2.4 physical attempts for every logical operation offered by the producer.

### Recovery to steady state

Define a baseline p99 band before injecting the fault. Recovery is the first sustained interval—recommendation: 30 seconds—in which:

- p99 is back inside the baseline band;
- error rate is within the SLO;
- replication gap is stable or decreasing to baseline;
- connection-creation rate is back inside its baseline band.

Promotion time alone is not application recovery time.

## Recommended controlled variables

- Exact Valkey version and container/image digest
- CPU model, core allocation, NUMA placement and frequency policy
- Memory/container limits, swap and `vm.overcommit_memory`
- Network bandwidth, RTT and availability-zone placement
- Persistence mode and `fsync` policy
- Dataset cardinality, update/insert/delete mix and TTL distribution
- Value-size distribution—not only average value size
- Hot-key/hash-tag distribution
- Client library/version, connection count, pipeline depth and topology-refresh interval
- Offered rate and retry budget
- Warm-up, fault, recovery and total duration
- Repetition count and whether displayed values are median, best, worst, or a specific run

## Minimum publication standard

For conference charts, run on dedicated Linux hosts or dedicated VM instances rather than Docker Desktop. Use at least two load-generator hosts so client CPU does not become the apparent server limit. Repeat every test five times, retain every raw run, and publish the median with the observed range. Label any synthetic or normalized chart explicitly.
