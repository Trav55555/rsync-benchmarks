#!/bin/bash
set -uo pipefail

# Rigorous file transfer benchmark suite
# Fixes: bilateral cache drops, destination cleanup per run, no warm-up,
# iperf3 baseline, SSH mux, transfer verification, safe JSON via Python

DEST="${1:?Usage: $0 <dest_private_ip>}"
RUNS=5
RESULTS_DIR="/benchmark/results/suite_$(date +%Y%m%d_%H%M%S)"
DATA_DIR="/benchmark/data"
RECV_DIR="/benchmark/receive"
SSH_MUX="/tmp/bench_mux"

mkdir -p "$RESULTS_DIR" "$SSH_MUX"

SSH_CMD="ssh -o StrictHostKeyChecking=no -o ControlPath=${SSH_MUX}/%r@%h:%p"
export RSYNC_RSH="$SSH_CMD"

ssh_dest() { $SSH_CMD ec2-user@"$DEST" "$@"; }

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# ── SSH multiplexing ─────────────────────────────────────────────
setup_ssh() {
    log "Establishing SSH ControlMaster..."
    $SSH_CMD -o ControlMaster=yes -fN ec2-user@"$DEST" 2>/dev/null || true
    sleep 1
}

teardown_ssh() {
    ssh -O exit -o ControlPath="${SSH_MUX}/%r@%h:%p" ec2-user@"$DEST" 2>/dev/null || true
}

# ── Bilateral cache drop ─────────────────────────────────────────
reset_caches() {
    sync && echo 3 > /proc/sys/vm/drop_caches
    ssh_dest 'sync && sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"'
    sleep 1
}

# ── Clean destination dir ─────────────────────────────────────────
clean_dest() {
    ssh_dest "rm -rf '$1' && mkdir -p '$1'"
}

# ── System info ───────────────────────────────────────────────────
collect_system_info() {
    RESULTS_DIR="$RESULTS_DIR" python3 << 'PYEOF'
import json, subprocess, os

def cmd(c):
    try: return subprocess.check_output(c, shell=True, text=True).strip()
    except: return "unknown"

info = {
    "timestamp": cmd("date -Iseconds"),
    "hostname": cmd("hostname"),
    "kernel": cmd("uname -r"),
    "cpu_model": cmd("grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2").strip(),
    "cpu_cores": int(cmd("nproc")),
    "memory_gb": int(cmd("free -g | grep Mem | awk '{print $2}'")),
    "filesystem": cmd("df -T /benchmark | tail -1 | awk '{print $2}'"),
    "rsync_version": cmd("rsync --version | head -1"),
    "tar_version": cmd("tar --version | head -1"),
}

out = os.path.join(os.environ["RESULTS_DIR"], "system_info.json")
with open(out, "w") as f:
    json.dump(info, f, indent=2)

print(f"[info] {info['cpu_model']} | {info['cpu_cores']} cores | {info['memory_gb']}GB | {info['filesystem']}")
PYEOF
}

# ── iperf3 baseline ──────────────────────────────────────────────
run_iperf_baseline() {
    log "Network baseline (iperf3)..."
    ssh_dest "pkill iperf3 2>/dev/null; sleep 1; iperf3 -s -D" 2>/dev/null
    sleep 2

    local i
    for i in 1 2 3; do
        iperf3 -c "$DEST" -t 10 -J > "$RESULTS_DIR/iperf3_run${i}.json" 2>/dev/null || true
    done

    ssh_dest "pkill iperf3" 2>/dev/null || true

    RESULTS_DIR="$RESULTS_DIR" python3 << 'PYEOF'
import json, os, statistics

bws = []
rd = os.environ["RESULTS_DIR"]
for i in range(1, 4):
    f = os.path.join(rd, f"iperf3_run{i}.json")
    if os.path.exists(f):
        try:
            d = json.load(open(f))
            bws.append(d["end"]["sum_sent"]["bits_per_second"] / 1e6)
        except: pass

if bws:
    result = {"median_mbps": round(statistics.median(bws), 2), "runs": len(bws)}
    with open(os.path.join(rd, "iperf3_stats.json"), "w") as f:
        json.dump(result, f, indent=2)
    print(f"  Network ceiling: {statistics.median(bws):.0f} Mbps ({len(bws)} runs)")
else:
    print("  WARNING: iperf3 failed")
PYEOF
}

