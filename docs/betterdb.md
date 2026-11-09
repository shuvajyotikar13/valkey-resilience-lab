# BetterDB observability for the Valkey resilience lab

This is an **optional** monitoring stack for the existing six-node Valkey 9.1.2 lab. It does not replace the lab's one-second CSV collector. BetterDB adds historical slowlog / COMMANDLOG analysis, per-node views and cluster topology; PostgreSQL keeps these observations across container restarts and `make reset`.

## Start

From the repository root:

```bash
make init
make up
make betterdb-up
make betterdb-status
```

Open <http://localhost:3001>. BetterDB uses `valkey-1:6379` as its cluster seed and `CLUSTER_AUTO_REGISTER_NODES=true` to discover the other primaries and replicas, typically within a 30-second sync cycle. Open **Manage Connections** to confirm all six nodes appear; they are reached through their cluster-advertised container IP addresses. The monitor must join the `bench` network; `localhost:7001` is not a valid container-to-container address.

The optional Compose overlay runs:

- `betterdb/monitor:latest` (override with `BETTERDB_IMAGE` in `.env`; pin the version/digest for repeatable results)
- `postgres:16-alpine` holding audit/slowlog history in the external named volume `valkey-resilience-lab-betterdb-pgdata`

**Why PostgreSQL?** The BetterDB `latest` Docker image does not include the SQLite native module; `STORAGE_TYPE=memory` loses data when the monitor restarts.

## Run a monitored experiment

Set `BETTERDB_ENABLED=1` in `.env` and start with low-risk cases:

```bash
RESET_BEFORE_RUN=1 BASELINE_SECONDS=180 make baseline
RESET_BEFORE_RUN=1 PARTIAL_OUTAGE_SECONDS=5 make replica-partial
RESET_BEFORE_RUN=1 FULL_OUTAGE_SECONDS=30 FULL_SYNC_BACKLOG=1mb make replica-full
RESET_BEFORE_RUN=1 make failover-jitter
```

`run-scenario.sh` automatically starts BetterDB again after it resets the six Valkey nodes. The monitor can be briefly offline during the reset; the PostgreSQL history survives. Use the dashboard **Replication**, **Memory**, **Slow Log**, **COMMANDLOG**, **Cluster** and **Clients** views during experiments. The lab's `events.csv`, `server.csv`, `replication-links.csv`, `workload.csv` and `report.md` remain the authoritative timing/performance artifacts. BetterDB's sync and polling may be coarser than the lab's one-second collector.

For an envelope run (`make envelope`) or manual commands, call `make betterdb-up` first. The `BETTERDB_ENABLED` setting applies to `run-scenario.sh`, not all scripts.

Check API and Prometheus exposition:

```bash
curl -fsS http://localhost:3001/api/health
curl -fsS http://localhost:3001/api/prometheus/metrics | head -n 20
```

The advertised Prometheus endpoint is `/api/prometheus/metrics` for production Docker builds. Expect `betterdb_*` series. Prometheus collection is optional; the lab does not install Prometheus or Grafana.

## Experiment checklist

| Scenario | Useful BetterDB evidence | What to verify in the lab's raw CSV |
|---|---|---|
| Baseline | Memory, cluster overview, clients, slow commands | Stable offset gap and p99 |
| Replica brief outage | Replica disconnect / reconnect, replication state | Partial-sync counters and catch-up time |
| Replica long outage | Replication / network pressure | Full-sync increment and backlog coverage |
| Primary failover | Node roles, topology, connection state | Promotion, error budget, retry amplification |
| BGSAVE | Memory and persistence metrics | RSS/COW peak, fork duration |
| Reshard | Cluster nodes, slot distribution, hot slots | Latency and replication during migration |

For publication-grade comparisons, run **monitor off** and **monitor on** control experiments at the same offered rate to measure BetterDB observer overhead. Record the BetterDB image digest/version, polling settings, topology, and data retention. Do not use `MONITOR` capture during latency/throughput experiments: that instrumentation is more intrusive than normal polling.

## Safety, reset and storage

This is a laptop lab, **not a production deployment**. The underlying Valkey cluster has `protected-mode no` with no password, and this integration uses BetterDB's `WORKSPACE_DISABLED=true` for easy local access. The dashboard is published only on `127.0.0.1:3001`, PostgreSQL is **not** published to the host, and anonymous BetterDB telemetry is disabled. Do not expose the dashboard or bridge network to untrusted users. For a shared lab, configure authenticated BetterDB users, a dedicated read-only Valkey ACL on **every node**, unique database credentials and TLS.

`make reset` deletes the lab's containers and Valkey volumes but **does not** delete the external BetterDB PostgreSQL volume. The monitor containers are recreated by `make betterdb-up` (or automatically by `BETTERDB_ENABLED=1` for scenarios). To stop the monitor without deleting history:

```bash
make betterdb-down
```

If you deliberately want to erase the BetterDB history, first run `make betterdb-down`, then `make reset` (to remove project containers using the volume), and only then:

```bash
podman volume rm valkey-resilience-lab-betterdb-pgdata
```

### Troubleshooting

- **Only one node visible** — wait at least 30 seconds, check **Manage Connections** auto-registration, and verify that BetterDB can reach the container IPs returned by `CLUSTER NODES` on the shared Compose `bench` network.
- **Monitor won't start** — run `podman compose -f docker-compose.yml -f docker-compose.betterdb.yml --profile betterdb logs --tail=100 betterdb betterdb-postgres`. Check for port 3001 collisions and PostgreSQL credentials. Use only URL-safe alphanumeric characters in `BETTERDB_PG_PASSWORD` (the value is embedded in a PostgreSQL URL). Once initialized, changing `BETTERDB_PG_PASSWORD` requires updating the existing PostgreSQL role or creating a new database volume; changing the env var alone is not a rotation.
- **Prometheus endpoint returns nothing** — check dashboard connection selection and the monitor's logs; BetterDB metric names use the `betterdb_` prefix.
- **Slowlog/COMMANDLOG not useful** — Valkey only logs commands that meet its thresholds. Confirm Valkey's thresholds and inject workloads appropriate to the experiment rather than assuming all commands must appear.

Official references: [BetterDB Docker installation](https://docs.betterdb.com/install/), [cluster auto-registration](https://github.com/BetterDB-inc/monitor/blob/master/docs/cluster-auto-registration.md), [minimum ACL](https://github.com/BetterDB-inc/monitor/blob/master/docs/minimum-acl.md), and [Prometheus metrics](https://www.betterdb.com/valkey-prometheus-monitoring).
