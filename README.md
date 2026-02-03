# Rsync Benchmarks

AWS infrastructure and automation for benchmarking file transfer tools (rsync, tar+ssh, aria2c, rclone, etc.) with real performance data.

## Overview

This repository provides:
- **Terraform infrastructure** for AWS EC2 instances (source + destination)
- **Automated benchmark scripts** for various transfer scenarios
- **Realistic test data** (compressible, incompressible, mixed workloads)
- **Statistical rigor** (multiple runs, warm-up, stddev calculation)
- **Data collection** to S3 with comprehensive analysis tools
- **Cross-AZ deployment** for testing real-world network latency
- **Latency simulation** (tc/netem) for testing high-RTT scenarios
- **Cost estimates** and optimization guidance

## Quick Start

```bash
# 1. Clone and setup
git clone <repo-url>
cd rsync-benchmarks
./run-benchmarks.sh setup

# 2. Configure (optional)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars to customize instance types, SSH keys, etc.

# 3. Deploy infrastructure
./run-benchmarks.sh deploy

# 4. Run benchmarks
./run-benchmarks.sh run

# 5. Collect results
./run-benchmarks.sh collect

# 6. Analyze
./run-benchmarks.sh analyze

# 7. Clean up
./run-benchmarks.sh destroy
```

Or run everything in one command:
```bash
./run-benchmarks.sh full
```

## Infrastructure

### Architecture

```
┌─────────────────┐         ┌─────────────────┐
│  Source EC2     │────────▶│ Destination EC2 │
│  (c6i.2xlarge)  │  SSH    │  (c6i.2xlarge)  │
│                 │         │                 │
│  Test data      │         │  Receives data  │
│  Benchmarks     │         │  Metrics        │
└────────┬────────┘         └────────┬────────┘
         │                           │
         └───────────┬───────────────┘
                     │
              ┌──────▼──────┐
              │  S3 Bucket  │
              │  Results    │
              └─────────────┘
```

### Resources Created

- **2× EC2 instances** (c6i.2xlarge by default) with gp3 SSD storage
- **VPC with public subnet** and Internet Gateway
- **Security group** allowing SSH and inter-instance traffic
- **IAM role** for S3 access
- **S3 bucket** for benchmark results

### Cross-AZ Deployment

Deploy instances in different availability zones to test real-world network conditions:

```bash
./run-benchmarks.sh deploy-cross-az
```

This adds ~1-2ms of real network latency between instances, simulating production scenarios where source and destination are in different AZs.

### Latency Simulation

Test how tools perform under high-latency conditions (e.g., cross-region transfers):

```bash
# Deploy with 100ms simulated latency
./run-benchmarks.sh latency-test 100

# Deploy with 200ms simulated latency
./run-benchmarks.sh latency-test 200
```

Uses Linux tc/netem to simulate network latency on the destination instance. This is useful for testing:
- How rsync performs over high-RTT links
- Whether parallel transfers help with latency
- TCP window scaling behavior

## Benchmarks

### Test Data Types

1. **Incompressible Data** (random binary)
   - Worst case for compression algorithms
   - Tests raw throughput

2. **Compressible Data** (repetitive text, logs)
   - Best case for compression
   - Tests compression efficiency

3. **Source Code** (Python-like files)
   - Realistic code repository simulation
   - Tests delta algorithm effectiveness

4. **Large Files** (1-10GB, varying compressibility)
   - Single file throughput
   - Resume capability testing

5. **Mixed Realistic Workload**
   - Database-like JSON files
   - Log files (highly compressible)
   - Binary assets (incompressible)
   - Source code tree
   - Tests real-world scenarios

6. **Metadata Test Files**
   - ACLs, extended attributes
   - Symlinks and hard links
   - Sparse files
   - Tests metadata preservation

### Benchmark Types

1. **Main Benchmark Suite** (`benchmark-runner.sh`)
   - Multiple runs (default: 3) with warm-up
   - Statistical analysis (mean, stddev, CV%)
   - CPU/memory profiling
   - Throughput calculation
   - Tools: rsync, tar+ssh variants

2. **Resume/Partial Transfer Tests** (`benchmark-resume.sh`)
   - Interrupts transfer after 5 seconds
   - Measures resume time
   - Tests `--partial` and `--append-verify`