# ── Data generation ───────────────────────────────────────────────
ensure_test_data() {
    if [ ! -d "$DATA_DIR/mixed_realistic" ]; then
        log "Generating mixed_realistic test data..."
        /benchmark/scripts/generate-test-data.sh mixed
    fi
    if [ ! -d "$DATA_DIR/incompressible_10000x4kb" ]; then
        log "Generating small files test data (10000 x 4KB)..."
        /benchmark/scripts/generate-test-data.sh incompressible 10000 4
    fi
}

# ── Core: single timed transfer ──────────────────────────────────
run_single() {
    local name="$1"
    local cmd_file="$2"
    local run_num="$3"
    local test_dir="$4"
    local dest_dir="${RECV_DIR}/${name}"
    local run_dir="${RESULTS_DIR}/${name}/run_${run_num}"
    mkdir -p "$run_dir"

    clean_dest "$dest_dir"
    reset_caches

    local start end exit_code=0
    start=$(date +%s.%N)
    /usr/bin/time -v -o "$run_dir/time.txt" "$cmd_file" \
        > "$run_dir/stdout.log" 2> "$run_dir/stderr.log" || exit_code=$?
    end=$(date +%s.%N)

    local src_bytes dst_bytes max_rss
    src_bytes=$(du -sb "$test_dir" | cut -f1)
    dst_bytes=$(ssh_dest "du -sb '$dest_dir' 2>/dev/null | cut -f1" 2>/dev/null || echo "0")
    max_rss=$(grep "Maximum resident" "$run_dir/time.txt" 2>/dev/null | awk '{print $6}' || echo "0")

    START="$start" END="$end" EXIT="$exit_code" SRC="$src_bytes" \
    DST="${dst_bytes:-0}" RSS="${max_rss:-0}" NAME="$name" RUN="$run_num" \
    RDIR="$run_dir" python3 << 'PYEOF'
import json, os

start = float(os.environ["START"])
end = float(os.environ["END"])
duration = round(end - start, 3)
src = int(os.environ["SRC"])
dst = int(os.environ.get("DST") or "0")
rss = int(os.environ.get("RSS") or "0")
ec = int(os.environ["EXIT"])
name = os.environ["NAME"]
run = int(os.environ["RUN"])

verified = abs(src - dst) < max(src * 0.01, 4096)
tp = round((src * 8) / (duration * 1e6), 2) if duration > 0 else 0

result = {
    "benchmark": name,
    "run": run,
    "exit_code": ec,
    "duration_s": duration,
    "src_bytes": src,
    "dst_bytes": dst,
    "verified": verified,
    "max_rss_kb": rss,
    "effective_throughput_mbps": tp,
}

with open(os.path.join(os.environ["RDIR"], "result.json"), "w") as f:
    json.dump(result, f, indent=2)

ok = "ok" if verified and ec == 0 else "FAIL"
print(f"  Run {run}: {duration:.3f}s  {tp} Mbps  [{ok}]")
PYEOF
}

