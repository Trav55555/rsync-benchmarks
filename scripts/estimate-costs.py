#!/usr/bin/env python3

import boto3
import json
from datetime import datetime

FALLBACK_EC2_PRICE = 0.34
FALLBACK_EBS_PRICE = 0.08
FALLBACK_S3_PRICE = 0.023
HOURS_PER_MONTH = 730
S3_RESULTS_SIZE_GB = 0.01
API_COST_ESTIMATE = 0.01

REGION_NAME_MAP = {
    "us-east-1": "US East (N. Virginia)",
    "us-east-2": "US East (Ohio)",
    "us-west-1": "US West (N. California)",
    "us-west-2": "US West (Oregon)",
    "eu-west-1": "EU (Ireland)",
    "eu-central-1": "EU (Frankfurt)",
    "ap-southeast-1": "Asia Pacific (Singapore)",
}

SPOT_DISCOUNT_RATE = 0.65
INSTANCE_COUNT = 2


def get_ec2_pricing(region="us-east-1", instance_type="c6i.2xlarge"):
    pricing_client = boto3.client("pricing", region_name="us-east-1")

    response = pricing_client.get_products(
        ServiceCode="AmazonEC2",
        Filters=[
            {"Type": "TERM_MATCH", "Field": "instanceType", "Value": instance_type},
            {
                "Type": "TERM_MATCH",
                "Field": "location",
                "Value": REGION_NAME_MAP.get(region, region),
            },
            {"Type": "TERM_MATCH", "Field": "tenancy", "Value": "Shared"},
            {"Type": "TERM_MATCH", "Field": "operatingSystem", "Value": "Linux"},
            {"Type": "TERM_MATCH", "Field": "preInstalledSw", "Value": "NA"},
            {"Type": "TERM_MATCH", "Field": "capacitystatus", "Value": "Used"},
        ],
        MaxResults=1,
    )

    if not response["PriceList"]:
        return None

    product = json.loads(response["PriceList"][0])
    on_demand = product["terms"]["OnDemand"]
    price_dimensions = list(on_demand.values())[0]["priceDimensions"]
    price_per_unit = list(price_dimensions.values())[0]["pricePerUnit"]["USD"]

    return float(price_per_unit)


def get_ebs_pricing(region="us-east-1", volume_type="gp3"):
    pricing_client = boto3.client("pricing", region_name="us-east-1")

    response = pricing_client.get_products(
        ServiceCode="AmazonEC2",
        Filters=[
            {"Type": "TERM_MATCH", "Field": "volumeApiName", "Value": volume_type},
            {
                "Type": "TERM_MATCH",
                "Field": "location",
                "Value": REGION_NAME_MAP.get(region, region),
            },
        ],
        MaxResults=1,
    )

    if not response["PriceList"]:
        return None

    product = json.loads(response["PriceList"][0])
    on_demand = product["terms"]["OnDemand"]
    price_dimensions = list(on_demand.values())[0]["priceDimensions"]
    price_per_unit = list(price_dimensions.values())[0]["pricePerUnit"]["USD"]

    return float(price_per_unit)


def get_s3_pricing(region="us-east-1"):
    pricing_client = boto3.client("pricing", region_name="us-east-1")

    response = pricing_client.get_products(
        ServiceCode="AmazonS3",
        Filters=[
            {
                "Type": "TERM_MATCH",
                "Field": "location",
                "Value": REGION_NAME_MAP.get(region, region),
            },
            {"Type": "TERM_MATCH", "Field": "storageClass", "Value": "General Purpose"},
        ],
        MaxResults=1,
    )

    if not response["PriceList"]:
        return None

    product = json.loads(response["PriceList"][0])
    on_demand = product["terms"]["OnDemand"]
    price_dimensions = list(on_demand.values())[0]["priceDimensions"]
    price_per_unit = list(price_dimensions.values())[0]["pricePerUnit"]["USD"]

    return float(price_per_unit)