3. **Parallel Transfer Tests** (`benchmark-parallel.sh`)
   - Tests 1×, 2×, 4×, 8× parallel streams
   - Shards data across multiple rsync processes
   - Includes fpsync testing
   - Calculates speedup and efficiency

4. **Additional Tools** (`benchmark-tools.sh`)
   - aria2c (multi-connection HTTP)
   - rclone (cloud-optimized)
   - Tests tools mentioned in blog post

### Statistical Rigor

- **Warm-up runs**: 1 run before measurement (excluded from stats)
- **Multiple iterations**: Default 3 runs per configuration
- **Metrics collected**:
  - Duration (mean ± stddev)
  - Coefficient of variation (CV%)
  - User/system CPU time
  - Memory usage (max RSS)
  - Context switches
  - I/O wait
  - Throughput (Mbps)
- **Cache management**: Dropped between runs for consistency

## Cost

**Estimated cost per benchmark run: $1-3 (on-demand) or $0.50-1 (spot)**

See [COST_ESTIMATE.md](COST_ESTIMATE.md) for detailed breakdown.

## Repository Structure

```
rsync-benchmarks/
├── terraform/
│   ├── main.tf              # Infrastructure definition
│   ├── variables.tf         # Configurable variables
│   └── scripts/
│       ├── setup-source.sh      # Source instance setup + benchmark scripts
│       └── setup-destination.sh # Destination instance setup
├── scripts/
│   ├── analyze-results.py   # Results analysis with statistics
│   └── estimate-costs.py    # Live AWS pricing queries
├── run-benchmarks.sh        # Main orchestration script
├── COST_ESTIMATE.md         # Detailed cost breakdown
└── README.md               # This file
```

## Requirements

- AWS CLI configured with credentials
- Terraform >= 1.0
- Python 3.8+
- SSH key pair (default: ~/.ssh/id_rsa)

## Configuration

Edit `terraform/terraform.tfvars`:

```hcl
aws_region              = "us-east-1"
source_instance_type    = "c6i.2xlarge"  # 8 vCPU, 16 GB
destination_instance_type = "c6i.2xlarge"
source_volume_size      = 100  # GB
destination_volume_size = 100  # GB
public_key_path         = "~/.ssh/id_rsa.pub"
private_key_path        = "~/.ssh/id_rsa"
allowed_ssh_cidr        = "YOUR_IP/32"  # Restrict for security

# Cross-AZ and latency simulation options
deploy_cross_az         = false  # Deploy instances in different AZs
simulate_latency        = false  # Enable latency simulation
latency_ms              = 100    # Simulated latency in milliseconds
bandwidth_limit_mbps    = 0      # Bandwidth limit (0 = unlimited)
```

## Security Notes

- **Restrict SSH access** to your IP only (not 0.0.0.0/0)
- **Use dedicated SSH keys** for benchmark instances
- **Terminate resources** immediately after use
- **S3 bucket** is private by default with versioning enabled

## Results Format

Benchmark results include detailed statistics:

```json
{
  "benchmark": "rsync_default",
  "runs": 3,
  "duration_seconds": {
    "mean": 45.23,
    "stdev": 2.14,
    "min": 42.89,
    "max": 47.56,
    "cv_percent": 4.7
  },
  "bytes_transferred": 419430400,
  "throughput_mbps": 74.2,
  "user_time_seconds": "12.34",
  "system_time_seconds": "8.91",
  "max_rss_kb": 45632,
  "timestamp": "2025-01-15T10:30:00Z"
}
```

## Analysis Output

The analysis script generates:
- Summary tables with mean ± stddev
- Coefficient of variation (CV%) for consistency
- Throughput calculations
- Parallel scaling analysis (speedup, efficiency)
- Resume test results
- Blog-ready comparison tables

## Troubleshooting

**SSH connection refused:**
- Wait 1-2 minutes after deploy for instances to boot
- Check security group allows your IP

**Benchmarks fail:**
- Verify destination instance is running
- Check `/var/log/cloud-init-output.log` on instances

**High costs:**
- Use Spot instances (edit variables.tf)
- Reduce instance size for testing (t3.large)
- Terminate immediately after use

## Contributing

Add new benchmarks by editing:
- `terraform/scripts/setup-source.sh` - add test scenarios
- `scripts/analyze-results.py` - add analysis functions

## License

MIT
