#!/usr/bin/env python3
"""
Analyze benchmark results and generate comparison tables with statistics.
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

    for json_file in results_path.rglob("*_stats.json"):
        try:
            with open(json_file) as f:
                data = json.load(f)
                benchmark_name = data.get(
                    "benchmark", json_file.stem.replace("_stats", "")
                )
                results[benchmark_name].append(data)
        except Exception as e:
            print(f"Warning: Could not parse {json_file}: {e}")

    for json_file in results_path.rglob("tool_*.json"):
        try:
            with open(json_file) as f:
                data = json.load(f)
                benchmark_name = data.get(
                    "benchmark", json_file.stem.replace("tool_", "")
                )
                results[benchmark_name].append(data)
        except Exception as e:
            print(f"Warning: Could not parse {json_file}: {e}")

    for json_file in results_path.rglob("parallel_*.json"):
        try:
            with open(json_file) as f:
                data = json.load(f)
                benchmark_name = (
                    f"{data.get('benchmark', 'parallel')}_p{data.get('parallelism', 0)}"
                )
                results[benchmark_name].append(data)
        except Exception as e:
            print(f"Warning: Could not parse {json_file}: {e}")

    for json_file in results_path.rglob("resume_*.json"):
        try:
            with open(json_file) as f:
                data = json.load(f)
                results[f"resume_{data.get('test', 'unknown')}"].append(data)
        except Exception as e:
            print(f"Warning: Could not parse {json_file}: {e}")

    return results


def format_duration(seconds):
    """Format duration in human-readable form."""
    if isinstance(seconds, str):
        try:
            seconds = float(seconds)
        except:
            return seconds

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
    if isinstance(bytes_val, str):
        try:
            bytes_val = int(bytes_val)
        except:
            return bytes_val

    if bytes_val < 1024:
        return f"{bytes_val}B"
    elif bytes_val < 1024 * 1024:
        return f"{bytes_val / 1024:.1f}KB"
    elif bytes_val < 1024 * 1024 * 1024:
        return f"{bytes_val / (1024 * 1024):.1f}MB"
    else:
        return f"{bytes_val / (1024 * 1024 * 1024):.1f}GB"


def format_throughput(mbps):
    """Format throughput in Mbps or Gbps."""
    if mbps >= 1000:
        return f"{mbps / 1000:.2f} Gbps"
    else:
        return f"{mbps:.1f} Mbps"


def analyze_benchmark_suite(results):
    """Analyze main benchmark suite results with statistics."""
    print("\n" + "=" * 100)
    print("BENCHMARK SUITE RESULTS (with statistics)")
    print("=" * 100)

    suite_tests = [
        k
        for k in results.keys()
        if k
        in [
            "rsync_default",
            "rsync_compress",
            "rsync_checksum",
            "tar_plain",
            "tar_zstd",
            "tar_gzip",
        ]
    ]

    if not suite_tests:
        print("No benchmark suite results found.")
        return

    print(
        f"\n{'Benchmark':<25} {'Mean':<12} {'±StdDev':<12} {'CV%':<8} {'Throughput':<15} {'Runs':<6}"
    )
    print("-" * 100)

    # Sort by mean duration
    sorted_tests = []
    for test in suite_tests:
        for run in results[test]:
            duration_info = run.get("duration_seconds", {})
            if isinstance(duration_info, dict):
                mean_duration = duration_info.get("mean", 0)
            else:
                mean_duration = duration_info

            throughput = run.get("throughput_mbps", 0)
            sorted_tests.append((test, mean_duration, throughput, run))

    sorted_tests.sort(key=lambda x: x[1])

    baseline_throughput = None
    for test, mean_duration, throughput, run in sorted_tests:
        duration_info = run.get("duration_seconds", {})

        if isinstance(duration_info, dict):
            mean = duration_info.get("mean", 0)
            stdev = duration_info.get("stdev", 0)
            cv = duration_info.get("cv_percent", 0)
        else:
            mean = duration_info
            stdev = 0
            cv = 0

        runs = run.get("runs", 1)

        # Calculate relative performance
        if baseline_throughput is None and throughput > 0:
            baseline_throughput = throughput

        relative = ""
        if baseline_throughput and throughput > 0:
            ratio = throughput / baseline_throughput
            if ratio > 1:
                relative = f" ({ratio:.1f}x)"

        print(
            f"{test:<25} {format_duration(mean):<12} {format_duration(stdev):<12} {cv:<8.1f} {format_throughput(throughput):<15}{relative} {runs:<6}"
        )


def analyze_parallel_benchmarks(results):
    """Analyze parallel benchmark results."""
    print("\n" + "=" * 100)
    print("PARALLEL TRANSFER RESULTS")
    print("=" * 100)

    parallel_tests = [k for k in results.keys() if k.startswith("parallel_")]

    if not parallel_tests:
        print("No parallel benchmark results found.")
        return

    print(
        f"\n{'Configuration':<25} {'Duration':<12} {'Throughput':<15} {'Speedup':<10}"
    )
    print("-" * 100)

    # Extract parallelism level and sort
    test_data = []
    for test in parallel_tests:
        for run in results[test]:
            parallelism = run.get("parallelism", 1)
            duration = run.get("duration_seconds", 0)
            throughput = run.get("throughput_mbps", 0)
            test_data.append((parallelism, duration, throughput, test))

    test_data.sort(key=lambda x: x[0])

    baseline_throughput = None
    for parallelism, duration, throughput, test in test_data:
        if baseline_throughput is None:
            baseline_throughput = throughput

        speedup = ""
        if baseline_throughput and throughput > 0:
            ratio = throughput / baseline_throughput
            speedup = f"{ratio:.1f}x"

        print(
            f"{test:<25} {format_duration(duration):<12} {format_throughput(throughput):<15} {speedup:<10}"
        )


def analyze_resume_tests(results):
    """Analyze resume/interruption test results."""
    print("\n" + "=" * 100)
    print("RESUME/PARTIAL TRANSFER RESULTS")
    print("=" * 100)

    resume_tests = [k for k in results.keys() if k.startswith("resume_")]

    if not resume_tests:
        print("No resume test results found.")
        return

    print(
        f"\n{'Test':<25} {'Partial':<12} {'Resume':<12} {'Total':<12} {'File Size':<15}"
    )
    print("-" * 100)

    for test in sorted(resume_tests):
        for run in results[test]:
            partial = run.get("partial_duration_seconds", 0)
            resume = run.get("resume_duration_seconds", 0)
            total = run.get("total_duration_seconds", 0)
            file_size = run.get("file_size_bytes", 0)

            print(
                f"{test:<25} {format_duration(partial):<12} {format_duration(resume):<12} {format_duration(total):<12} {format_bytes(file_size):<15}"
            )


def generate_comparison_table(results):
    """Generate a comparison table for the blog post."""
    print("\n" + "=" * 100)
    print("BLOG POST COMPARISON TABLE")
    print("=" * 100)

    # Table 1: Main benchmark results
    print("\n### Transfer Tools Comparison (Mean ± StdDev, n=3 runs)")
    print("\n| Tool | Configuration | Duration | Throughput | CV% | Notes |")
    print("|------|--------------|----------|------------|-----|-------|")

    suite_tests = {
        "rsync_default": "rsync -a",
        "rsync_compress": "rsync -az (compressed)",
        "rsync_checksum": "rsync -a --checksum",
        "tar_plain": "tar \| ssh (no compression)",
        "tar_gzip": "tar -cz \| ssh (gzip)",
        "tar_zstd": "tar --zstd \| ssh (zstd)",
    }

    for test_key, config in suite_tests.items():
        if test_key in results:
            for run in results[test_key]:
                duration_info = run.get("duration_seconds", {})
                if isinstance(duration_info, dict):
                    mean = duration_info.get("mean", 0)
                    stdev = duration_info.get("stdev", 0)
                    cv = duration_info.get("cv_percent", 0)
                else:
                    mean = duration_info
                    stdev = 0
                    cv = 0

                throughput = run.get("throughput_mbps", 0)

                duration_str = f"{mean:.1f}s ± {stdev:.1f}s"
                throughput_str = format_throughput(throughput)

                notes = ""
                if "compress" in test_key and throughput > 0:
                    notes = "Good for compressible data"
                elif "checksum" in test_key:
                    notes = "CPU-intensive verification"

                print(
                    f"| {config:<35} | {duration_str:<18} | {throughput_str:<15} | {cv:.1f}% | {notes} |"
                )

    # Table 2: Parallel scaling
    print("\n### Parallel Transfer Scaling")
    print("\n| Parallelism | Duration | Throughput | Speedup | Efficiency |")
    print("|-------------|----------|------------|---------|------------|")

    parallel_data = []
    for test_key in results:
        if test_key.startswith("parallel_rsync_p"):
            for run in results[test_key]:
                p = run.get("parallelism", 1)
                duration = run.get("duration_seconds", 0)
                throughput = run.get("throughput_mbps", 0)
                parallel_data.append((p, duration, throughput))

    if parallel_data:
        parallel_data.sort(key=lambda x: x[0])
        baseline_throughput = parallel_data[0][2] if parallel_data else 1

        for p, duration, throughput in parallel_data:
            speedup = throughput / baseline_throughput if baseline_throughput > 0 else 1
            efficiency = (speedup / p) * 100 if p > 0 else 100

            print(
                f"| {p:<11} | {format_duration(duration):<8} | {format_throughput(throughput):<10} | {speedup:.1f}x | {efficiency:.0f}% |"
            )

    # Table 3: Resume capability
    resume_tests = [k for k in results.keys() if k.startswith("resume_")]
    if resume_tests:
        print("\n### Resume/Partial Transfer Performance")
        print(
            "\n| Method | Partial Duration | Resume Duration | Total Time | Overhead |"
        )
        print("|--------|-----------------|-----------------|------------|----------|")

        for test in sorted(resume_tests):
            for run in results[test]:
                test_name = test.replace("resume_", "")
                partial = run.get("partial_duration_seconds", 0)
                resume = run.get("resume_duration_seconds", 0)
                total = run.get("total_duration_seconds", 0)

                # Calculate overhead vs ideal (if we knew ideal time)
                overhead = "N/A"

                print(
                    f"| {test_name:<15} | {format_duration(partial):<15} | {format_duration(resume):<15} | {format_duration(total):<10} | {overhead:<8} |"
                )


def generate_summary_report(results_dir, results):
    """Generate a comprehensive summary report."""
    print("\n" + "=" * 100)
    print("BENCHMARK SUMMARY REPORT")
    print("=" * 100)

    # Load system info if available
    system_info_file = Path(results_dir) / "system_info.json"
    if system_info_file.exists():
        with open(system_info_file) as f:
            system_info = json.load(f)

        print("\n### System Configuration")
        print(f"- **Instance Type:** {system_info.get('cpu_model', 'Unknown')}")
        print(f"- **CPU Cores:** {system_info.get('cpu_cores', 'Unknown')}")
        print(f"- **Memory:** {system_info.get('memory_gb', 'Unknown')} GB")
        print(f"- **Kernel:** {system_info.get('kernel', 'Unknown')}")
        print(f"- **Filesystem:** {system_info.get('filesystem', 'Unknown')}")
        print(f"- **Rsync Version:** {system_info.get('rsync_version', 'Unknown')}")

    # Count total benchmarks
    total_benchmarks = len(results)
    total_runs = sum(len(runs) for runs in results.values())

    print(f"\n### Test Coverage")
    print(f"- **Total Benchmarks:** {total_benchmarks}")
    print(f"- **Total Runs:** {total_runs}")
    print(f"- **Tools Tested:** rsync, tar+ssh, parallel variants, aria2c, rclone")
    print(f"- **Data Types:** Mixed realistic workload (DB, logs, code, binary assets)")

    # Key findings
    print("\n### Key Findings")

    # Find fastest tool
    fastest_tool = None
    fastest_throughput = 0
    for test_key, runs in results.items():
        for run in runs:
            throughput = run.get("throughput_mbps", 0)
            if throughput > fastest_throughput:
                fastest_throughput = throughput
                fastest_tool = test_key

    if fastest_tool:
        print(
            f"- **Fastest Tool:** {fastest_tool} ({format_throughput(fastest_throughput)})"
        )

    # Find best compression
    compress_tests = {
        k: v
        for k, v in results.items()
        if "compress" in k or "gzip" in k or "zstd" in k
    }
    if compress_tests:
        print(f"- **Compression Tools Tested:** {len(compress_tests)} variants")

    # Parallel scaling
    parallel_tests = {k: v for k, v in results.items() if "parallel" in k}
    if parallel_tests:
        print(
            f"- **Parallel Configurations:** {len(parallel_tests)} different parallelism levels"
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

    # Generate all reports
    analyze_benchmark_suite(results)
    analyze_parallel_benchmarks(results)
    analyze_resume_tests(results)
    generate_comparison_table(results)
    generate_summary_report(results_dir, results)

    print("\n" + "=" * 100)
    print("Analysis complete!")
    print("=" * 100)
    print(f"\nResults directory: {results_dir}")
    print("View individual JSON files for detailed per-run metrics.")


if __name__ == "__main__":
    main()
