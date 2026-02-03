#!/usr/bin/env python3
"""
Analyze benchmark results and generate comparison tables.
"""

import json
import sys
import os
from pathlib import Path
from collections import defaultdict
import statistics


def load_results(results_dir):
    """Load all JSON result files from directory."""
    results = defaultdict(list)

    results_path = Path(results_dir)
    if not results_path.exists():
        print(f"Error: Results directory '{results_dir}' not found")
        sys.exit(1)

    for json_file in results_path.rglob("*.json"):
        try:
            with open(json_file) as f:
                data = json.load(f)
                if isinstance(data, list):
                    for item in data:
                        results[item.get("benchmark", "unknown")].append(item)
                else:
                    results[data.get("benchmark", "unknown")].append(data)
        except Exception as e:
            print(f"Warning: Could not parse {json_file}: {e}")

    return results


def format_duration(seconds):
    """Format duration in human-readable form."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    elif seconds < 3600:
        minutes = seconds / 60
        return f"{minutes:.1f}m"
    else:
        hours = seconds / 3600
        return f"{hours:.1f}h"


def format_bytes(bytes_val):
    """Format bytes in human-readable form."""
    if bytes_val < 1024:
        return f"{bytes_val}B"
    elif bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.1f}KB"
    elif bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.1f}MB"
    else:
        return f"{bytes_val / (1024 * 1024 * 1024):.1f}GB"


def analyze_rsync_benchmarks(results):
    """Analyze rsync benchmark results."""
    print("\n" + "=" * 80)
    print("RSYNC BENCHMARK RESULTS")
    print("=" * 80)

    rsync_tests = [k for k in results.keys() if k.startswith("rsync_")]

    if not rsync_tests:
        print("No rsync benchmark results found.")
        return

    print(f"\n{'Benchmark':<25} {'Duration':<15} {'Status':<10}")
    print("-" * 80)

    for test in sorted(rsync_tests):
        for run in results[test]:
            duration = run.get("duration_seconds", 0)
            exit_code = run.get("exit_code", -1)
            status = "✓" if exit_code == 0 else "✗"

            print(f"{test:<25} {format_duration(duration):<15} {status:<10}")


def analyze_tar_benchmarks(results):
    """Analyze tar+ssh benchmark results."""
    print("\n" + "=" * 80)
    print("TAR+SSH BENCHMARK RESULTS")
    print("=" * 80)

    tar_tests = [k for k in results.keys() if k.startswith("tar_")]

    if not tar_tests:
        print("No tar+ssh benchmark results found.")
        return

    print(f"\n{'Benchmark':<25} {'Duration':<15} {'Status':<10}")
    print("-" * 80)

    for test in sorted(tar_tests):
        for run in results[test]:
            duration = run.get("duration_seconds", 0)
            exit_code = run.get("exit_code", -1)
            status = "✓" if exit_code == 0 else "✗"

            print(f"{test:<25} {format_duration(duration):<15} {status:<10}")


def analyze_parallel_benchmarks(results):
    """Analyze parallelization benchmark results."""
    print("\n" + "=" * 80)
    print("PARALLELIZATION BENCHMARK RESULTS")
    print("=" * 80)

    parallel_tests = [k for k in results.keys() if "parallel" in k.lower()]

    if not parallel_tests:
        print("No parallelization benchmark results found.")
        return

    print(f"\n{'Parallelism':<15} {'Duration':<15} {'Status':<10}")
    print("-" * 80)

    for test in sorted(parallel_tests):
        for run in results[test]:
            parallelism = run.get("parallelism", "N/A")
            duration = run.get("duration_seconds", 0)

            print(f"{parallelism:<15} {format_duration(duration):<15} {'✓':<10}")


def generate_comparison_table(results):
    """Generate a comparison table for the blog post."""
    print("\n" + "=" * 80)
    print("BLOG POST COMPARISON TABLE")
    print("=" * 80)

    print("\n### Small Files (100K x 4KB = ~400MB total)")
    print("\n| Tool | Configuration | Time | Relative Speed |")
    print("|------|--------------|------|----------------|")

    small_file_tests = {
        "rsync_default": "rsync -a",
        "rsync_partial": "rsync -a --partial",
        "rsync_compress": "rsync -az",
        "tar_plain_ssh": "tar | ssh",
        "tar_zstd_ssh": "tar --zstd | ssh",
    }

    baseline_time = None
    for test_name, config in small_file_tests.items():
        if test_name in results:
            for run in results[test_name]:
                duration = run.get("duration_seconds", 0)
                if baseline_time is None:
                    baseline_time = duration

                relative = f"{baseline_time / duration:.1f}x" if duration > 0 else "N/A"
                print(
                    f"| {config:<20} | {format_duration(duration):<12} | {relative:<14} |"
                )

    print("\n### Large Files (10GB single file)")
    print("\n| Tool | Configuration | Time | Throughput |")
    print("|------|--------------|------|------------|")

    large_file_tests = {
        "rsync_default": "rsync -a",
        "rsync_partial": "rsync -a --partial --append-verify",
    }

    for test_name, config in large_file_tests.items():
        if test_name in results:
            for run in results[test_name]:
                duration = run.get("duration_seconds", 0)
                bytes_transferred = run.get(
                    "bytes_transferred", 10 * 1024 * 1024 * 1024
                )

                if duration > 0:
                    throughput_mbps = (bytes_transferred * 8) / (duration * 1024 * 1024)
                    throughput_str = f"{throughput_mbps:.0f} Mbps"
                else:
                    throughput_str = "N/A"

                print(
                    f"| {config:<30} | {format_duration(duration):<12} | {throughput_str:<10} |"
                )


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze-results.py <results_directory>")
        sys.exit(1)

    results_dir = sys.argv[1]
    results = load_results(results_dir)

    if not results:
        print("No benchmark results found.")
        sys.exit(1)

    print(f"Loaded results from {len(list(Path(results_dir).rglob('*.json')))} files")
    print(f"Found {len(results)} unique benchmark types")

    analyze_rsync_benchmarks(results)
    analyze_tar_benchmarks(results)
    analyze_parallel_benchmarks(results)
    generate_comparison_table(results)

    print("\n" + "=" * 80)
    print("Analysis complete!")
    print("=" * 80)


if __name__ == "__main__":
    main()