# ── Core: N runs + statistics ─────────────────────────────────────
run_benchmark() {
    local name="$1"
    local test_dir="$2"
    local profile="$3"
    local cmd_file="/tmp/bench_${name}.sh"

    # Write the command (caller already created cmd_file)
    chmod +x "$cmd_file"

    echo ""
    log "=== $name ==="

    local i
    for i in $(seq 1 "$RUNS"); do
        run_single "$name" "$cmd_file" "$i" "$test_dir"
    done

    NAME="$name" RDIR="$RESULTS_DIR" RUNS_N="$RUNS" PROFILE="$profile" \
    python3 << 'PYEOF'
import json, os, statistics

name = os.environ["NAME"]
rd = os.environ["RDIR"]
n_expected = int(os.environ["RUNS_N"])
profile = os.environ["PROFILE"]

runs = []
for i in range(1, n_expected + 1):
    f = os.path.join(rd, name, f"run_{i}", "result.json")
    if os.path.exists(f):
        r = json.load(open(f))
        if r["exit_code"] == 0 and r["verified"]:
            runs.append(r)

n = len(runs)
if n == 0:
    print("  SKIPPED (no valid runs)")
    exit(0)
if n < 3:
    print(f"  WARNING: only {n} valid runs")

durations = [r["duration_s"] for r in runs]
throughputs = [r["effective_throughput_mbps"] for r in runs]

trimmed_d = sorted(durations)[1:-1] if n >= 5 else durations
trimmed_t = sorted(throughputs)[1:-1] if n >= 5 else throughputs

med = statistics.median(durations)
mean = statistics.mean(durations)
sd = statistics.stdev(durations) if n > 1 else 0
cv = round((sd / mean) * 100, 1) if mean > 0 and n > 1 else 0

stats = {
    "benchmark": name,
    "data_profile": profile,
    "valid_runs": n,
    "total_runs": n_expected,
    "duration_s": {
        "median": round(med, 3),
        "mean": round(mean, 3),
        "trimmed_mean": round(statistics.mean(trimmed_d), 3),
        "stdev": round(sd, 3),
        "min": round(min(durations), 3),
        "max": round(max(durations), 3),
        "cv_pct": cv,
    },
    "effective_throughput_mbps": {
        "median": round(statistics.median(throughputs), 2),
        "trimmed_mean": round(statistics.mean(trimmed_t), 2),
    },
    "src_bytes": runs[0]["src_bytes"],
    "all_verified": all(r["verified"] for r in runs),
}

with open(os.path.join(rd, f"{name}_stats.json"), "w") as f:
    json.dump(stats, f, indent=2)

flag = " !! HIGH VARIANCE" if cv > 15 else ""
print(f"  -> Median: {med:.3f}s | CV: {cv}%{flag} | Throughput: {stats['effective_throughput_mbps']['median']} Mbps | Verified: {stats['all_verified']}")
PYEOF
}

