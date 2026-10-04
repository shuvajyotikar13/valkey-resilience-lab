#!/usr/bin/env python3
"""Compare no-retry, immediate-retry, and jittered failover runs."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import statistics
from datetime import datetime
from pathlib import Path
from typing import Any


def rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def load_env(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                result[key] = value
    return result


def number(row: dict[str, str], key: str) -> float:
    try:
        return float(row.get(key, "0") or 0)
    except ValueError:
        return 0.0


def timestamp_epoch(value: str) -> float:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return 0.0


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * quantile + 0.999999) - 1))
    return ordered[index]


def sha256(path: Path) -> str:
    if not path.exists():
        return "missing"
    return hashlib.sha256(path.read_bytes()).hexdigest()


def slot_count(token: str) -> int:
    if token.startswith("["):
        return 0
    try:
        if "-" in token:
            first, last = token.split("-", 1)
            return int(last) - int(first) + 1
        int(token)
        return 1
    except ValueError:
        return 0


def slot_distribution(path: Path) -> list[int]:
    result: list[int] = []
    if not path.exists():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) < 8:
            continue
        flags = fields[2].split(",")
        if "master" in flags and "fail" not in flags:
            result.append(sum(slot_count(token) for token in fields[8:]))
    return sorted(result)


def event_epochs(events: list[dict[str, str]]) -> dict[str, float]:
    return {row.get("event", ""): number(row, "epoch_s") for row in events}


def timestamp_window(data: list[dict[str, str]], start: float, end: float) -> list[dict[str, str]]:
    return [row for row in data if start <= timestamp_epoch(row.get("timestamp", "")) <= end]


def counter_delta(server: list[dict[str, str]], key: str, start: float, end: float) -> float:
    grouped: dict[str, list[float]] = {}
    for row in server:
        when = number(row, "epoch_s")
        if start <= when <= end:
            grouped.setdefault(row.get("node", "unknown"), []).append(number(row, key))
    return sum(max(values) - min(values) for values in grouped.values() if values)


def stable_time(
    workload: list[dict[str, str]],
    search_from: float,
    logical_floor: float,
    p99_ceiling: float,
    error_ceiling: float,
) -> float | None:
    consecutive = 0
    first = 0.0
    for row in sorted(workload, key=lambda item: timestamp_epoch(item.get("timestamp", ""))):
        when = timestamp_epoch(row.get("timestamp", ""))
        if when < search_from:
            continue
        healthy = (
            number(row, "logical_ops_s") >= logical_floor
            and number(row, "latency_p99_ms") <= p99_ceiling
            and number(row, "error_rate") <= error_ceiling
        )
        if healthy:
            if consecutive == 0:
                first = when
            consecutive += 1
            if consecutive >= 5:
                return first
        else:
            consecutive = 0
    return None


def analyze(run_dir: Path) -> dict[str, Any]:
    summary = load_json(run_dir / "summary.json")
    workload = rows(run_dir / "workload.csv")
    server = rows(run_dir / "server.csv")
    events = rows(run_dir / "events.csv")
    times = event_epochs(events)
    t0 = times.get("primary_stopped", 0.0)
    td = times.get("failure_detected", 0.0)
    t1 = times.get("replica_promoted", 0.0)
    restarted = times.get("old_primary_restarted", 0.0)

    pre = timestamp_window(workload, t0 - 15, t0 - 1)
    pre_logical = [number(row, "logical_ops_s") for row in pre]
    pre_p99 = [number(row, "latency_p99_ms") for row in pre]
    pre_errors = [number(row, "error_rate") for row in pre]
    baseline_logical = statistics.median(pre_logical) if pre_logical else 0.0
    baseline_p99 = statistics.median(pre_p99) if pre_p99 else 0.0
    logical_floor = baseline_logical * 0.95
    p99_ceiling = max(percentile(pre_p99, 0.95), baseline_p99 * 1.5, baseline_p99 + 1)
    error_ceiling = max(percentile(pre_errors, 0.95), 0.0001)
    search_from = t1 or t0
    t2 = stable_time(workload, search_from, logical_floor, p99_ceiling, error_ceiling)
    last_workload_epoch = max((timestamp_epoch(row.get("timestamp", "")) for row in workload), default=t0)
    window_end = t2 if t2 is not None else last_workload_epoch
    recovery = timestamp_window(workload, t0, window_end)
    totals = summary.get("totals", {})

    return {
        "dir": run_dir,
        "env": load_env(run_dir / "environment.txt"),
        "config": summary.get("configuration", {}),
        "totals": totals,
        "compose_hash": sha256(run_dir / "compose-resolved.yml"),
        "slots": slot_distribution(run_dir / "cluster-nodes-before.txt"),
        "t0": t0,
        "td": td,
        "t1": t1,
        "t2": t2,
        "restart": restarted,
        "baseline_logical": baseline_logical,
        "baseline_p99": baseline_p99,
        "logical_floor": logical_floor,
        "p99_ceiling": p99_ceiling,
        "min_logical": min((number(row, "logical_ops_s") for row in recovery), default=0.0),
        "peak_physical": max((number(row, "physical_attempts_s") for row in recovery), default=0.0),
        "peak_amp": max((number(row, "attempt_amplification") for row in recovery), default=0.0),
        "peak_dials": max((number(row, "connection_attempts_s") for row in recovery), default=0.0),
        "errors": sum(number(row, "errors_s") for row in recovery),
        "peak_error": max((number(row, "error_rate") for row in recovery), default=0.0),
        "peak_p99": max((number(row, "latency_p99_ms") for row in recovery), default=0.0),
        "peak_p999": max((number(row, "latency_p999_ms") for row in recovery), default=0.0),
        "new_connections": counter_delta(server, "total_connections_received", t0, window_end),
    }


def seconds_between(first: float | None, second: float | None) -> str:
    if not first or not second:
        return "not observed"
    return f"{max(0.0, second - first):.1f} s"


def common_config(configuration: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in configuration.items() if key not in {"retry_policy", "max_attempts"}}


def print_report(runs: list[dict[str, Any]]) -> None:
    labels = ["F1 no retries", "F2 immediate", "F3 jitter"]
    env_keys = (
        "target_rps",
        "workers",
        "preload_keys",
        "value_sizes",
        "warmup_seconds",
        "fault_seconds",
        "recovery_seconds",
    )
    same_common_config = len({json.dumps(common_config(run["config"]), sort_keys=True) for run in runs}) == 1
    same_env = all(
        len({run["env"].get(key, "") for run in runs}) == 1
        for key in env_keys
    )
    same_compose = len({run["compose_hash"] for run in runs}) == 1
    same_slots = len({tuple(run["slots"]) for run in runs}) == 1 and bool(runs[0]["slots"])
    f2_f3_budget = runs[1]["config"].get("max_attempts") == runs[2]["config"].get("max_attempts")

    print("# Failover recovery comparison")
    print()
    print("## Controlled-comparison checks")
    print()
    print("| Check | Result |")
    print("|---|---|")
    for name, passed in (
        ("Same non-retry workload configuration", same_common_config),
        ("Same recorded environment", same_env),
        ("Same resolved Compose configuration", same_compose),
        ("Same starting slot distribution", same_slots),
        ("F2 and F3 use the same maximum-attempt budget", f2_f3_budget),
    ):
        print(f"| {name} | {'PASS' if passed else 'FAIL'} |")

    print()
    print("## Recovery milestones")
    print()
    print("| Metric | " + " | ".join(labels) + " |")
    print("|---|" + "---:|" * len(labels))
    milestone_rows = (
        ("T0 → failure declared", lambda run: seconds_between(run["t0"], run["td"])),
        ("T0 → replica promoted", lambda run: seconds_between(run["t0"], run["t1"])),
        ("T1 → application stable", lambda run: seconds_between(run["t1"], run["t2"])),
        ("T0 → application stable", lambda run: seconds_between(run["t0"], run["t2"])),
        ("T0 → old primary restarted", lambda run: seconds_between(run["t0"], run["restart"])),
    )
    for label, formatter in milestone_rows:
        print(f"| {label} | " + " | ".join(formatter(run) for run in runs) + " |")

    print()
    print("## Client and server impact through application stability")
    print()
    print("| Metric | " + " | ".join(labels) + " |")
    print("|---|" + "---:|" * len(labels))
    metrics = (
        ("Pre-fault median logical ops/s", "baseline_logical", "{:,.0f}"),
        ("Minimum logical ops/s", "min_logical", "{:,.0f}"),
        ("Peak physical attempts/s", "peak_physical", "{:,.0f}"),
        ("Peak attempt amplification", "peak_amp", "{:.3f}x"),
        ("Peak load-generator TCP dials/s", "peak_dials", "{:,.0f}"),
        ("New server connections", "new_connections", "{:,.0f}"),
        ("Errors", "errors", "{:,.0f}"),
        ("Peak error rate", "peak_error", "{:.4%}"),
        ("Pre-fault median p99", "baseline_p99", "{:.2f} ms"),
        ("Peak p99", "peak_p99", "{:.2f} ms"),
        ("Peak p99.9", "peak_p999", "{:.2f} ms"),
    )
    for label, key, fmt in metrics:
        print(f"| {label} | " + " | ".join(fmt.format(run[key]) for run in runs) + " |")

    print()
    print("## Whole-run totals")
    print()
    print("| Metric | " + " | ".join(labels) + " |")
    print("|---|" + "---:|" * len(labels))
    total_metrics = (
        ("Logical operations", "logical_operations", "{:,.0f}"),
        ("Physical attempts", "physical_attempts", "{:,.0f}"),
        ("Attempt amplification", "attempt_amplification", "{:.4f}x"),
        ("Load-generator TCP dials", "connection_attempts", "{:,.0f}"),
        ("Errors", "errors", "{:,.0f}"),
        ("Dropped offered-load tokens", "dropped_offered_tokens", "{:,.0f}"),
    )
    for label, key, fmt in total_metrics:
        print(
            f"| {label} | "
            + " | ".join(fmt.format(float(run["totals"].get(key, 0))) for run in runs)
            + " |"
        )

    print()
    print("Application stable means five consecutive one-second samples with logical rate ≥95% of the pre-fault median, p99 inside the pre-fault band, and error rate ≤0.01% or the pre-fault upper band.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("f1", type=Path, help="results/...-failover-none")
    parser.add_argument("f2", type=Path, help="results/...-failover-immediate")
    parser.add_argument("f3", type=Path, help="results/...-failover-jitter")
    args = parser.parse_args()
    print_report([analyze(args.f1), analyze(args.f2), analyze(args.f3)])


if __name__ == "__main__":
    main()
