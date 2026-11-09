# Valkey Resilience Lab + BetterDB
## Podman Setup, Startup & Shutdown Runbook

**Platform:** macOS (Apple Silicon)
**Container runtime:** Podman
**Compose provider:** podman-compose
**Valkey topology:** 3 primaries + 3 replicas
**Monitoring:** BetterDB
**Storage:** PostgreSQL
**BetterDB dashboard:** http://localhost:3001

---

## 1. Purpose

This runbook describes how to start, verify, and safely stop the Valkey Resilience Lab with BetterDB using Podman.

It is designed for repeatable use. Follow the steps in order whenever you want to bring up the environment.

The routine workflow is:

1. Navigate to the project.
2. Start Podman.
3. Start the Valkey cluster.
4. Start BetterDB and PostgreSQL.
5. Verify cluster health, replication, and monitoring.
6. Run experiments.
7. Stop services safely without deleting persistent data.

**Important:** Routine startup does not require rebuilding images, reinstalling dependencies, recreating the cluster, or deleting volumes.

---

## 2. Environment details

| Component | Configuration |
|---|---|
| Project directory | Your local clone of `valkey-resilience-lab` |
| Podman machine | `podman-machine-default` |
| Valkey nodes | 6 |
| Primaries | 3 |
| Replicas | 3 |
| Valkey host ports | 7001–7006 |
| BetterDB port | 3001 |
| BetterDB dashboard | http://localhost:3001 |
| BetterDB health endpoint | `http://127.0.0.1:3001/api/health` |
| BetterDB metrics endpoint | `http://127.0.0.1:3001/api/prometheus/metrics` |
| PostgreSQL database | `betterdb` |

### Valkey topology

| Node | Role | Replica relationship |
|---|---|---|
| valkey-1 | Primary | Replica: valkey-5 |
| valkey-2 | Primary | Replica: valkey-6 |
| valkey-3 | Primary | Replica: valkey-4 |
| valkey-4 | Replica | Primary: valkey-3 |
| valkey-5 | Replica | Primary: valkey-1 |
| valkey-6 | Replica | Primary: valkey-2 |

The cluster uses all 16,384 hash slots.

### Stable Podman network addresses

The six core Valkey nodes use fixed addresses on the Compose `bench` network:

| Node | Address |
|---|---|
| valkey-1 | `10.89.0.2` |
| valkey-2 | `10.89.0.3` |
| valkey-3 | `10.89.0.4` |
| valkey-4 | `10.89.0.5` |
| valkey-5 | `10.89.0.6` |
| valkey-6 | `10.89.0.7` |

The network uses the explicitly configured subnet `10.89.0.0/24`.

This is important because Valkey persists cluster membership and peer addresses in each node's `nodes.conf` file. If Podman recreates the network and assigns different addresses, the persisted cluster configuration can refer to stale peer addresses. Nodes may then fail to communicate or replicas may fail to reconnect.

**Operational guidance:**

- Keep the subnet and the six node addresses consistent across restarts.
- Do not change these addresses on an already initialized cluster without planning a cluster reconfiguration.
- Routine startup and shutdown should use the existing containers and persistent volumes.
- Do not delete Valkey volumes or `nodes.conf` files to address a networking problem.

BetterDB's PostgreSQL history is stored separately in the persistent volume `valkey-resilience-lab-betterdb-pgdata`. The startup script checks whether this volume already exists before creating it, so repeated `make betterdb-up` runs do not require deleting or recreating the volume.


---

## 3. Prerequisites

Ensure the following tools are installed:

- Podman
- podman-compose
- Make
- curl

Check versions:

```bash
podman --version
podman compose version
make --version
```

The verified environment used Podman 6.1.4 and podman-compose 1.6.0.

---

## 4. Startup procedure

### Step 1: Navigate to the project

Open Terminal:

```bash
cd /path/to/valkey-resilience-lab
```

Verify:

```bash
pwd
```

Expected:

```text
/path/to/valkey-resilience-lab
```

### Step 2: Start Podman

```bash
podman machine start
```

If the machine is already running, no action is required.

Verify Podman:

```bash
podman info
```

### Step 3: Start the Valkey cluster

```bash
make up
```

This starts the six Valkey nodes.

Check running containers:

```bash
podman ps
```

Verify that all six Valkey containers are running and healthy:

- valkey-1
- valkey-2
- valkey-3
- valkey-4
- valkey-5
- valkey-6

