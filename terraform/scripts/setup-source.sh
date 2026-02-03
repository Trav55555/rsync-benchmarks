#!/bin/bash
set -e

yum update -y

yum install -y rsync aria2 fpart parallel bc python3 python3-pip lz4 zstd iperf3 sysstat attr

pip3 install awscli

mkdir -p /benchmark/data /benchmark/results /benchmark/scripts

cat > /benchmark/scripts/generate-test-data.sh << 'EOF'
#!/bin/bash
set -e

BASE_DIR="/benchmark/data"
mkdir -p "$BASE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

generate_incompressible_data() {
    local count=$1
    local size_kb=$2
    local dir="$BASE_DIR/incompressible_${count}x${size_kb}kb"
    
    log "Generating $count incompressible files (${size_kb}KB each)..."
    mkdir -p "$dir"
    
    for i in $(seq 1 $count); do
        dd if=/dev/urandom of="$dir/file_$(printf %08d $i).bin" bs=1024 count=$size_kb 2>/dev/null
    done
    
    du -sh "$dir"
}

generate_compressible_data() {
    local count=$1
    local size_kb=$2
    local dir="$BASE_DIR/compressible_${count}x${size_kb}kb"
    
    log "Generating $count compressible text files (${size_kb}KB each)..."
    mkdir -p "$dir"
    
    # Generate repetitive text data (highly compressible)
    for i in $(seq 1 $count); do
        # Create a file with repetitive patterns (logs, JSON-like data)
        {
            echo '{"timestamp":"2024-01-15T10:30:00Z","level":"INFO","message":"Application started","service":"benchmark","iteration":1}'
            for j in $(seq 1 $((size_kb * 10))); do
                echo "LOG ENTRY $j: This is a repetitive log message that will compress very well with gzip zstd and lz4 algorithms. "
            done
            echo '{"timestamp":"2024-01-15T10:30:01Z","level":"INFO","message":"Application completed","service":"benchmark","iteration":1}'
        } > "$dir/file_$(printf %08d $i).log"
    done
    
    du -sh "$dir"
}

generate_source_code_like() {
    local count=$1
    local dir="$BASE_DIR/source_code_${count}files"
    
    log "Generating $count source code-like files..."
    mkdir -p "$dir"
    
    # Simulate a codebase with realistic structure
    for i in $(seq 1 $count); do
        cat > "$dir/module_$(printf %04d $i).py" << PYEOF
#!/usr/bin/env python3
"""
Module $(printf %04d $i) - Auto-generated for benchmarking
This simulates real source code with comments, imports, and functions
"""

import os
import sys
import json
import logging
from typing import Dict, List, Optional, Any
from dataclasses import dataclass
from pathlib import Path

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@dataclass
class DataItem:
    """Represents a data item in the system"""
    id: int
    name: str
    value: float
    metadata: Dict[str, Any]
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'id': self.id,
            'name': self.name,
            'value': self.value,
            'metadata': self.metadata
        }

class DataProcessor:
    """Processes data items in batches"""
    
    def __init__(self, batch_size: int = 100):
        self.batch_size = batch_size
        self.processed_count = 0
        self.items: List[DataItem] = []
    
    def add_item(self, item: DataItem) -> None:
        self.items.append(item)
        if len(self.items) >= self.batch_size:
            self._process_batch()
    
    def _process_batch(self) -> None:
        for item in self.items:
            logger.info(f"Processing item {item.id}: {item.name}")
            self.processed_count += 1
        self.items.clear()
    
    def finalize(self) -> int:
        if self.items:
            self._process_batch()
        return self.processed_count

def main():
    processor = DataProcessor(batch_size=50)
    
    for i in range(1000):
        item = DataItem(
            id=i,
            name=f"item_{i}",
            value=float(i) * 1.5,
            metadata={'created': '2024-01-15', 'version': '1.0.0'}
        )
        processor.add_item(item)
    
    count = processor.finalize()
    print(f"Processed {count} items")
    return 0

if __name__ == '__main__':
    sys.exit(main())
PYEOF
    done
    
    du -sh "$dir"
}