# ── Parallel rsync ────────────────────────────────────────────────
run_parallel_bench() {
    local streams="$1"
    local test_dir="$2"
    local profile="$3"
    local name="${profile}_parallel_${streams}x"
    local dest_dir="${RECV_DIR}/${name}"

    echo ""
    log "=== $name ==="

    local run_num
    for run_num in $(seq 1 "$RUNS"); do
        local run_dir="${RESULTS_DIR}/${name}/run_${run_num}"
        mkdir -p "$run_dir"

        clean_dest "$dest_dir"
        reset_caches

        # Shard files across streams
        (cd "$test_dir" && find . -type f) | sort | \
            awk -v n="$streams" '{print NR % n, $0}' > "$run_dir/shard_map.txt"

        local s
        for s in $(seq 0 $((streams - 1))); do
            grep "^${s} " "$run_dir/shard_map.txt" | cut -d' ' -f2- > "$run_dir/shard_${s}.txt"
        done

        local start end
        start=$(date +%s.%N)

        for s in $(seq 0 $((streams - 1))); do
            if [ -s "$run_dir/shard_${s}.txt" ]; then
                rsync -a --files-from="$run_dir/shard_${s}.txt" "$test_dir" \
                    "ec2-user@${DEST}:${dest_dir}/" 2>"$run_dir/shard_${s}_err.log" &
            fi
        done
        wait

        end=$(date +%s.%N)

        local src_bytes dst_bytes
        src_bytes=$(du -sb "$test_dir" | cut -f1)
        dst_bytes=$(ssh_dest "du -sb '$dest_dir' 2>/dev/null | cut -f1" 2>/dev/null || echo "0")

        START="$start" END="$end" SRC="$src_bytes" DST="${dst_bytes:-0}" \
        NAME="$name" RUN="$run_num" STREAMS="$streams" RDIR="$run_dir" \
        python3 << 'PYEOF'
import json, os

start = float(os.environ["START"])
end = float(os.environ["END"])
duration = round(end - start, 3)
src = int(os.environ["SRC"])
dst = int(os.environ.get("DST") or "0")
name = os.environ["NAME"]
run = int(os.environ["RUN"])
streams = int(os.environ["STREAMS"])

verified = abs(src - dst) < max(src * 0.01, 4096)
tp = round((src * 8) / (duration * 1e6), 2) if duration > 0 else 0

result = {
    "benchmark": name,
    "run": run,
    "streams": streams,
    "exit_code": 0,
    "duration_s": duration,
    "src_bytes": src,
    "dst_bytes": dst,
    "verified": verified,
    "effective_throughput_mbps": tp,
}

with open(os.path.join(os.environ["RDIR"], "result.json"), "w") as f:
    json.dump(result, f, indent=2)

ok = "ok" if verified else "FAIL"
print(f"  Run {run}: {duration:.3f}s  {tp} Mbps  [{ok}]")
PYEOF
    done

    # Stats
    NAME="$name" RDIR="$RESULTS_DIR" RUNS_N="$RUNS" PROFILE="$profile" \
    python3 << 'PYEOF'
import json, os, statistics

name = os.environ["NAME"]
rd = os.environ["RDIR"]
n_expected = int(os.environ["RUNS_N"])
profile = os.environ["PROFILE"]

runs = []
for i in range(1, n_expected + 1):
    f = os.path.join(rd, name, f"run_{i}", "result.json")
    if os.path.exists(f):
        r = json.load(open(f))
        if r.get("verified", False):
            runs.append(r)

n = len(runs)
if n == 0:
    print("  SKIPPED (no valid runs)")
    exit(0)

durations = [r["duration_s"] for r in runs]
throughputs = [r["effective_throughput_mbps"] for r in runs]
trimmed_d = sorted(durations)[1:-1] if n >= 5 else durations
trimmed_t = sorted(throughputs)[1:-1] if n >= 5 else throughputs

med = statistics.median(durations)
sd = statistics.stdev(durations) if n > 1 else 0
cv = round((sd / statistics.mean(durations)) * 100, 1) if n > 1 and statistics.mean(durations) > 0 else 0

stats = {
    "benchmark": name,
    "data_profile": profile,
    "streams": runs[0].get("streams", 1),
    "valid_runs": n,
    "total_runs": n_expected,
    "duration_s": {
        "median": round(med, 3),
        "mean": round(statistics.mean(durations), 3),
        "trimmed_mean": round(statistics.mean(trimmed_d), 3),
        "stdev": round(sd, 3),
        "min": round(min(durations), 3),
        "max": round(max(durations), 3),
        "cv_pct": cv,
    },
    "effective_throughput_mbps": {
        "median": round(statistics.median(throughputs), 2),
        "trimmed_mean": round(statistics.mean(trimmed_t), 2),
    },
    "src_bytes": runs[0]["src_bytes"],
    "all_verified": all(r["verified"] for r in runs),
}

with open(os.path.join(rd, f"{name}_stats.json"), "w") as f:
    json.dump(stats, f, indent=2)

print(f"  -> Median: {med:.3f}s | CV: {cv}% | Throughput: {stats['effective_throughput_mbps']['median']} Mbps")
PYEOF
}

