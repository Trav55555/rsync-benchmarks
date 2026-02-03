# Rsync Benchmarks

AWS infrastructure and automation for benchmarking file transfer tools (rsync, tar+ssh, aria2c, etc.) with real performance data.

## Overview

This repository provides:
- **Terraform infrastructure** for AWS EC2 instances (source + destination)
- **Automated benchmark scripts** for various transfer scenarios
- **Data collection** to S3 with analysis tools
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

## Benchmarks

### Test Scenarios

1. **Small Files** (100K × 4KB = ~400MB)
   - Metadata overhead dominates
   - Tests: rsync variants, tar+ssh with different compression

2. **Large Files** (10GB single file)
   - Throughput dominates
   - Tests: rsync with/without resume, multi-connection tools

3. **Parallelization** (1×, 2×, 4×, 8×, 16×)
   - Tests overhead of parallel streams
   - Measures diminishing returns

4. **Mixed Workload**
   - Combination of large and small files
   - Tests real-world scenarios

### Tools Tested

- `rsync` (various flags: -a, -az, --partial, --checksum, --delete)
- `tar + ssh` (plain, gzip, zstd, lz4)
- Parallel rsync variants (fpsync, parsyncfp2)
- `aria2c` (multi-connection)

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
│       ├── setup-source.sh      # Source instance setup
│       └── setup-destination.sh # Destination instance setup
├── scripts/
│   └── analyze-results.py   # Results analysis
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
```

## Security Notes

- **Restrict SSH access** to your IP only (not 0.0.0.0/0)
- **Use dedicated SSH keys** for benchmark instances
- **Terminate resources** immediately after use
- **S3 bucket** is private by default with versioning enabled

## Results Format

Benchmark results are saved as JSON:

```json
{
  "benchmark": "rsync_default",
  "command": "rsync -a /benchmark/data/...",
  "duration_seconds": 45.23,
  "bytes_transferred": 419430400,
  "exit_code": 0,
  "timestamp": "2025-01-15T10:30:00Z"
}
```

## Analysis Output

The analysis script generates:
- Summary tables for each benchmark type
- Comparison tables formatted for blog posts
- Relative speed comparisons
- Throughput calculations

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