generate_large_file() {
    local size_gb=$1
    local compressibility=$2  # "high", "medium", "low"
    local dir="$BASE_DIR/large_${size_gb}gb_${compressibility}"
    
    log "Generating ${size_gb}GB ${compressibility} compressibility file..."
    mkdir -p "$dir"
    
    case "$compressibility" in
        high)
            # Highly compressible: repetitive pattern
            log "  Creating highly compressible data (repetitive patterns)..."
            head -c $((size_gb * 1024 * 1024 * 1024 / 100)) /dev/zero | \
                while IFS= read -r -d '' chunk || [[ -n "$chunk" ]]; do
                    printf "A%.0s" $(seq 1 100)
                done > "$dir/large_file.bin" 2>/dev/null || true
            ;;
        medium)
            # Medium: mix of text and binary
            log "  Creating medium compressibility data (mixed content)..."
            dd if=/dev/urandom of="$dir/large_file.bin" bs=1M count=$((size_gb * 512)) 2>/dev/null
            # Append compressible text
            for i in $(seq 1 $((size_gb * 10))); do
                echo "LOG ENTRY $i: This is sample log data that compresses moderately well. " >> "$dir/large_file.bin"
            done
            ;;
        low)
            # Low: mostly random
            log "  Creating low compressibility data (mostly random)..."
            dd if=/dev/urandom of="$dir/large_file.bin" bs=1M count=$((size_gb * 1024)) 2>/dev/null
            ;;
    esac
    
    du -sh "$dir"
}