### Step 4: Start BetterDB

After Valkey is running:

```bash
make betterdb-up
```

This starts:

- BetterDB monitoring service
- PostgreSQL storage service

Check service status:

```bash
make betterdb-status
```

PostgreSQL should report healthy, and BetterDB should be running.

---

## 5. Health verification

Perform these checks before running experiments.

### Step 5.1: Verify BetterDB connectivity

```bash
curl -fsS http://127.0.0.1:3001/api/health
```

Expected indicators:

- `"status":"connected"`
- Database type: `valkey`
- Valkey version: `9.1.2`
- `"clusterEnabled":true`

BetterDB should discover all six nodes: three masters and three replicas.

### Step 5.2: Verify the Valkey cluster

```bash
podman exec valkey-resilience-lab_valkey-1_1 \
  valkey-cli -h 127.0.0.1 -p 6379 CLUSTER INFO
```

Expected values:

```text
cluster_state:ok
cluster_slots_assigned:16384
cluster_slots_ok:16384
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:6
cluster_size:3
```

### Step 5.3: Verify replication

```bash
for port in 7001 7002 7003 7004 7005 7006; do
  echo "===== Valkey port $port ====="
  podman exec "valkey-resilience-lab_valkey-$((port - 7000))_1" \
    valkey-cli -h 127.0.0.1 -p 6379 INFO replication \
    | grep -E '^(role|master_host|master_link_status|master_repl_offset|slave_repl_offset|slave[0-9]+):'
done
```

Verify:

- Three nodes report `role:master`.
- Three nodes report `role:slave`.
- Primary nodes report their replicas as `state=online`.
- Replica nodes report `master_link_status:up`.

When the cluster is idle and replication has caught up, the primary and replica offsets should match.

### Step 5.4: Verify BetterDB Prometheus metrics

Check whether the metrics endpoint is responding:

```bash
curl -fsS http://127.0.0.1:3001/api/prometheus/metrics | head -40
```

Check replication offsets:

```bash
curl -fsS http://127.0.0.1:3001/api/prometheus/metrics \
  | grep '^betterdb_replication_offset{'
```

Check memory metrics:

```bash
curl -fsS http://127.0.0.1:3001/api/prometheus/metrics \
  | grep -E '^betterdb_memory_(used_bytes|used_rss_bytes|fragmentation_ratio){'
```

Metrics should be available for all six nodes.

**Note:** If `curl` displays `curl: (23) Failure writing output to destination` when piped to `head`, this can happen because `head` closes the pipe after reading the requested number of lines. It does not necessarily indicate a monitoring failure.

---

## 6. Startup acceptance checklist

Before starting an experiment, confirm the following:

- [ ] Podman machine is running.
- [ ] Six Valkey containers are running.
- [ ] All Valkey nodes are healthy.
- [ ] BetterDB container is running.
- [ ] PostgreSQL container is healthy.
- [ ] BetterDB dashboard opens.
- [ ] BetterDB health endpoint reports connected.
- [ ] Valkey cluster reports `cluster_state:ok`.
- [ ] All 16,384 slots are covered.
- [ ] Three replicas are online.
- [ ] BetterDB metrics endpoint responds.
- [ ] Replication metrics are available.

Once all checks pass, the environment is ready for experiments.

---

## 7. Capture an idle baseline

Capture a baseline before introducing workload or performing a resilience experiment.

Create the baseline directory:

```bash
mkdir -p artifacts/baseline
```

Capture cluster, replication, memory, and BetterDB metrics:

```bash
{
  echo "=== Timestamp ==="
  date

  echo
  echo "=== Cluster state ==="
  podman exec valkey-resilience-lab_valkey-1_1 \
    valkey-cli -h 127.0.0.1 -p 6379 CLUSTER INFO

  echo
  echo "=== Replication state ==="
  for port in 7001 7002 7003 7004 7005 7006; do
    echo "--- Port $port ---"
    podman exec "valkey-resilience-lab_valkey-$((port - 7000))_1" \
      valkey-cli -h 127.0.0.1 -p 6379 INFO replication
  done

  echo
  echo "=== BetterDB replication metrics ==="
  curl -fsS http://127.0.0.1:3001/api/prometheus/metrics \
    | grep '^betterdb_replication_offset{'

  echo
  echo "=== Memory metrics ==="
  curl -fsS http://127.0.0.1:3001/api/prometheus/metrics \
    | grep -E '^betterdb_memory_(used_bytes|used_rss_bytes|fragmentation_ratio){'
} | tee "artifacts/baseline/idle-baseline-$(date +%Y%m%d-%H%M%S).txt"
```

