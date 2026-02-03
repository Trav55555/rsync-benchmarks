#!/usr/bin/env python3
"""Analyze benchmark results and produce blog-ready tables."""

import json
import sys
import os
from pathlib import Path
from collections import defaultdict


def load_stats(results_dir: str) -> list[dict]:
    rd = Path(results_dir)
    if not rd.exists():
        print(f"Error: {results_dir} not found")
        sys.exit(1)

    stats = []
    for f in sorted(rd.glob("*_stats.json")):
        if "iperf3" in f.name:
            continue
        try:
            stats.append(json.load(open(f)))
        except Exception as e:
            print(f"Warning: {f}: {e}")

    return stats


def load_iperf(results_dir: str) -> dict | None:
    f = Path(results_dir) / "iperf3_stats.json"
    if f.exists():
        return json.load(open(f))
    return None


def load_system_info(results_dir: str) -> dict | None:
    f = Path(results_dir) / "system_info.json"
    if f.exists():
        return json.load(open(f))
    return None


def fmt_bytes(b: int) -> str:
    if b < 1024**2:
        return f"{b / 1024:.0f} KB"
    if b < 1024**3:
        return f"{b / 1024**2:.0f} MB"
    return f"{b / 1024**3:.1f} GB"


def fmt_tp(mbps: float) -> str:
    if mbps >= 1000:
        return f"{mbps / 1000:.2f} Gbps"
    return f"{mbps:.1f} Mbps"


def print_terminal_table(stats: list[dict], iperf: dict | None):
    print("\n" + "=" * 95)
    print("BENCHMARK RESULTS")
    print("=" * 95)

    if iperf:
        print(f"Network ceiling: {iperf['median_mbps']:.0f} Mbps")

    profiles = defaultdict(list)
    for s in stats:
        profiles[s.get("data_profile", "unknown")].append(s)

    for profile, entries in profiles.items():
        src_bytes = entries[0].get("src_bytes", 0)
        print(f"\n--- {profile} ({fmt_bytes(src_bytes)}) ---")
        print(
            f"{'Benchmark':<35} {'Median':>8} {'StdDev':>8} {'CV%':>6} {'Throughput':>14} {'Runs':>5} {'OK':>4}"
        )
        print("-" * 95)

        for s in sorted(entries, key=lambda x: x["duration_s"]["median"]):
            d = s["duration_s"]
            tp = s["effective_throughput_mbps"]
            v = "yes" if s["all_verified"] else "NO"
            n = f"{s['valid_runs']}/{s['total_runs']}"
            streams = f" ({s['streams']}x)" if "streams" in s else ""
            name = s["benchmark"] + streams

            print(
                f"{name:<35} {d['median']:>7.3f}s {d['stdev']:>7.3f}s {d['cv_pct']:>5.1f}% "
                f"{tp['median']:>10.2f} Mbps {n:>5} {v:>4}"
            )


def print_markdown_table(stats: list[dict], iperf: dict | None, sys_info: dict | None):
    print("\n\n## Benchmark Results\n")

    if sys_info:
        print("**Environment:**")
        print(
            f"- Instance: c6i.2xlarge ({sys_info.get('cpu_cores', '?')} vCPU, {sys_info.get('memory_gb', '?')} GB RAM)"
        )
        print(
            f"- Network: Same-AZ, {iperf['median_mbps']:.0f} Mbps ceiling"
            if iperf
            else "- Network: Same-AZ"
        )
        print(f"- Filesystem: {sys_info.get('filesystem', '?')}")
        print(f"- rsync: {sys_info.get('rsync_version', '?')}")
        print()

    profiles = defaultdict(list)
    for s in stats:
        profiles[s.get("data_profile", "unknown")].append(s)

    tool_labels = {
        "rsync_default": "`rsync -a`",
        "rsync_compress": "`rsync -az`",
        "tar_ssh": "`tar | ssh`",
        "tar_zstd_ssh": "`tar | zstd | ssh`",
    }

    for profile, entries in profiles.items():
        src_bytes = entries[0].get("src_bytes", 0)
        parallel_entries = [e for e in entries if "streams" in e]
        single_entries = [e for e in entries if "streams" not in e]

        print(f"### {profile} ({fmt_bytes(src_bytes)})\n")
        print("| Tool | Median | Throughput | CV% | vs fastest |")
        print("|------|-------:|----------:|----:|-----------:|")

        sorted_single = sorted(single_entries, key=lambda x: x["duration_s"]["median"])
        fastest = sorted_single[0]["duration_s"]["median"] if sorted_single else 1

        for s in sorted_single:
            d = s["duration_s"]
            tp = s["effective_throughput_mbps"]
            short_name = s["benchmark"].replace(f"{profile}_", "")
            label = tool_labels.get(short_name, f"`{short_name}`")
            ratio = d["median"] / fastest if fastest > 0 else 1
            vs = "**fastest**" if ratio < 1.01 else f"{ratio:.2f}x slower"

            print(
                f"| {label} | {d['median']:.3f}s | {fmt_tp(tp['median'])} | {d['cv_pct']:.1f}% | {vs} |"
            )

        if parallel_entries:
            print(f"\n**Parallel rsync scaling ({profile}):**\n")
            print("| Streams | Median | Throughput | vs single |")
            print("|--------:|-------:|----------:|----------:|")

            rsync_single = next(
                (e for e in single_entries if "rsync_default" in e["benchmark"]), None
            )
            baseline_med = (
                rsync_single["duration_s"]["median"] if rsync_single else None
            )

            for s in sorted(parallel_entries, key=lambda x: x.get("streams", 0)):
                d = s["duration_s"]
                tp = s["effective_throughput_mbps"]
                streams = s.get("streams", "?")
                if baseline_med and baseline_med > 0:
                    speedup = f"{baseline_med / d['median']:.2f}x"
                else:
                    speedup = "-"
                print(
                    f"| {streams} | {d['median']:.3f}s | {fmt_tp(tp['median'])} | {speedup} |"
                )

        print()


def export_json_summary(stats: list[dict], iperf: dict | None, output_path: str):
    summary = {
        "network_ceiling_mbps": iperf["median_mbps"] if iperf else None,
        "benchmarks": [],
    }

    for s in sorted(
        stats, key=lambda x: (x.get("data_profile", ""), x["duration_s"]["median"])
    ):
        summary["benchmarks"].append(
            {
                "name": s["benchmark"],
                "profile": s.get("data_profile", "unknown"),
                "median_s": s["duration_s"]["median"],
                "stdev_s": s["duration_s"]["stdev"],
                "cv_pct": s["duration_s"]["cv_pct"],
                "throughput_mbps": s["effective_throughput_mbps"]["median"],
                "src_bytes": s.get("src_bytes", 0),
                "verified": s.get("all_verified", False),
                "streams": s.get("streams"),
            }
        )

    with open(output_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\nJSON summary: {output_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze-results.py <results_directory>")
        sys.exit(1)

    results_dir = sys.argv[1]
    stats = load_stats(results_dir)
    iperf = load_iperf(results_dir)
    sys_info = load_system_info(results_dir)

    if not stats:
        print("No benchmark results found.")
        sys.exit(1)

    print(f"Loaded {len(stats)} benchmark results")

    print_terminal_table(stats, iperf)
    print_markdown_table(stats, iperf, sys_info)
    export_json_summary(stats, iperf, os.path.join(results_dir, "summary.json"))


if __name__ == "__main__":
    main()
