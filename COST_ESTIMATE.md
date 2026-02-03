# AWS Cost Estimate: Rsync Benchmarks

## Infrastructure Overview

| Resource | Configuration | Quantity |
|----------|--------------|----------|
| EC2 Source | c6i.2xlarge (8 vCPU, 16 GB) | 1 |
| EC2 Destination | c6i.2xlarge (8 vCPU, 16 GB) | 1 |
| EBS Volumes | 100 GB gp3 per instance | 2 |
| S3 Bucket | Results storage | 1 |
| Data Transfer | Cross-AZ or same VPC | Variable |

## Cost Breakdown (us-east-1)

### Compute (EC2)

**c6i.2xlarge On-Demand Pricing:** ~$0.34/hour

| Scenario | Duration | Cost |
|----------|----------|------|
| Quick test (1 hour) | 1 hour × 2 instances | **$0.68** |
| Standard benchmark (4 hours) | 4 hours × 2 instances | **$2.72** |
| Extended testing (8 hours) | 8 hours × 2 instances | **$5.44** |
| Full day (24 hours) | 24 hours × 2 instances | **$16.32** |

**Spot Instance Alternative:** ~$0.12/hour (65% savings)
- Quick test: **$0.24**
- Standard benchmark: **$0.96**
- Extended testing: **$1.92**

### Storage (EBS)

**gp3 Volume Pricing:** $0.08/GB-month

| Configuration | Size | Monthly Cost | 1 Day Cost |
|--------------|------|--------------|------------|
| 100 GB gp3 | 200 GB total | $16.00 | **$0.53** |

**IOPS:** 3,000 included, no extra charge

### Data Transfer

**Same VPC/Subnet:** $0 (free)
**Cross-AZ:** $0.01/GB

Estimated data transferred during benchmarks:
- Small files test: ~400 MB × multiple runs = ~5 GB
- Large file test: ~10 GB × multiple runs = ~50 GB
- Mixed workload: ~20 GB
- **Total: ~75 GB**

| Scenario | Data Transfer | Cost |
|----------|--------------|------|
| Same subnet | 75 GB | **$0** |
| Cross-AZ | 75 GB | **$0.75** |

### S3 Storage

**S3 Standard:** $0.023/GB-month

Results data: ~10 MB of JSON files
- Monthly: Negligible
- 1 day: **~$0.01**

**S3 API Requests:** 
- PUT requests: $0.005 per 1,000 requests
- Estimated: <100 requests = **$0.01**

### Networking (VPC)

- VPC: Free
- Internet Gateway: Free (data transfer charges apply if using public IPs)
- NAT Gateway: Not used (saves ~$32/month)

## Total Cost Estimates

### On-Demand Pricing (Recommended for reliability)

| Duration | Compute | Storage | Data Transfer | S3 | **Total** |
|----------|---------|---------|---------------|-----|-----------|
| 1 hour | $0.68 | $0.02 | $0 | $0.01 | **~$0.71** |
| 4 hours | $2.72 | $0.07 | $0 | $0.01 | **~$2.80** |
| 8 hours | $5.44 | $0.14 | $0 | $0.01 | **~$5.59** |
| 24 hours | $16.32 | $0.53 | $0 | $0.01 | **~$16.86** |

### Spot Instance Pricing (Cost-optimized)

| Duration | Compute | Storage | Data Transfer | S3 | **Total** |
|----------|---------|---------|---------------|-----|-----------|
| 1 hour | $0.24 | $0.02 | $0 | $0.01 | **~$0.27** |
| 4 hours | $0.96 | $0.07 | $0 | $0.01 | **~$1.04** |
| 8 hours | $1.92 | $0.14 | $0 | $0.01 | **~$2.07** |

## Cost Optimization Tips

1. **Use Spot Instances** for 65% savings (if interruption risk is acceptable)
2. **Terminate immediately** after benchmarks complete
3. **Use same subnet** to avoid cross-AZ data transfer costs
4. **Delete S3 bucket** after downloading results
5. **Consider Reserved Instances** if running benchmarks regularly

## Realistic Single Run Cost

For a complete benchmark run (setup + benchmarks + teardown):

- **Time:** ~2 hours total
- **Compute:** $1.36 (on-demand) or $0.48 (spot)
- **Storage:** $0.04
- **Data Transfer:** $0
- **S3:** $0.01

### **Total: ~$1.40 (on-demand) or ~$0.50 (spot)**

## Cost Alerts & Budgeting

Recommended AWS Budget setup:
- **Alert at $5:** Early warning
- **Alert at $10:** Investigation needed
- **Alert at $25:** Stop all resources

## Free Tier Eligibility

If you have AWS Free Tier:
- **750 hours/month** of t2/t3.micro (not applicable - need larger instances)
- **30 GB EBS** storage (partial coverage)
- **5 GB S3** storage (fully covered)
- **Data transfer:** Not covered

**Note:** The c6i.2xlarge instances required for meaningful benchmarks are **not** covered by Free Tier.

## Summary

| Approach | Estimated Cost |
|----------|---------------|
| **Single benchmark run (on-demand)** | **$1-3** |
| **Single benchmark run (spot)** | **$0.50-1** |
| **Development/testing (multiple runs)** | **$5-15** |
| **Comprehensive testing (full day)** | **$15-20** |

**Recommendation:** Budget **$5-10** for initial setup and testing, then **$1-3 per benchmark run** thereafter.