Keep baseline snapshots separate from experiment results.

Do not overwrite previous experiment evidence unless explicitly intended.

The initial validated baseline is also available at:

```text
artifacts/baseline/idle-baseline.txt
```

---

## 8. Accessing BetterDB

Open the dashboard:

http://localhost:3001

Useful endpoints:

| Purpose | Endpoint |
|---|---|
| Dashboard | `http://localhost:3001` |
| Health | `/api/health` |
| Prometheus metrics | `/api/prometheus/metrics` |

BetterDB is configured to monitor the Valkey cluster and persist its data in PostgreSQL.

---

## 9. Routine shutdown procedure

**Use this procedure when finishing a working session.**

The shutdown commands below stop containers without removing them or deleting their persistent volumes.

### Step 1: Stop BetterDB and PostgreSQL

```bash
make betterdb-down
```

Verified Makefile implementation:

```makefile
betterdb-down:
	podman compose -f docker-compose.yml -f docker-compose.betterdb.yml --profile betterdb stop betterdb betterdb-postgres
```

This uses `stop`, not `down -v`.

### Step 2: Stop all six Valkey nodes

```bash
podman compose stop valkey-1 valkey-2 valkey-3 valkey-4 valkey-5 valkey-6
```

This stops the six services without deleting their containers or volumes.

### Step 3: Verify that containers have stopped

```bash
podman ps
```

Expected: no Valkey or BetterDB containers in the running list.

Check that the containers still exist:

```bash
podman ps -a --format "table {{.Names}}\t{{.Status}}"
```

The eight containers should remain listed with an exited/stopped status.

### Step 4: Verify persistent volumes

```bash
podman volume ls
```

Confirm that the BetterDB PostgreSQL volume remains:

```text
valkey-resilience-lab-betterdb-pgdata
```

Also verify that the six Valkey data volumes remain present.

**Important:** Podman Compose may display project-prefixed volume names. Verify the actual names rather than assuming a particular prefix.

---

## 10. Commands to avoid during routine operation

The following operations are not part of normal startup or shutdown.

### Do not run:

```bash
make reset
```

The reset script runs:

```bash
podman compose ... down -v --remove-orphans
```

This can delete Compose-managed volumes and persistent Valkey data.

Also avoid:

```bash
podman compose down -v
podman volume rm ...
podman system prune --volumes
```

These commands can remove data required for future experiments.

Only use destructive cleanup when you explicitly intend to reset the environment and have preserved any results you need.

---

## 11. When is a rebuild required?

Routine startup does not require rebuilding images.

| Situation | Action |
|---|---|
| Starting a new session | `make up`, then `make betterdb-up` |
| Restarting stopped containers | Same startup sequence |
| Changing load-generator Go code | `make build` |
| Changing Compose configuration | `make check` |
| Changing BetterDB configuration | Review configuration and restart relevant services |
| Intentionally resetting experiment state | Follow a separate reset procedure after preserving results |

---

## 12. Quick reference

### Routine startup

```bash
cd /path/to/valkey-resilience-lab

podman machine start

make up

make betterdb-up

make betterdb-status

curl -fsS http://127.0.0.1:3001/api/health
```

Open:

http://localhost:3001

### Routine shutdown

```bash
make betterdb-down

podman compose stop valkey-1 valkey-2 valkey-3 valkey-4 valkey-5 valkey-6
```

### Quick health check

```bash
podman ps

podman exec valkey-resilience-lab_valkey-1_1 \
  valkey-cli -h 127.0.0.1 -p 6379 CLUSTER INFO

curl -fsS http://127.0.0.1:3001/api/health
```

---

## 13. Operational guidelines

1. Do not rebuild images during routine startup.
2. Do not delete volumes during routine shutdown.
3. Verify cluster health before running experiments.
4. Capture an idle baseline before introducing workload.
5. Keep experiment output and baseline snapshots.
6. Compare BetterDB telemetry with native Valkey metrics.
7. Keep environment startup, experiment execution, and destructive reset as separate procedures.

**Golden rule:** Start the existing environment, verify it, run your experiment, and stop it safely. Do not recreate or reset the cluster just to start another working session.
