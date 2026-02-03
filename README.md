# Rsync Benchmarks

Controlled benchmarks comparing file transfer tools on AWS EC2. Produced data for the [Rsync or Rswim](../blogs/rsync-or-rswim/) blog post.

## Results (2026-02-03)

**Environment:** 2× c6i.2xlarge (8 vCPU, 15 GB RAM), same-AZ us-east-1a, xfs on gp3, rsync 3.4.0.
**Network ceiling:** 4,967 Mbps (iperf3, median of 3 runs).
**Methodology:** 5 runs per test, bilateral cache drops, fresh destination per run, no warm-up, transfer verification. Medians reported.

### Mixed workload (325 MB)

JSON records, logs, source code, binary assets.

| Tool | Median | Throughput | vs fastest |
|------|-------:|----------:|-----------:|
| `rsync -az` | 2.42s | 1.13 Gbps | — |
| `rsync -a` | 2.46s | 1.11 Gbps | 1.01× slower |
| `tar \| ssh` | 2.51s | 1.08 Gbps | 1.04× slower |
| `tar \| zstd \| ssh` | 2.52s | 1.08 Gbps | 1.04× slower |
| parallel rsync (2×) | 2.00s | 1.36 Gbps | 1.21× faster |
| parallel rsync (4×) | 1.92s | 1.42 Gbps | 1.26× faster |

### Small files (10,000 × 4 KB, 39 MB)

Random binary data, worst case for compression.

| Tool | Median | Throughput |
|------|-------:|----------:|
| `tar \| zstd \| ssh` | 6.07s | 54.4 Mbps |
| `tar \| ssh` | 6.11s | 54.1 Mbps |
| `rsync -a` | 6.22s | 53.1 Mbps |

### Key findings

1. **On fast networks, tool choice barely matters for bulk data.** All single-stream methods within 4%. Bottleneck is single-core SSH encryption at ~22% of 5 Gbps.
2. **Compression is a wash at high bandwidth.** `rsync -az` = `rsync -a` when the network is faster than zstd.
3. **Parallel rsync gives real speedup.** 4 streams → 1.28× by distributing SSH encryption across cores. Diminishing returns beyond 4.
4. **Small files are the real killer.** 54 Mbps on 5 Gbps = 1% utilization. Per-file metadata overhead dominates. Tar helps marginally (150 ms); the problem is architectural.

## Methodology

The benchmark runner (`scripts/rigorous-bench.sh`) addresses common pitfalls in transfer benchmarks:

| Issue | Fix |
|-------|-----|
| Destination warm from prior run | Fresh `rm -rf && mkdir` before every run |
| Source-only cache drops | Bilateral: `echo 3 > /proc/sys/vm/drop_caches` on both machines |
| Warm-up run populates destination | No warm-up (unnecessary for I/O-bound workloads) |
| Inconsistent SSH overhead | SSH ControlMaster for connection multiplexing |
| No network baseline | iperf3 ceiling measurement before benchmarks |
| Unverified transfers | `du -sb` comparison after each run, 1% tolerance |
| bc output produces invalid JSON | All math via Python `json.dumps()` |
| 3 runs too few for outlier detection | 5 runs, report median + trimmed mean |

## Repository structure

```
rsync-benchmarks/
├── scripts/
│   ├── rigorous-bench.sh      # Main benchmark runner (v2, rigorous)
│   └── analyze-results.py     # Results analysis + blog-ready tables
├── terraform/
│   ├── main.tf                # 2× EC2, VPC, S3, IAM
│   ├── variables.tf
│   └── scripts/
│       ├── setup-source.sh    # Source instance provisioning
│       └── setup-destination.sh
├── results/
│   ├── suite_20260203_195147/ # Raw JSON results (per-run + stats)
│   ├── chart_mixed_throughput.png
│   ├── chart_small_files.png
│   └── chart_variance.png
├── run-benchmarks.sh          # Orchestration wrapper
└── COST_ESTIMATE.md
```

## Running

```bash
# 1. Deploy infrastructure
cd terraform
AWS_PROFILE=your-profile terraform apply

# 2. Fix destination permissions (setup runs as root, transfers run as ec2-user)
ssh ec2-user@<dest_ip> "sudo chown -R ec2-user:ec2-user /benchmark"

# 3. Copy benchmark script to source
scp scripts/rigorous-bench.sh ec2-user@<source_ip>:/benchmark/scripts/

# 4. Run (as root for cache drops, ~5 min)
ssh ec2-user@<source_ip> "sudo /benchmark/scripts/rigorous-bench.sh <dest_private_ip>"

# 5. Collect results
scp -r ec2-user@<source_ip>:/benchmark/results/suite_*/ results/

# 6. Analyze
python3 scripts/analyze-results.py results/suite_*/

# 7. Destroy (instances cost ~$0.68/hr combined)
AWS_PROFILE=your-profile terraform destroy
```

## Results format

Each benchmark produces per-run JSON and aggregate stats:

```json
{
  "benchmark": "mixed_rsync_default",
  "data_profile": "mixed",
  "valid_runs": 5,
  "total_runs": 5,
  "duration_s": {
    "median": 2.458,
    "mean": 2.586,
    "trimmed_mean": 2.461,
    "stdev": 0.515,
    "min": 2.095,
    "max": 3.455,
    "cv_pct": 19.9
  },
  "effective_throughput_mbps": {
    "median": 1108.99,
    "trimmed_mean": 1108.85
  },
  "src_bytes": 340853565,
  "all_verified": true
}
```

## Cost

~$1.50 per full run (2× c6i.2xlarge on-demand for ~1 hour including setup). Destroy immediately after.

## Requirements

- AWS CLI with admin credentials (SSO or IAM)
- Terraform >= 1.0
- Python 3.8+ (matplotlib for charts)
- SSH key pair at `~/.ssh/id_rsa`