def calculate_benchmark_costs(
    region="us-east-1",
    source_instance="c6i.2xlarge",
    dest_instance="c6i.2xlarge",
    volume_size_gb=100,
    duration_hours=2,
    data_transfer_gb=75,
    use_spot=False,
):
    print(f"Querying AWS Pricing APIs for {region}...")
    print("-" * 60)

    ec2_price = FALLBACK_EC2_PRICE
    ebs_price = FALLBACK_EBS_PRICE
    s3_price = FALLBACK_S3_PRICE
    pricing_source = "Fallback"

    try:
        fetched_ec2_price = get_ec2_pricing(region, source_instance)
        if fetched_ec2_price:
            ec2_price = fetched_ec2_price
            print(f"✓ EC2 {source_instance}: ${ec2_price:.4f}/hour")
            pricing_source = "AWS API"
        else:
            print(
                f"✗ Could not fetch EC2 pricing, using fallback ${FALLBACK_EC2_PRICE}/hour"
            )
    except Exception as e:
        print(f"✗ Error fetching EC2 pricing: {e}")
        print(f"  Using fallback ${FALLBACK_EC2_PRICE}/hour")

    try:
        fetched_ebs_price = get_ebs_pricing(region, "gp3")
        if fetched_ebs_price:
            ebs_price = fetched_ebs_price
            print(f"✓ EBS gp3: ${ebs_price:.6f}/GB-month")
        else:
            print(
                f"✗ Could not fetch EBS pricing, using fallback ${FALLBACK_EBS_PRICE}/GB-month"
            )
    except Exception as e:
        print(f"✗ Error fetching EBS pricing: {e}")
        print(f"  Using fallback ${FALLBACK_EBS_PRICE}/GB-month")

    try:
        fetched_s3_price = get_s3_pricing(region)
        if fetched_s3_price:
            s3_price = fetched_s3_price
            print(f"✓ S3 Standard: ${s3_price:.6f}/GB-month")
        else:
            print(
                f"✗ Could not fetch S3 pricing, using fallback ${FALLBACK_S3_PRICE}/GB-month"
            )
    except Exception as e:
        print(f"✗ Error fetching S3 pricing: {e}")
        print(f"  Using fallback ${FALLBACK_S3_PRICE}/GB-month")

    spot_price = ec2_price * (1 - SPOT_DISCOUNT_RATE)

    print(
        f"✓ Spot pricing (est.): ${spot_price:.4f}/hour ({SPOT_DISCOUNT_RATE * 100:.0f}% discount)"
    )
    print("-" * 60)

    instance_price = spot_price if use_spot else ec2_price

    compute_cost = instance_price * duration_hours * INSTANCE_COUNT

    storage_cost = (
        ebs_price * volume_size_gb * INSTANCE_COUNT * (duration_hours / HOURS_PER_MONTH)
    )

    transfer_cost = 0.0

    s3_cost = s3_price * S3_RESULTS_SIZE_GB * (duration_hours / HOURS_PER_MONTH)

    api_cost = API_COST_ESTIMATE

    total = compute_cost + storage_cost + transfer_cost + s3_cost + api_cost

    print(
        f"\nCOST BREAKDOWN ({duration_hours} hours, {'Spot' if use_spot else 'On-Demand'})"
    )
    print("=" * 60)
    print(f"{'Compute (2× ' + source_instance + ')':<40} ${compute_cost:>8.2f}")
    print(
        f"{'Storage (2× ' + str(volume_size_gb) + 'GB gp3)':<40} ${storage_cost:>8.2f}"
    )
    print(f"{'Data Transfer (same AZ)':<40} ${transfer_cost:>8.2f}")
    print(f"{'S3 Storage':<40} ${s3_cost:>8.2f}")
    print(f"{'API Requests':<40} ${api_cost:>8.2f}")
    print("-" * 60)
    print(f"{'TOTAL ESTIMATED COST':<40} ${total:>8.2f}")
    print("=" * 60)

    print(f"\nSCENARIO COMPARISON")
    print("-" * 60)

    scenarios = [
        ("Quick test (1 hour)", 1),
        ("Standard benchmark (2 hours)", 2),
        ("Extended testing (4 hours)", 4),
        ("Full day (8 hours)", 8),
    ]

    for name, hours in scenarios:
        od_compute = ec2_price * hours * INSTANCE_COUNT
        spot_compute = spot_price * hours * INSTANCE_COUNT
        od_storage = (
            ebs_price * volume_size_gb * INSTANCE_COUNT * (hours / HOURS_PER_MONTH)
        )

        od_total = od_compute + od_storage + api_cost
        spot_total = spot_compute + od_storage + api_cost

        print(f"{name:<35} On-Demand: ${od_total:>6.2f}  Spot: ${spot_total:>6.2f}")

    print("-" * 60)

    return {
        "region": region,
        "instance_type": source_instance,
        "duration_hours": duration_hours,
        "use_spot": use_spot,
        "compute_cost": compute_cost,
        "storage_cost": storage_cost,
        "transfer_cost": transfer_cost,
        "s3_cost": s3_cost,
        "api_cost": api_cost,
        "total": total,
        "pricing_source": pricing_source,
    }


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Estimate AWS costs for rsync benchmarks"
    )
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--instance", default="c6i.2xlarge", help="EC2 instance type")
    parser.add_argument("--duration", type=int, default=2, help="Duration in hours")
    parser.add_argument(
        "--volume-size", type=int, default=100, help="EBS volume size in GB"
    )
    parser.add_argument("--spot", action="store_true", help="Use Spot instance pricing")

    args = parser.parse_args()

    print("=" * 60)
    print("AWS BENCHMARK COST ESTIMATOR")
    print("=" * 60)
    print(f"Configuration: {args.instance} in {args.region}")
    print(f"Duration: {args.duration} hours")
    print(f"Storage: {args.volume_size} GB gp3 per instance")
    print(f"Pricing: {'Spot' if args.spot else 'On-Demand'}")
    print("=" * 60)

    try:
        costs = calculate_benchmark_costs(
            region=args.region,
            source_instance=args.instance,
            duration_hours=args.duration,
            volume_size_gb=args.volume_size,
            use_spot=args.spot,
        )

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"cost_estimate_{timestamp}.json"

        with open(filename, "w") as f:
            json.dump(costs, f, indent=2)

        print(f"\n✓ Cost estimate saved to: {filename}")

    except Exception as e:
        print(f"\n✗ Error: {e}")
        print("\nNote: AWS credentials required. Configure with:")
        print("  aws configure")
        print("or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY")
        return 1

    return 0


if __name__ == "__main__":
    exit(main())
