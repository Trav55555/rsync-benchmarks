#!/bin/bash
set -e

yum update -y

yum install -y rsync aria2 fpart parallel bc python3 python3-pip

pip3 install awscli

mkdir -p /benchmark/data /benchmark/results /benchmark/scripts

cat > /benchmark/scripts/generate-test-data.sh << 'EOF'
#!/bin/bash
set -e

BASE_DIR="/benchmark/data"

mkdir -p "$BASE_DIR"

generate_small_files() {
    local count=$1
    local size_kb=$2
    local dir="$BASE_DIR/small_${count}_files"
    
    echo "Generating $count small files (${size_kb}KB each)..."
    mkdir -p "$dir"
    
    for i in $(seq 1 $count); do
        dd if=/dev/urandom of="$dir/file_$(printf %08d $i).bin" bs=1024 count=$size_kb 2>/dev/null
    done
    
    du -sh "$dir"
}

generate_large_file() {
    local size_gb=$1
    local dir="$BASE_DIR/large_${size_gb}gb"
    
    echo "Generating ${size_gb}GB file..."
    mkdir -p "$dir"
    
    dd if=/dev/urandom of="$dir/large_file.bin" bs=1M count=$((size_gb * 1024)) 2>/dev/null
    
    du -sh "$dir"
}

generate_mixed() {
    local large_count=$1
    local large_size_gb=$2
    local small_count=$3
    local small_size_kb=$4
    local dir="$BASE_DIR/mixed_${large_count}x${large_size_gb}gb_${small_count}x${small_size_kb}kb"
    
    echo "Generating mixed workload..."
    mkdir -p "$dir/large" "$dir/small"
    
    for i in $(seq 1 $large_count); do
        dd if=/dev/urandom of="$dir/large/large_$(printf %02d $i).bin" bs=1M count=$((large_size_gb * 1024)) 2>/dev/null
    done
    
    for i in $(seq 1 $small_count); do
        dd if=/dev/urandom of="$dir/small/file_$(printf %08d $i).bin" bs=1024 count=$small_size_kb 2>/dev/null
    done
    
    du -sh "$dir"
}

case "$1" in
    small)
        generate_small_files "${2:-100000}" "${3:-4}"
        ;;
    large)
        generate_large_file "${2:-10}"
        ;;
    mixed)
        generate_mixed "${2:-5}" "${3:-1}" "${4:-10000}" "${5:-4}"
        ;;
    *)
        echo "Usage: $0 {small|large|mixed} [args...]"
        echo "  small <count> <size_kb>     - Generate many small files"
        echo "  large <size_gb>               - Generate one large file"
        echo "  mixed <lg_count> <lg_gb> <sm_count> <sm_kb> - Mixed workload"
        exit 1
        ;;
esac
EOF

chmod +x /benchmark/scripts/generate-test-data.sh

cat > /benchmark/scripts/benchmark-rsync.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${DEST_IP:-$1}"
TEST_DIR="${2:-/benchmark/data/small_100000_files}"
RESULTS_FILE="${3:-/benchmark/results/rsync_$(basename $TEST_DIR)_$(date +%Y%m%d_%H%M%S).json}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    echo "Usage: $0 <dest_ip> [test_dir] [results_file]"
    exit 1
fi

mkdir -p /benchmark/results

run_benchmark() {
    local name=$1
    shift
    local cmd="$@"
    
    echo "Running: $name"
    echo "Command: $cmd"
    
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    local start_time=$(date +%s.%N)
    local start_bytes=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
    
    eval "$cmd" 2>&1 | tee /tmp/benchmark_output.log
    local exit_code=$?
    
    local end_time=$(date +%s.%N)
    local end_bytes=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
    
    local duration=$(echo "$end_time - $start_time" | bc)
    local bytes_transferred=$(echo "$end_bytes - $start_bytes" | bc)
    
    cat >> "$RESULTS_FILE" << RESULT
{
  "benchmark": "$name",
  "command": "$cmd",
  "duration_seconds": $duration,
  "bytes_transferred": $bytes_transferred,
  "exit_code": $exit_code,
  "timestamp": "$(date -Iseconds)"
}
RESULT

    echo "Completed: $name in ${duration}s"
    echo "---"
}

TEST_NAME=$(basename "$TEST_DIR")

echo "Starting rsync benchmarks for $TEST_NAME"
echo "Results will be saved to: $RESULTS_FILE"
echo ""

run_benchmark "rsync_default" \
    "rsync -a $TEST_DIR/ ec2-user@$DEST_IP:/benchmark/receive/$TEST_NAME/"

run_benchmark "rsync_partial" \
    "rsync -a --partial --append-verify $TEST_DIR/ ec2-user@$DEST_IP:/benchmark/receive/${TEST_NAME}_partial/"

run_benchmark "rsync_compress" \
    "rsync -az $TEST_DIR/ ec2-user@$DEST_IP:/benchmark/receive/${TEST_NAME}_compress/"

run_benchmark "rsync_checksum" \
    "rsync -a --checksum $TEST_DIR/ ec2-user@$DEST_IP:/benchmark/receive/${TEST_NAME}_checksum/"

run_benchmark "rsync_delete" \
    "rsync -a --delete $TEST_DIR/ ec2-user@$DEST_IP:/benchmark/receive/${TEST_NAME}_delete/"