# ── Write command files ───────────────────────────────────────────
write_cmds() {
    local test_dir="$1"
    local profile="$2"
    local dest="$DEST"
    local recv="$RECV_DIR"
    local ssh_cmd="$SSH_CMD"

    cat > "/tmp/bench_${profile}_rsync_default.sh" << CMDEOF
#!/bin/bash
rsync -a '${test_dir}/' ec2-user@${dest}:${recv}/${profile}_rsync_default/
CMDEOF

    cat > "/tmp/bench_${profile}_rsync_compress.sh" << CMDEOF
#!/bin/bash
rsync -az '${test_dir}/' ec2-user@${dest}:${recv}/${profile}_rsync_compress/
CMDEOF

    cat > "/tmp/bench_${profile}_tar_ssh.sh" << CMDEOF
#!/bin/bash
tar -cf - -C '${test_dir}' . | ${ssh_cmd} ec2-user@${dest} 'tar -xf - -C ${recv}/${profile}_tar_ssh/'
CMDEOF

    cat > "/tmp/bench_${profile}_tar_zstd_ssh.sh" << CMDEOF
#!/bin/bash
tar -cf - -C '${test_dir}' . | zstd -1 -T0 | ${ssh_cmd} ec2-user@${dest} 'zstd -d | tar -xf - -C ${recv}/${profile}_tar_zstd_ssh/'
CMDEOF

    chmod +x /tmp/bench_${profile}_*.sh
}

# ── Summary ───────────────────────────────────────────────────────
print_summary() {
    RESULTS_DIR="$RESULTS_DIR" python3 << 'PYEOF'
import json, os, glob

rd = os.environ["RESULTS_DIR"]
stats_files = sorted(glob.glob(os.path.join(rd, "*_stats.json")))

print("\n" + "=" * 90)
print("SUMMARY")
print("=" * 90)
print(f"{'Benchmark':<35} {'Median':>8} {'CV%':>6} {'Throughput':>14} {'Verified':>9}")
print("-" * 90)

for sf in stats_files:
    if "iperf3" in sf:
        continue
    s = json.load(open(sf))
    name = s["benchmark"]
    d = s["duration_s"]
    tp = s["effective_throughput_mbps"]
    v = "yes" if s["all_verified"] else "NO"
    print(f"{name:<35} {d['median']:>7.3f}s {d['cv_pct']:>5.1f}% {tp['median']:>10.2f} Mbps {v:>9}")

iperf = os.path.join(rd, "iperf3_stats.json")
if os.path.exists(iperf):
    ip = json.load(open(iperf))
    print(f"\nNetwork ceiling: {ip['median_mbps']:.0f} Mbps")

print("=" * 90)
PYEOF
}

# ── MAIN ──────────────────────────────────────────────────────────
main() {
    echo "================================================================"
    echo "  Rsync Benchmark Suite v2 (Rigorous)"
    echo "  Dest: $DEST | Runs: $RUNS | Output: $RESULTS_DIR"
    echo "================================================================"

    setup_ssh
    collect_system_info
    ensure_test_data
    run_iperf_baseline

    # ── Profile 1: mixed_realistic (~960MB) ──
    local test_dir="$DATA_DIR/mixed_realistic"
    local profile="mixed"
    local data_size
    data_size=$(du -sh "$test_dir" | cut -f1)
    echo ""
    log "--- Profile: mixed_realistic ($data_size) ---"

    write_cmds "$test_dir" "$profile"

    run_benchmark "${profile}_rsync_default"  "$test_dir" "$profile"
    run_benchmark "${profile}_rsync_compress" "$test_dir" "$profile"
    run_benchmark "${profile}_tar_ssh"        "$test_dir" "$profile"
    run_benchmark "${profile}_tar_zstd_ssh"   "$test_dir" "$profile"

    run_parallel_bench 2 "$test_dir" "$profile"
    run_parallel_bench 4 "$test_dir" "$profile"

    # ── Profile 2: many small files (10000 x 4KB) ──
    test_dir="$DATA_DIR/incompressible_10000x4kb"
    profile="small"
    data_size=$(du -sh "$test_dir" | cut -f1)
    echo ""
    log "--- Profile: small_files ($data_size) ---"

    write_cmds "$test_dir" "$profile"

    run_benchmark "${profile}_rsync_default"  "$test_dir" "$profile"
    run_benchmark "${profile}_tar_ssh"        "$test_dir" "$profile"
    run_benchmark "${profile}_tar_zstd_ssh"   "$test_dir" "$profile"

    # ── Done ──
    print_summary

    echo ""
    echo "Results: $RESULTS_DIR"
    log "Benchmark suite complete."

    teardown_ssh
}

main "$@"