generate_mixed_workload() {
    local dir="$BASE_DIR/mixed_realistic"
    
    log "Generating realistic mixed workload..."
    mkdir -p "$dir"
    
    # 1. Database-like files (compressible)
    log "  Creating database-like JSON files..."
    mkdir -p "$dir/database"
    for i in $(seq 1 1000); do
        cat > "$dir/database/records_$(printf %04d $i).json" << JSONEOF
{
  "records": [
    {"id": 1, "name": "Alice", "email": "alice@example.com", "created": "2024-01-15T10:00:00Z"},
    {"id": 2, "name": "Bob", "email": "bob@example.com", "created": "2024-01-15T10:01:00Z"},
    {"id": 3, "name": "Charlie", "email": "charlie@example.com", "created": "2024-01-15T10:02:00Z"}
  ],
  "metadata": {"version": "1.0", "count": 3, "batch": $i}
}
JSONEOF
    done
    
    # 2. Log files (highly compressible)
    log "  Creating log files..."
    mkdir -p "$dir/logs"
    for i in $(seq 1 100); do
        for j in $(seq 1 1000); do
            echo "$(date -Iseconds) [INFO] service-$i: Processing request $j - This is a log message that will compress very well" >> "$dir/logs/app_$(printf %03d $i).log"
        done
    done
    
    # 3. Binary assets (incompressible)
    log "  Creating binary assets..."
    mkdir -p "$dir/assets"
    dd if=/dev/urandom of="$dir/assets/image_001.bin" bs=1M count=50 2>/dev/null
    dd if=/dev/urandom of="$dir/assets/image_002.bin" bs=1M count=50 2>/dev/null
    dd if=/dev/urandom of="$dir/assets/video_segment.bin" bs=1M count=200 2>/dev/null
    
    # 4. Source code (moderately compressible)
    log "  Creating source code tree..."
    mkdir -p "$dir/src"
    generate_source_code_like 500
    mv "$BASE_DIR/source_code_500files"/* "$dir/src/"
    rmdir "$BASE_DIR/source_code_500files" 2>/dev/null || true
    
    # 5. Large compressed archive (to test delta sync)
    log "  Creating large archive..."
    tar -czf "$dir/archive_large.tar.gz" -C "$dir" logs/ 2>/dev/null || true
    
    du -sh "$dir"
    
    # Show compression ratios
    log "Compression analysis:"
    log "  Original size: $(du -sh "$dir" | cut -f1)"
    tar -czf /tmp/compressed_test.tar.gz -C "$dir" . 2>/dev/null
    log "  Compressed (gzip): $(du -sh /tmp/compressed_test.tar.gz | cut -f1)"
    rm -f /tmp/compressed_test.tar.gz
}

generate_metadata_test() {
    local dir="$BASE_DIR/metadata_test"
    
    log "Generating files with metadata for preservation testing..."
    mkdir -p "$dir"
    
    # Create files with specific permissions, ownership, timestamps
    echo "file with permissions" > "$dir/perms_test.txt"
    chmod 750 "$dir/perms_test.txt"
    
    # Create files with ACLs (if supported)
    echo "file with ACLs" > "$dir/acl_test.txt"
    setfacl -m u:ec2-user:rwx "$dir/acl_test.txt" 2>/dev/null || log "  Warning: ACLs not supported"
    
    # Create files with extended attributes
    echo "file with xattrs" > "$dir/xattr_test.txt"
    setfattr -n user.comment -v "benchmark test data" "$dir/xattr_test.txt" 2>/dev/null || log "  Warning: xattrs not supported"
    
    # Create symlinks and hard links
    echo "original content" > "$dir/link_target.txt"
    ln -s link_target.txt "$dir/symlink.txt"
    ln "$dir/link_target.txt" "$dir/hardlink.txt"
    
    # Create sparse file
    dd if=/dev/zero of="$dir/sparse_file.bin" bs=1M count=0 seek=100 2>/dev/null
    
    ls -la "$dir/"
}

case "$1" in
    incompressible)
        generate_incompressible_data "${2:-10000}" "${3:-4}"
        ;;
    compressible)
        generate_compressible_data "${2:-10000}" "${3:-4}"
        ;;
    source-code)
        generate_source_code_like "${2:-500}"
        ;;
    large)
        generate_large_file "${2:-1}" "${3:-medium}"
        ;;
    mixed)
        generate_mixed_workload
        ;;
    metadata)
        generate_metadata_test
        ;;
    all)
        log "Generating all test data types..."
        generate_incompressible_data 10000 4
        generate_compressible_data 10000 4
        generate_source_code_like 500
        generate_large_file 1 medium
        generate_mixed_workload
        generate_metadata_test
        log "All test data generated!"
        ;;
    *)
        echo "Usage: $0 {incompressible|compressible|source-code|large|mixed|metadata|all} [args...]"
        echo ""
        echo "Data types:"
        echo "  incompressible <count> <size_kb>  - Random binary data (worst case for compression)"
        echo "  compressible <count> <size_kb>    - Repetitive text (best case for compression)"
        echo "  source-code <count>               - Python-like source files (realistic code)"
        echo "  large <size_gb> <compressibility> - Single large file (high/medium/low)"
        echo "  mixed                             - Realistic mixed workload (DB, logs, assets, code)"
        echo "  metadata                          - Files with ACLs, xattrs, symlinks, sparse"
        echo "  all                               - Generate all test data types"
        exit 1
        ;;
esac
EOF

chmod +x /benchmark/scripts/generate-test-data.sh

cat > /benchmark/scripts/benchmark-runner.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${DEST_IP:-$1}"
TEST_DIR="${2:-/benchmark/data/mixed_realistic}"
RUNS="${3:-3}"
RESULTS_DIR="${4:-/benchmark/results}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    echo "Usage: $0 <dest_ip> [test_dir] [runs] [results_dir]"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# System info for reproducibility
log_system_info() {
    local info_file="$RESULTS_DIR/system_info.json"
    
    cat > "$info_file" << INFOEOF
{
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "kernel": "$(uname -r)",
  "cpu_model": "$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)",
  "cpu_cores": $(nproc),
  "memory_gb": $(free -g | grep Mem | awk '{print $2}'),
  "disk_type": "$(lsblk -d -o NAME,ROTA,TYPE | grep -E 'nvme|xvd' | head -1 | awk '{print $1}')",
  "filesystem": "$(df -T /benchmark | tail -1 | awk '{print $2}')",
  "rsync_version": "$(rsync --version | head -1)",
  "tar_version": "$(tar --version | head -1)",
  "ssh_version": "$(ssh -V 2>&1 | head -1)"
}
INFOEOF
}

# Drop caches and sync
reset_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches
    sleep 1
}

# Collect system metrics during transfer
start_metrics_collection() {
    local pid_file="$1"
    local output_file="$2"
    
    (
        echo "timestamp,cpu_percent,mem_percent,io_wait,disk_read_mb,disk_write_mb" > "$output_file"
        while true; do
            local stats=$(iostat -c 1 1 | tail -1)
            local cpu=$(echo "$stats" | awk '{print $1}')
            local io_wait=$(echo "$stats" | awk '{print $4}')
            
            local mem_info=$(free | grep Mem)
            local mem_used=$(echo "$mem_info" | awk '{print $3}')
            local mem_total=$(echo "$mem_info" | awk '{print $2}')
            local mem_pct=$(echo "scale=1; $mem_used * 100 / $mem_total" | bc)
            
            local disk_stats=$(cat /proc/diskstats | grep -E 'nvme0n1|xvda' | head -1)
            local disk_read=$(echo "$disk_stats" | awk '{print $6 * 512 / 1024 / 1024}')
            local disk_write=$(echo "$disk_stats" | awk '{print $10 * 512 / 1024 / 1024}')
            
            echo "$(date +%s),$cpu,$mem_pct,$io_wait,$disk_read,$disk_write" >> "$output_file"
            sleep 1
        done
    ) &
    echo $! > "$pid_file"
}

stop_metrics_collection() {
    local pid_file="$1"
    if [ -f "$pid_file" ]; then
        kill $(cat "$pid_file") 2>/dev/null || true
        rm -f "$pid_file"
    fi
}

# Run a single benchmark with full metrics
run_single_benchmark() {
    local name=$1
    local cmd=$2
    local output_dir=$3
    local run_num=$4
    
    local run_dir="$output_dir/${name}_run${run_num}"
    mkdir -p "$run_dir"
    
    echo "  Run $run_num: $name"
    
    # Reset caches
    reset_caches
    
    # Start metrics collection
    local metrics_pid_file="$run_dir/metrics.pid"
    local metrics_file="$run_dir/metrics.csv"
    start_metrics_collection "$metrics_pid_file" "$metrics_file"
    
    # Time the command with detailed stats
    local start_time=$(date +%s.%N)
    local start_cpu=$(cat /proc/stat | grep '^cpu ' | awk '{print ($2+$3+$4+$5+$6+$7+$8)}')
    
    # Run the command and capture output
    if ! /usr/bin/time -v -o "$run_dir/time_stats.txt" bash -c "$cmd" > "$run_dir/stdout.log" 2> "$run_dir/stderr.log"; then
        echo "    WARNING: Command failed or partial success"
    fi
    
    local end_time=$(date +%s.%N)
    local end_cpu=$(cat /proc/stat | grep '^cpu ' | awk '{print ($2+$3+$4+$5+$6+$7+$8)}')
    
    # Stop metrics collection
    stop_metrics_collection "$metrics_pid_file"
    
    # Calculate duration
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Parse time stats
    local user_time=$(grep "User time" "$run_dir/time_stats.txt" | sed 's/.*: //')
    local sys_time=$(grep "System time" "$run_dir/time_stats.txt" | sed 's/.*: //')
    local max_rss=$(grep "Maximum resident" "$run_dir/time_stats.txt" | awk '{print $6}')
    local vol_ctx=$(grep "Voluntary context" "$run_dir/time_stats.txt" | awk '{print $4}')
    local invol_ctx=$(grep "Involuntary context" "$run_dir/time_stats.txt" | awk '{print $4}')
    
    # Create result JSON
    cat > "$run_dir/result.json" << RESULTEOF
{
  "benchmark": "$name",
  "run_number": $run_num,
  "duration_seconds": $duration,
  "user_time_seconds": "$user_time",
  "system_time_seconds": "$sys_time",
  "max_rss_kb": ${max_rss:-0},
  "voluntary_context_switches": ${vol_ctx:-0},
  "involuntary_context_switches": ${inv_ctx:-0},
  "timestamp": "$(date -Iseconds)",
  "command": "$cmd"
}
RESULTEOF
    
    echo "    Duration: ${duration}s"
}

# Run multiple iterations and calculate statistics
run_benchmark_with_stats() {
    local name=$1
    local cmd=$2
    local test_dir=$3
    local output_dir=$4
    local runs=$5
    
    echo "Benchmark: $name"
    echo "  Command: $cmd"
    echo "  Runs: $runs"
    
    # Warm-up run (not recorded)
    echo "  Warm-up run..."
    reset_caches
    bash -c "$cmd" > /dev/null 2>&1 || true
    
    # Actual benchmark runs
    for i in $(seq 1 $runs); do
        run_single_benchmark "$name" "$cmd" "$output_dir" "$i"
    done
    
    # Calculate statistics
    local stats_file="$output_dir/${name}_stats.json"
    python3 << PYEOF
import json
import statistics
import os

runs = []
for i in range(1, $runs + 1):
    run_file = f"$output_dir/${name}_run{i}/result.json"
    if os.path.exists(run_file):
        with open(run_file) as f:
            runs.append(json.load(f))

if len(runs) < 2:
    print("  ERROR: Need at least 2 successful runs for statistics")
    exit(1)

durations = [r['duration_seconds'] for r in runs]
mean_duration = statistics.mean(durations)
stdev_duration = statistics.stdev(durations) if len(durations) > 1 else 0
min_duration = min(durations)
max_duration = max(durations)

# Calculate throughput if we know the data size
import subprocess
try:
    result = subprocess.run(['du', '-sb', '$test_dir'], capture_output=True, text=True)
    bytes_total = int(result.stdout.split()[0])
    throughput_mbps = (bytes_total * 8) / (mean_duration * 1000000)
except:
    bytes_total = 0
    throughput_mbps = 0

stats = {
    "benchmark": "$name",
    "runs": len(runs),
    "duration_seconds": {
        "mean": round(mean_duration, 3),
        "stdev": round(stdev_duration, 3),
        "min": round(min_duration, 3),
        "max": round(max_duration, 3),
        "cv_percent": round((stdev_duration / mean_duration) * 100, 1) if mean_duration > 0 else 0
    },
    "bytes_transferred": bytes_total,
    "throughput_mbps": round(throughput_mbps, 2),
    "runs_detail": runs
}

with open("$stats_file", 'w') as f:
    json.dump(stats, f, indent=2)

print(f"  Mean duration: {mean_duration:.2f}s (±{stdev_duration:.2f}s, CV: {(stdev_duration/mean_duration)*100:.1f}%)")
print(f"  Throughput: {throughput_mbps:.2f} Mbps")
PYEOF
}

# Main benchmark suite
main() {
    log_system_info
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local output_dir="$RESULTS_DIR/benchmark_${timestamp}"
    mkdir -p "$output_dir"
    
    echo "========================================"
    echo "Rsync Benchmark Suite"
    echo "========================================"
    echo "Test directory: $TEST_DIR"
    echo "Destination: $DEST_IP"
    echo "Runs per test: $RUNS"
    echo "Output: $output_dir"
    echo "========================================"
    
    # Get data size
    local data_size=$(du -sh "$TEST_DIR" | cut -f1)
    echo "Data size: $data_size"
    echo ""
    
    # Test 1: rsync default
    run_benchmark_with_stats "rsync_default" \
        "rsync -a '$TEST_DIR/' ec2-user@$DEST_IP:/benchmark/receive/rsync_default/" \
        "$TEST_DIR" "$output_dir" "$RUNS"
    
    # Test 2: rsync with compression
    run_benchmark_with_stats "rsync_compress" \
        "rsync -az '$TEST_DIR/' ec2-user@$DEST_IP:/benchmark/receive/rsync_compress/" \
        "$TEST_DIR" "$output_dir" "$RUNS"
    
    # Test 3: rsync with checksum
    run_benchmark_with_stats "rsync_checksum" \
        "rsync -a --checksum '$TEST_DIR/' ec2-user@$DEST_IP:/benchmark/receive/rsync_checksum/" \
        "$TEST_DIR" "$output_dir" "$RUNS"
    
    # Test 4: tar + ssh (plain)
    run_benchmark_with_stats "tar_plain" \
        "tar -C '$TEST_DIR' -cf - . | ssh ec2-user@$DEST_IP 'tar -C /benchmark/receive/tar_plain -xf -'" \
        "$TEST_DIR" "$output_dir" "$RUNS"
    
    # Test 5: tar + zstd + ssh
    run_benchmark_with_stats "tar_zstd" \
        "tar --zstd -C '$TEST_DIR' -cf - . | ssh ec2-user@$DEST_IP 'tar --zstd -C /benchmark/receive/tar_zstd -xf -'" \
        "$TEST_DIR" "$output_dir" "$RUNS"
    
    # Test 6: tar + gzip + ssh
    run_benchmark_with_stats "tar_gzip" \
        "tar -cz -C '$TEST_DIR' -f - . | ssh ec2-user@$DEST_IP 'tar -xz -C /benchmark/receive/tar_gzip -xf -'" \
        "$TEST_DIR" "$output_dir" "$RUNS"
    
    echo ""
    echo "========================================"
    echo "Benchmark suite complete!"
    echo "Results: $output_dir"
    echo "========================================"
}

main "$@"
EOF

chmod +x /benchmark/scripts/benchmark-runner.sh

cat > /benchmark/scripts/benchmark-resume.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${DEST_IP:-$1}"
TEST_FILE="${2:-/benchmark/data/large_1gb_medium/large_file.bin}"
RESULTS_DIR="${3:-/benchmark/results}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Test partial transfer and resume
test_resume() {
    local test_name=$1
    local rsync_opts=$2
    local dest_dir="/benchmark/receive/${test_name}"
    
    log "Testing: $test_name"
    log "  Options: $rsync_opts"
    
    # Clean start
    ssh ec2-user@$DEST_IP "rm -rf $dest_dir; mkdir -p $dest_dir" 2>/dev/null || true
    
    # Start transfer in background and kill it after 5 seconds
    log "  Starting transfer (will interrupt after 5s)..."
    local start_time=$(date +%s.%N)
    
    (rsync $rsync_opts "$TEST_FILE" "ec2-user@$DEST_IP:$dest_dir/" 2>/dev/null) &
    local rsync_pid=$!
    
    sleep 5
    kill $rsync_pid 2>/dev/null || true
    wait $rsync_pid 2>/dev/null || true
    
    local interrupt_time=$(date +%s.%N)
    local partial_duration=$(echo "$interrupt_time - $start_time" | bc)
    
    # Check partial file exists
    local partial_exists=$(ssh ec2-user@$DEST_IP "test -f $dest_dir/*.partial && echo 'yes' || echo 'no'" 2>/dev/null)
    log "  Partial file created: $partial_exists"
    
    # Now resume
    log "  Resuming transfer..."
    local resume_start=$(date +%s.%N)
    
    if rsync $rsync_opts "$TEST_FILE" "ec2-user@$DEST_IP:$dest_dir/"; then
        local resume_end=$(date +%s.%N)
        local resume_duration=$(echo "$resume_end - $resume_start" | bc)
        local total_duration=$(echo "$resume_end - $start_time" | bc)
        
        # Verify file
        local src_size=$(stat -c%s "$TEST_FILE")
        local dst_size=$(ssh ec2-user@$DEST_IP "stat -c%s $dest_dir/$(basename $TEST_FILE)" 2>/dev/null)
        
        if [ "$src_size" = "$dst_size" ]; then
            log "  SUCCESS: File verified ($src_size bytes)"
            log "  Partial transfer: ${partial_duration}s"
            log "  Resume transfer: ${resume_duration}s"
            log "  Total time: ${total_duration}s"
            
            # Save result
            cat > "$RESULTS_DIR/resume_${test_name}.json" << RESUMEEOF
{
  "test": "$test_name",
  "rsync_options": "$rsync_opts",
  "file_size_bytes": $src_size,
  "partial_duration_seconds": $partial_duration,
  "resume_duration_seconds": $resume_duration,
  "total_duration_seconds": $total_duration,
  "success": true,
  "timestamp": "$(date -Iseconds)"
}
RESUMEEOF
        else
            log "  ERROR: Size mismatch (src: $src_size, dst: $dst_size)"
        fi
    else
        log "  ERROR: Resume failed"
    fi
}

# Main
log "Resume/Partial Transfer Tests"
log "================================"
log "Test file: $TEST_FILE"
log "Destination: $DEST_IP"
log ""

# Test with --partial
test_resume "partial_flag" "-a --partial"

# Test with --partial --append-verify
test_resume "partial_append" "-a --partial --append-verify"

log ""
log "Resume tests complete!"
EOF

chmod +x /benchmark/scripts/benchmark-resume.sh

cat > /benchmark/scripts/benchmark-parallel.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${DEST_IP:-$1}"
TEST_DIR="${2:-/benchmark/data/mixed_realistic}"
MAX_PARALLEL="${3:-8}"
RESULTS_DIR="${4:-/benchmark/results}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Get list of top-level directories or files to shard
generate_shard_list() {
    local test_dir=$1
    local num_shards=$2
    
    # Find top-level items and distribute them
    find "$test_dir" -maxdepth 1 -mindepth 1 -type d -o -maxdepth 1 -mindepth 1 -type f | \
        sort | \
        awk -v n="$num_shards" '{print NR % n, $0}' > /tmp/shard_map.txt
    
    # Create file lists for each shard
    for i in $(seq 0 $((num_shards - 1))); do
        grep "^$i " /tmp/shard_map.txt | cut -d' ' -f2- > "/tmp/shard_${i}.txt"
    done
}

# Run parallel rsync test
run_parallel_rsync() {
    local parallelism=$1
    local output_file="$RESULTS_DIR/parallel_rsync_p${parallelism}.json"
    
    log "Testing parallel rsync with $parallelism streams..."
    
    # Clean destination
    ssh ec2-user@$DEST_IP "rm -rf /benchmark/receive/parallel_p${parallelism}; mkdir -p /benchmark/receive/parallel_p${parallelism}" 2>/dev/null || true
    
    # Generate shard lists
    generate_shard_list "$TEST_DIR" "$parallelism"
    
    # Start timing
    local start_time=$(date +%s.%N)
    
    # Launch parallel rsyncs
    for i in $(seq 0 $((parallelism - 1))); do
        if [ -s "/tmp/shard_${i}.txt" ]; then
            (
                while read -r item; do
                    local rel_path="${item#$TEST_DIR/}"
                    local dest_path="/benchmark/receive/parallel_p${parallelism}/$(dirname "$rel_path")"
                    
                    # Create destination directory
                    ssh ec2-user@$DEST_IP "mkdir -p '$dest_path'" 2>/dev/null || true
                    
                    # Rsync this item
                    if [ -d "$item" ]; then
                        rsync -a "$item/" "ec2-user@$DEST_IP:$dest_path/$(basename "$rel_path")/"
                    else
                        rsync -a "$item" "ec2-user@$DEST_IP:$dest_path/"
                    fi
                done < "/tmp/shard_${i}.txt"
            ) &
        fi
    done
    
    # Wait for all to complete
    wait
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate throughput
    local bytes_total=$(du -sb "$TEST_DIR" | cut -f1)
    local throughput_mbps=$(echo "scale=2; ($bytes_total * 8) / ($duration * 1000000)" | bc)
    
    log "  Duration: ${duration}s"
    log "  Throughput: ${throughput_mbps} Mbps"
    
    # Save result
    cat > "$output_file" << PAREOF
{
  "benchmark": "parallel_rsync",
  "parallelism": $parallelism,
  "duration_seconds": $duration,
  "bytes_transferred": $bytes_total,
  "throughput_mbps": $throughput_mbps,
  "timestamp": "$(date -Iseconds)"
}
PAREOF
    
    # Cleanup
    rm -f /tmp/shard_*.txt /tmp/shard_map.txt
}

# Test fpsync if available
test_fpsync() {
    if ! command -v fpsync &> /dev/null; then
        log "fpsync not available, skipping..."
        return
    fi
    
    log "Testing fpsync..."
    
    local output_file="$RESULTS_DIR/fpsync.json"
    
    # Clean destination
    ssh ec2-user@$DEST_IP "rm -rf /benchmark/receive/fpsync; mkdir -p /benchmark/receive/fpsync" 2>/dev/null || true
    
    local start_time=$(date +%s.%N)
    
    # Run fpsync
    fpsync -n 8 -o "-a" "$TEST_DIR/" "ec2-user@$DEST_IP:/benchmark/receive/fpsync/"
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    local bytes_total=$(du -sb "$TEST_DIR" | cut -f1)
    local throughput_mbps=$(echo "scale=2; ($bytes_total * 8) / ($duration * 1000000)" | bc)
    
    log "  Duration: ${duration}s"
    log "  Throughput: ${throughput_mbps} Mbps"
    
    cat > "$output_file" << FPSEOF
{
  "benchmark": "fpsync",
  "parallelism": 8,
  "duration_seconds": $duration,
  "bytes_transferred": $bytes_total,
  "throughput_mbps": $throughput_mbps,
  "timestamp": "$(date -Iseconds)"
}
FPSEOF
}

# Main
log "Parallel Transfer Benchmarks"
log "============================"
log "Test directory: $TEST_DIR"
log "Max parallelism: $MAX_PARALLEL"
log ""

# Test different parallelism levels
for p in 1 2 4 8; do
    if [ $p -le $MAX_PARALLEL ]; then
        run_parallel_rsync $p
    fi
done

# Test fpsync
test_fpsync

log ""
log "Parallel benchmarks complete!"
EOF

chmod +x /benchmark/scripts/benchmark-parallel.sh

cat > /benchmark/scripts/benchmark-tools.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${DEST_IP:-$1}"
TEST_DIR="${2:-/benchmark/data/mixed_realistic}"
RESULTS_DIR="${3:-/benchmark/results}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

run_tool_benchmark() {
    local name=$1
    local cmd=$2
    
    log "Benchmarking: $name"
    
    local start_time=$(date +%s.%N)
    
    if eval "$cmd"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        
        local bytes_total=$(du -sb "$TEST_DIR" | cut -f1)
        local throughput_mbps=$(echo "scale=2; ($bytes_total * 8) / ($duration * 1000000)" | bc)
        
        log "  Duration: ${duration}s"
        log "  Throughput: ${throughput_mbps} Mbps"
        
        cat > "$RESULTS_DIR/tool_${name}.json" << TOOLEOF
{
  "benchmark": "$name",
  "duration_seconds": $duration,
  "bytes_transferred": $bytes_total,
  "throughput_mbps": $throughput_mbps,
  "timestamp": "$(date -Iseconds)"
}
TOOLEOF
    else
        log "  FAILED"
    fi
}

# Test aria2c if available
test_aria2c() {
    if ! command -v aria2c &> /dev/null; then
        log "aria2c not available, skipping..."
        return
    fi
    
    log "Testing aria2c (multi-connection download)..."
    
    # Create a test file and serve it via HTTP on destination
    local test_file="/benchmark/data/large_1gb_medium/large_file.bin"
    
    # Setup simple HTTP server on destination (requires python3)
    ssh ec2-user@$DEST_IP "cd /benchmark/data && python3 -m http.server 8080 &" 2>/dev/null || true
    sleep 2
    
    local output_file="$RESULTS_DIR/aria2c.json"
    
    # Clean and download
    rm -f /tmp/aria2c_download.bin
    
    local start_time=$(date +%s.%N)
    
    if aria2c -x 8 -s 8 -o /tmp/aria2c_download.bin "http://$DEST_IP:8080/large_1gb_medium/large_file.bin"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        
        local bytes_total=$(stat -c%s /tmp/aria2c_download.bin)
        local throughput_mbps=$(echo "scale=2; ($bytes_total * 8) / ($duration * 1000000)" | bc)
        
        log "  Duration: ${duration}s"
        log "  Throughput: ${throughput_mbps} Mbps"
        
        cat > "$output_file" << ARIAEOF
{
  "benchmark": "aria2c",
  "connections": 8,
  "duration_seconds": $duration,
  "bytes_transferred": $bytes_total,
  "throughput_mbps": $throughput_mbps,
  "timestamp": "$(date -Iseconds)"
}
ARIAEOF
    fi
    
    # Cleanup
    rm -f /tmp/aria2c_download.bin
    ssh ec2-user@$DEST_IP "pkill -f 'python3 -m http.server'" 2>/dev/null || true
}

# Test rclone if available
test_rclone() {
    if ! command -v rclone &> /dev/null; then
        log "rclone not available, installing..."
        curl https://rclone.org/install.sh | bash 2>/dev/null || {
            log "  Failed to install rclone, skipping..."
            return
        }
    fi
    
    log "Testing rclone..."
    
    # Configure rclone for SFTP
    mkdir -p ~/.config/rclone
    cat > ~/.config/rclone/rclone.conf << RCLONEOF
[benchmark_dest]
type = sftp
host = $DEST_IP
user = ec2-user
key_file = ~/.ssh/id_rsa
RCLONEEOF
    
    local output_file="$RESULTS_DIR/rclone.json"
    
    # Clean destination
    ssh ec2-user@$DEST_IP "rm -rf /benchmark/receive/rclone; mkdir -p /benchmark/receive/rclone" 2>/dev/null || true
    
    local start_time=$(date +%s.%N)
    
    if rclone copy "$TEST_DIR" benchmark_dest:/benchmark/receive/rclone --transfers 16 --checkers 16 --stats 0; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        
        local bytes_total=$(du -sb "$TEST_DIR" | cut -f1)
        local throughput_mbps=$(echo "scale=2; ($bytes_total * 8) / ($duration * 1000000)" | bc)
        
        log "  Duration: ${duration}s"
        log "  Throughput: ${throughput_mbps} Mbps"
        
        cat > "$output_file" << RCLONEEOF
{
  "benchmark": "rclone",
  "transfers": 16,
  "checkers": 16,
  "duration_seconds": $duration,
  "bytes_transferred": $bytes_total,
  "throughput_mbps": $throughput_mbps,
  "timestamp": "$(date -Iseconds)"
}
RCLONEEOF
    fi
}

# Main
log "Additional Tools Benchmarks"
log "============================="

# Test aria2c
test_aria2c

# Test rclone
test_rclone

log ""
log "Tool benchmarks complete!"
EOF

chmod +x /benchmark/scripts/benchmark-tools.sh

cat > /benchmark/scripts/run-all-benchmarks.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${1:-$DEST_IP}"
RESULTS_DIR="${2:-/benchmark/results}"
RUNS="${3:-3}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    echo "Usage: $0 <destination_ip> [results_dir] [runs]"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

mkdir -p "$RESULTS_DIR"

log "=========================================="
log "Complete Rsync Benchmark Suite"
log "=========================================="
log "Destination: $DEST_IP"
log "Results: $RESULTS_DIR"
log "Runs per test: $RUNS"
log "=========================================="
log ""

# Generate all test data
log "Step 1: Generating test data..."
/benchmark/scripts/generate-test-data.sh all
log ""

# Run main benchmark suite
log "Step 2: Running main benchmark suite..."
/benchmark/scripts/benchmark-runner.sh "$DEST_IP" /benchmark/data/mixed_realistic "$RUNS" "$RESULTS_DIR"
log ""

# Run resume tests
log "Step 3: Running resume/interruption tests..."
/benchmark/scripts/benchmark-resume.sh "$DEST_IP" /benchmark/data/large_1gb_medium/large_file.bin "$RESULTS_DIR"
log ""

# Run parallel benchmarks
log "Step 4: Running parallel transfer benchmarks..."
/benchmark/scripts/benchmark-parallel.sh "$DEST_IP" /benchmark/data/mixed_realistic 8 "$RESULTS_DIR"
log ""

# Run additional tools
log "Step 5: Running additional tool benchmarks..."
/benchmark/scripts/benchmark-tools.sh "$DEST_IP" /benchmark/data/mixed_realistic "$RESULTS_DIR"
log ""

# Upload results
log "Step 6: Uploading results to S3..."
if [ -n "$S3_BUCKET" ]; then
    /benchmark/scripts/upload-results.sh "$S3_BUCKET"
else
    log "  S3_BUCKET not set, skipping upload"
fi

log ""
log "=========================================="
log "All benchmarks complete!"
log "Results available in: $RESULTS_DIR"
log "=========================================="

# List result files
find "$RESULTS_DIR" -name "*.json" -type f | sort
EOF

chmod +x /benchmark/scripts/run-all-benchmarks.sh

echo "Enhanced benchmark environment ready!"
echo "Test data generator: /benchmark/scripts/generate-test-data.sh"
echo "Main benchmark runner: /benchmark/scripts/benchmark-runner.sh"
echo "Resume tests: /benchmark/scripts/benchmark-resume.sh"
echo "Parallel tests: /benchmark/scripts/benchmark-parallel.sh"
echo "Additional tools: /benchmark/scripts/benchmark-tools.sh"
echo "All-in-one: /benchmark/scripts/run-all-benchmarks.sh"
