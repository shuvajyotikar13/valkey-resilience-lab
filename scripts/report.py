#!/usr/bin/env python3
"""Create a compact Markdown report and optional PNG from one scenario directory."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any


def rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def number(row: dict[str, str], key: str) -> float:
    try:
        return float(row.get(key, "0") or 0)
    except ValueError:
        return 0.0


def peak(data: list[dict[str, str]], key: str) -> float:
    return max((number(row, key) for row in data), default=0.0)


def median(data: list[dict[str, str]], key: str) -> float:
    values = [number(row, key) for row in data if number(row, key) > 0]
    return statistics.median(values) if values else 0.0


def counter_delta(data: list[dict[str, str]], key: str, group: str = "node") -> float:
    grouped: dict[str, list[float]] = defaultdict(list)
    for row in data:
        grouped[row.get(group, "unknown")].append(number(row, key))
    return sum(max(values) - min(values) for values in grouped.values() if values)


def replication_rates(data: list[dict[str, str]]) -> dict[str, float]:
    """Estimate median replication-stream bytes/s for each observed primary."""
    grouped: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for row in data:
        if row.get("role") != "master":
            continue
        epoch = number(row, "epoch_s")
        offset = number(row, "master_repl_offset")
        if epoch > 0 and offset >= 0:
            grouped[row.get("node", "unknown")].append((epoch, offset))

    out: dict[str, float] = {}
    for node, samples in grouped.items():
        samples.sort()
        rates = []
        for (previous_time, previous_offset), (current_time, current_offset) in zip(samples, samples[1:]):
            elapsed = current_time - previous_time
            delta = current_offset - previous_offset
            if elapsed > 0 and delta >= 0:
                rates.append(delta / elapsed)
        if rates:
            out[node] = statistics.median(rates)
    return out


def backlog_coverage_seconds(data: list[dict[str, str]], rates: dict[str, float]) -> float:
    coverages = []
    for node, rate in rates.items():
        if rate <= 0:
            continue
        sizes = [number(row, "repl_backlog_size") for row in data if row.get("node") == node]
        sizes = [size for size in sizes if size > 0]
        if sizes:
            coverages.append(statistics.median(sizes) / rate)
    return min(coverages) if coverages else 0.0


def mib(value: float) -> str:
    return f"{value / 1024 / 1024:.1f} MiB"


def load_environment(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            out[key] = value
    return out


def build_report(run_dir: Path, args: argparse.Namespace) -> str:
    workload = rows(run_dir / "workload.csv")
    server = rows(run_dir / "server.csv")
    links = rows(run_dir / "replication-links.csv")
    events = rows(run_dir / "events.csv")
    env = load_environment(run_dir / "environment.txt")
    summary: dict[str, Any] = {}
    if (run_dir / "summary.json").exists():
        summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))

    p99_peak = peak(workload, "latency_p99_ms")
    p999_peak = peak(workload, "latency_p999_ms")
    error_peak = peak(workload, "error_rate")
    amp_peak = peak(workload, "attempt_amplification")
    median_ops = median(workload, "logical_ops_s")
    peak_gap = peak(links, "gap_bytes")
    peak_rss = peak(server, "used_memory_rss")
    peak_used = peak(server, "used_memory")
    peak_cow = peak(server, "current_cow_peak")
    peak_not_counted = peak(server, "mem_not_counted_for_evict")
    rates = replication_rates(server)
    median_replication_bps = statistics.median(rates.values()) if rates else 0.0
    minimum_backlog_coverage = backlog_coverage_seconds(server, rates)
    totals = summary.get("totals", {})

    gates: list[tuple[str, bool, str]] = []
    if args.slo_p99_ms is not None:
        gates.append(("Peak p99", p99_peak <= args.slo_p99_ms, f"{p99_peak:.2f} ms ≤ {args.slo_p99_ms:.2f} ms"))
    if args.slo_error_rate is not None:
        gates.append(("Peak error rate", error_peak <= args.slo_error_rate, f"{error_peak:.4%} ≤ {args.slo_error_rate:.4%}"))
    if args.max_amplification is not None:
        gates.append(("Attempt amplification", amp_peak <= args.max_amplification, f"{amp_peak:.3f}× ≤ {args.max_amplification:.3f}×"))

    lines = [
        f"# Valkey resilience run: {env.get('scenario', run_dir.name)}",
        "",
        "> This report describes an observed run. It is not a product-wide performance claim; retain the hardware, version, configuration, workload, and repetition count with every published chart.",
        "",
        "## Run configuration",
        "",
        "| Item | Value |",
        "|---|---:|",
        f"| Scenario | {env.get('scenario', 'unknown')} |",
        f"| Target RPS | {env.get('target_rps', summary.get('configuration', {}).get('offered_rps', 'unknown'))} |",
        f"| Workers | {env.get('workers', summary.get('configuration', {}).get('workers', 'unknown'))} |",
        f"| Preloaded keys | {env.get('preload_keys', 'unknown')} |",
        f"| Value-size distribution | {env.get('value_sizes', 'unknown')} |",
        f"| Primary under test | {env.get('primary_under_test', 'n/a')} |",
        f"| Replica under test | {env.get('replica_under_test', 'n/a')} |",
        "",
        "## Key observations",
        "",
        "| Signal | Observed value |",
        "|---|---:|",
        f"| Median achieved logical ops/s | {median_ops:,.0f} |",
        f"| Peak sampled p99 | {p99_peak:.2f} ms |",
        f"| Peak sampled p99.9 | {p999_peak:.2f} ms |",
        f"| Peak per-second error rate | {error_peak:.4%} |",
        f"| Peak physical-attempt amplification | {amp_peak:.3f}× |",
        f"| Peak replication offset gap | {peak_gap:,.0f} bytes |",
        f"| Estimated median per-primary replication stream | {mib(median_replication_bps)}/s |",
        f"| Estimated minimum backlog coverage | {minimum_backlog_coverage:.1f} s |",
        f"| Full sync counter delta | {counter_delta(server, 'sync_full'):,.0f} |",
        f"| Partial sync success counter delta | {counter_delta(server, 'sync_partial_ok'):,.0f} |",
        f"| Peak per-node used memory | {mib(peak_used)} |",
        f"| Peak per-node RSS | {mib(peak_rss)} |",
        f"| Peak per-node copy-on-write | {mib(peak_cow)} |",
        f"| Peak per-node non-evictable memory | {mib(peak_not_counted)} |",
        f"| Evicted keys counter delta | {counter_delta(server, 'evicted_keys'):,.0f} |",
        f"| New server connections counter delta | {counter_delta(server, 'total_connections_received'):,.0f} |",
        f"| Load-generator TCP dials | {float(totals.get('connection_attempts', 0)):,.0f} |",
        f"| Dropped offered-load tokens | {float(totals.get('dropped_offered_tokens', 0)):,.0f} |",
        "",
    ]

    if gates:
        lines.extend(["## User-supplied acceptance gates", "", "| Gate | Result | Evidence |", "|---|---|---:|"])
        for name, passed, evidence in gates:
            lines.append(f"| {name} | {'PASS' if passed else 'FAIL'} | {evidence} |")
        lines.append("")

    if events:
        lines.extend(["## Event timeline", "", "| Timestamp | Event | Details |", "|---|---|---|"])
        for event in events:
            lines.append(f"| {event.get('timestamp', '')} | {event.get('event', '')} | {event.get('details', '')} |")
        lines.append("")

    lines.extend(
        [
            "## Interpretation checklist",
            "",
            "- Did the offered rate remain stable while replication gap or memory pressure grew?",
            "- Did the replica recover with partial synchronization or cross into a full synchronization?",
            "- Did p99/error rate return to the pre-fault band, and how long did that take?",
            "- Did physical attempts grow faster than logical operations during failover?",
            "- Which resource peaked first: network, replication buffer, RSS, connections, or CPU?",
            "",
        ]
    )
    if (run_dir / "overview.png").exists():
        lines.extend(["![Run overview](overview.png)", ""])
    return "\n".join(lines)


def event_positions(events: list[dict[str, str]], epoch0: float) -> list[tuple[float, str]]:
    out = []
    for event in events:
        try:
            out.append((float(event["epoch_s"]) - epoch0, event.get("event", "event")))
        except (KeyError, ValueError):
            pass
    return out


def create_plot(run_dir: Path) -> bool:
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        return False

    workload = rows(run_dir / "workload.csv")
    server = rows(run_dir / "server.csv")
    links = rows(run_dir / "replication-links.csv")
    events = rows(run_dir / "events.csv")
    epochs = [number(r, "epoch_s") for r in server] + [number(r, "epoch_s") for r in links]
    if workload:
        epochs += [number(r, "elapsed_s") for r in workload]
    if not epochs:
        return False
    absolute_epochs = [e for e in [number(r, "epoch_s") for r in server] if e > 0]
    epoch0 = min(absolute_epochs) if absolute_epochs else 0

    fig, axes = plt.subplots(4, 1, figsize=(13, 11), sharex=True, constrained_layout=True)
    wx = [number(r, "elapsed_s") for r in workload]
    axes[0].plot(wx, [number(r, "logical_ops_s") for r in workload], label="logical ops/s", color="#2563eb")
    axes[0].plot(wx, [number(r, "physical_attempts_s") for r in workload], label="physical attempts/s", color="#f97316")
    axes[0].set_ylabel("operations/s")
    axes[0].legend(loc="upper right")

    axes[1].plot(wx, [number(r, "latency_p99_ms") for r in workload], label="p99", color="#dc2626")
    axes[1].plot(wx, [number(r, "latency_p999_ms") for r in workload], label="p99.9", color="#7c3aed", alpha=0.8)
    axes[1].set_ylabel("latency ms")
    axes[1].legend(loc="upper right")

    link_by_epoch: dict[float, float] = defaultdict(float)
    for row in links:
        t = number(row, "epoch_s") - epoch0
        link_by_epoch[t] = max(link_by_epoch[t], number(row, "gap_bytes") / 1024 / 1024)
    axes[2].plot(sorted(link_by_epoch), [link_by_epoch[t] for t in sorted(link_by_epoch)], label="max replication gap", color="#0891b2")
    axes[2].set_ylabel("gap MiB")
    axes[2].legend(loc="upper right")

    rss_by_epoch: dict[float, float] = defaultdict(float)
    used_by_epoch: dict[float, float] = defaultdict(float)
    cow_by_epoch: dict[float, float] = defaultdict(float)
    for row in server:
        t = number(row, "epoch_s") - epoch0
        rss_by_epoch[t] = max(rss_by_epoch[t], number(row, "used_memory_rss") / 1024 / 1024)
        used_by_epoch[t] = max(used_by_epoch[t], number(row, "used_memory") / 1024 / 1024)
        cow_by_epoch[t] = max(cow_by_epoch[t], number(row, "current_cow_peak") / 1024 / 1024)
    xs = sorted(rss_by_epoch)
    axes[3].plot(xs, [rss_by_epoch[t] for t in xs], label="RSS", color="#111827")
    axes[3].plot(xs, [used_by_epoch[t] for t in xs], label="used_memory", color="#16a34a")
    axes[3].plot(xs, [cow_by_epoch[t] for t in xs], label="COW peak", color="#db2777")
    axes[3].set_ylabel("per-node max MiB")
    axes[3].set_xlabel("seconds from collection start")
    axes[3].legend(loc="upper right")

    for ax in axes:
        ax.grid(True, alpha=0.2)
        for position, label in event_positions(events, epoch0):
            ax.axvline(position, color="#6b7280", linewidth=0.8, alpha=0.45)
        ax.spines[["top", "right"]].set_visible(False)

    fig.suptitle(run_dir.name)
    fig.savefig(run_dir / "overview.png", dpi=160)
    plt.close(fig)
    return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--slo-p99-ms", type=float)
    parser.add_argument("--slo-error-rate", type=float, help="fraction, e.g. 0.001 for 0.1%%")
    parser.add_argument("--max-amplification", type=float)
    args = parser.parse_args()
    args.run_dir.mkdir(parents=True, exist_ok=True)
    create_plot(args.run_dir)
    report = build_report(args.run_dir, args)
    (args.run_dir / "report.md").write_text(report + "\n", encoding="utf-8")
    print(args.run_dir / "report.md")


if __name__ == "__main__":
    main()