echo "All benchmarks completed. Results saved to: $RESULTS_FILE"
EOF

chmod +x /benchmark/scripts/benchmark-rsync.sh

cat > /benchmark/scripts/benchmark-parallel.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${DEST_IP:-$1}"
TEST_DIR="${2:-/benchmark/data/small_100000_files}"
PARALLELISM="${3:-4}"
RESULTS_FILE="${4:-/benchmark/results/parallel_$(basename $TEST_DIR)_p${PARALLELISM}_$(date +%Y%m%d_%H%M%S).json}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    exit 1
fi

mkdir -p /benchmark/results

run_parallel_benchmark() {
    local name=$1
    local parallelism=$2
    
    echo "Running: $name with parallelism=$parallelism"
    
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    local start_time=$(date +%s.%N)
    
    find "$TEST_DIR" -type f | split -n r/$parallelism -d - /tmp/file_list_
    
    for i in $(seq 0 $((parallelism - 1))); do
        if [ -f "/tmp/file_list_$i" ]; then
            (
                while read -r file; do
                    rel_path="${file#$TEST_DIR/}"
                    mkdir -p "/benchmark/receive/${name}_p${parallelism}/$(dirname "$rel_path")"
                    cp "$file" "/benchmark/receive/${name}_p${parallelism}/$rel_path"
                done < "/tmp/file_list_$i"
            ) &
        fi
    done
    
    wait
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    cat >> "$RESULTS_FILE" << RESULT
{
  "benchmark": "$name",
  "parallelism": $parallelism,
  "duration_seconds": $duration,
  "timestamp": "$(date -Iseconds)"
}
RESULT

    echo "Completed: $name in ${duration}s"
    rm -f /tmp/file_list_*
}

echo "Starting parallel benchmarks with parallelism=$PARALLELISM"

for p in 1 2 4 8 16; do
    if [ $p -le $PARALLELISM ]; then
        run_parallel_benchmark "parallel_copy" $p
    fi
done

echo "Parallel benchmarks completed. Results saved to: $RESULTS_FILE"
EOF

chmod +x /benchmark/scripts/benchmark-parallel.sh

cat > /benchmark/scripts/benchmark-tar-ssh.sh << 'EOF'
#!/bin/bash
set -e

DEST_IP="${DEST_IP:-$1}"
TEST_DIR="${2:-/benchmark/data/small_100000_files}"
RESULTS_FILE="${3:-/benchmark/results/tar_ssh_$(basename $TEST_DIR)_$(date +%Y%m%d_%H%M%S).json}"

if [ -z "$DEST_IP" ]; then
    echo "Error: Destination IP required"
    exit 1
fi

mkdir -p /benchmark/results

run_benchmark() {
    local name=$1
    shift
    local cmd="$@"
    
    echo "Running: $name"
    echo "Command: $cmd"
    
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    local start_time=$(date +%s.%N)
    
    eval "$cmd"
    local exit_code=$?
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    cat >> "$RESULTS_FILE" << RESULT
{
  "benchmark": "$name",
  "command": "$cmd",
  "duration_seconds": $duration,
  "exit_code": $exit_code,
  "timestamp": "$(date -Iseconds)"
}
RESULT

    echo "Completed: $name in ${duration}s"
    echo "---"
}

echo "Starting tar+ssh benchmarks for $(basename $TEST_DIR)"

run_benchmark "tar_plain_ssh" \
    "tar -C $TEST_DIR -cf - . | ssh ec2-user@$DEST_IP 'tar -C /benchmark/receive/tar_plain -xf -'"

run_benchmark "tar_gzip_ssh" \
    "tar -cz -C $TEST_DIR -f - . | ssh ec2-user@$DEST_IP 'tar -xz -C /benchmark/receive/tar_gzip -f -'"

run_benchmark "tar_zstd_ssh" \
    "tar --zstd -C $TEST_DIR -cf - . | ssh ec2-user@$DEST_IP 'tar --zstd -C /benchmark/receive/tar_zstd -xf -'"

run_benchmark "tar_lz4_ssh" \
    "tar -C $TEST_DIR -cf - . | lz4 | ssh ec2-user@$DEST_IP 'lz4 -d | tar -C /benchmark/receive/tar_lz4 -xf -'"

echo "tar+ssh benchmarks completed. Results saved to: $RESULTS_FILE"
EOF

chmod +x /benchmark/scripts/benchmark-tar-ssh.sh

cat > /benchmark/scripts/upload-results.sh << 'EOF'
#!/bin/bash
set -e

BUCKET="${S3_BUCKET:-$1}"

if [ -z "$BUCKET" ]; then
    echo "Error: S3 bucket required"
    echo "Usage: $0 <s3_bucket>"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)

echo "Uploading results to s3://$BUCKET/$TIMESTAMP/$HOSTNAME/"

aws s3 sync /benchmark/results/ "s3://$BUCKET/$TIMESTAMP/$HOSTNAME/" --sse AES256

echo "Upload complete"
echo "Results available at: s3://$BUCKET/$TIMESTAMP/$HOSTNAME/"
EOF

chmod +x /benchmark/scripts/upload-results.sh

echo "Setup complete. Benchmark environment ready."
echo "Test data generator: /benchmark/scripts/generate-test-data.sh"
echo "Benchmark scripts: /benchmark/scripts/benchmark-*.sh"
