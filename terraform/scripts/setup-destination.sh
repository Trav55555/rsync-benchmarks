#!/bin/bash
set -e

dnf update -y

dnf install -y rsync bc python3 python3-pip lz4 zstd iproute-tc || true

mkdir -p /benchmark/receive /benchmark/results /benchmark/scripts

SIMULATE_LATENCY="${SIMULATE_LATENCY:-false}"
LATENCY_MS="${LATENCY_MS:-0}"
BANDWIDTH_LIMIT="${BANDWIDTH_LIMIT:-0}"

if [ -f /etc/benchmark/latency-config ]; then
    . /etc/benchmark/latency-config
fi

setup_latency_simulation() {
    if [ "$SIMULATE_LATENCY" = "true" ] || [ "$SIMULATE_LATENCY" = "True" ]; then
        echo "Setting up network latency simulation..."
        echo "  Latency: ${LATENCY_MS}ms"

        IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
        tc qdisc add dev $IFACE root netem delay ${LATENCY_MS}ms 10ms distribution normal

        if [ "$BANDWIDTH_LIMIT" -gt 0 ]; then
            echo "  Bandwidth limit: ${BANDWIDTH_LIMIT}Mbps"
            tc qdisc add dev $IFACE root netem delay ${LATENCY_MS}ms rate ${BANDWIDTH_LIMIT}mbit
        fi

        echo "Latency simulation active on interface $IFACE"
        tc qdisc show dev $IFACE
    fi
}

cat > /benchmark/scripts/collect-metrics.sh << 'INNEREOF'
#!/bin/bash

INTERVAL="${1:-1}"
DURATION="${2:-3600}"
OUTPUT="${3:-/benchmark/results/metrics_$(date +%Y%m%d_%H%M%S).csv}"

echo "timestamp,cpu_percent,mem_percent,disk_read_mb,disk_write_mb,net_rx_mb,net_tx_mb" > "$OUTPUT"

end_time=$(($(date +%s) + DURATION))

while [ $(date +%s) -lt $end_time ]; do
    timestamp=$(date +%s)

    cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    mem=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')

    disk_stats=$(cat /proc/diskstats | grep "nvme0n1 " | head -1)
    disk_read=$(echo "$disk_stats" | awk '{print $6 * 512 / 1024 / 1024}')
    disk_write=$(echo "$disk_stats" | awk '{print $10 * 512 / 1024 / 1024}')

    net_rx=$(cat /sys/class/net/eth0/statistics/rx_bytes | awk '{print $1 / 1024 / 1024}')
    net_tx=$(cat /sys/class/net/eth0/statistics/tx_bytes | awk '{print $1 / 1024 / 1024}')

    echo "$timestamp,$cpu,$mem,$disk_read,$disk_write,$net_rx,$net_tx" >> "$OUTPUT"

    sleep $INTERVAL
done
INNEREOF

chmod +x /benchmark/scripts/collect-metrics.sh

cat > /benchmark/scripts/verify-transfer.sh << 'INNEREOF'
#!/bin/bash

SOURCE_DIR="$1"
DEST_DIR="$2"

if [ -z "$SOURCE_DIR" ] || [ -z "$DEST_DIR" ]; then
    echo "Usage: $0 <source_dir> <dest_dir>"
    exit 1
fi

echo "Verifying transfer..."
echo "Source: $SOURCE_DIR"
echo "Dest: $DEST_DIR"

source_count=$(find "$SOURCE_DIR" -type f | wc -l)
dest_count=$(find "$DEST_DIR" -type f | wc -l)

echo "Source file count: $source_count"
echo "Dest file count: $dest_count"

if [ "$source_count" -eq "$dest_count" ]; then
    echo "✓ File counts match"
else
    echo "✗ File count mismatch!"
    exit 1
fi

source_size=$(du -sb "$SOURCE_DIR" | cut -f1)
dest_size=$(du -sb "$DEST_DIR" | cut -f1)

echo "Source size: $source_size bytes"
echo "Dest size: $dest_size bytes"

if [ "$source_size" -eq "$dest_size" ]; then
    echo "✓ Sizes match"
else
    echo "✗ Size mismatch!"
    exit 1
fi

echo "Running checksum comparison (sample of 100 files)..."
sample_files=$(find "$SOURCE_DIR" -type f | head -100)

mismatches=0
for file in $sample_files; do
    rel_path="${file#$SOURCE_DIR/}"
    dest_file="$DEST_DIR/$rel_path"

    if [ -f "$dest_file" ]; then
        source_md5=$(md5sum "$file" | cut -d' ' -f1)
        dest_md5=$(md5sum "$dest_file" | cut -d' ' -f1)

        if [ "$source_md5" != "$dest_md5" ]; then
            echo "✗ Checksum mismatch: $rel_path"
            mismatches=$((mismatches + 1))
        fi
    else
        echo "✗ Missing file: $rel_path"
        mismatches=$((mismatches + 1))
    fi
done

if [ $mismatches -eq 0 ]; then
    echo "✓ All sampled files verified"
else
    echo "✗ $mismatches files failed verification"
    exit 1
fi

echo ""
echo "Transfer verification complete!"
INNEREOF

chmod +x /benchmark/scripts/verify-transfer.sh

cat > /benchmark/scripts/latency-control.sh << 'INNEREOF'
#!/bin/bash

IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

case "$1" in
    show)
        echo "Current tc configuration on $IFACE:"
        tc qdisc show dev $IFACE
        ;;
    add)
        LATENCY="${2:-100}"
        echo "Adding ${LATENCY}ms latency to $IFACE..."
        tc qdisc add dev $IFACE root netem delay ${LATENCY}ms 10ms distribution normal
        ;;
    remove)
        echo "Removing latency simulation from $IFACE..."
        tc qdisc del dev $IFACE root 2>/dev/null || true
        ;;
    change)
        LATENCY="${2:-100}"
        echo "Changing latency to ${LATENCY}ms on $IFACE..."
        tc qdisc change dev $IFACE root netem delay ${LATENCY}ms 10ms distribution normal
        ;;
    *)
        echo "Usage: $0 {show|add <ms>|remove|change <ms>}"
        exit 1
        ;;
esac
INNEREOF

chmod +x /benchmark/scripts/latency-control.sh

if [ "$SIMULATE_LATENCY" = "true" ] || [ "$SIMULATE_LATENCY" = "True" ]; then
    setup_latency_simulation
fi

# Fix permissions so ec2-user can write (rsync/tar connect as ec2-user)
chown -R ec2-user:ec2-user /benchmark

echo "Destination setup complete. Ready to receive transfers."
