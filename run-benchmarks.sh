#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

show_usage() {
    cat << EOF
Rsync Benchmark Orchestrator

Usage: $0 <command> [options]

Commands:
    setup           Initialize Terraform and create infrastructure
    deploy          Deploy benchmark environment to AWS
    run             Run all benchmarks (requires deployed environment)
    collect         Collect and download results from S3
    analyze         Analyze results and generate report
    destroy         Tear down AWS infrastructure
    full            Run complete workflow: setup → deploy → run → collect → analyze

Options:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose output

Examples:
    $0 setup                    # Initialize Terraform
    $0 deploy                   # Create AWS resources
    $0 run                      # Execute benchmarks
    $0 collect                  # Download results
    $0 analyze                  # Generate analysis report
    $0 destroy                  # Clean up AWS resources
    $0 full                     # Run everything end-to-end

EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

cmd_setup() {
    log "Initializing Terraform..."
    cd terraform
    terraform init
    log "Terraform initialized. Edit terraform/terraform.tfvars to customize settings."
}

cmd_deploy() {
    log "Deploying benchmark environment..."
    cd terraform
    
    if [ ! -f .terraform/terraform.tfstate ]; then
        log "Running terraform init first..."
        terraform init
    fi
    
    log "Creating infrastructure (this may take 5-10 minutes)..."
    terraform apply -auto-approve
    
    log "Deployment complete!"
    terraform output
}

cmd_run() {
    log "Running benchmarks..."
    
    cd terraform
    SOURCE_IP=$(terraform output -raw source_public_ip)
    DEST_IP=$(terraform output -raw destination_public_ip)
    BUCKET=$(terraform output -raw results_bucket)
    KEY_PATH=$(terraform output -raw ssh_command_source | grep -o '\-i [^ ]*' | cut -d' ' -f2)
    
    log "Source IP: $SOURCE_IP"
    log "Destination IP: $DEST_IP"
    log "Results bucket: $BUCKET"
    
    log "Waiting for instances to be ready..."
    sleep 30
    
    log "Generating test data on source..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo /benchmark/scripts/generate-test-data.sh small 100000 4"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo /benchmark/scripts/generate-test-data.sh large 10"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo /benchmark/scripts/generate-test-data.sh mixed 5 1 10000 4"
    
    log "Running small file benchmarks..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo DEST_IP=$DEST_IP /benchmark/scripts/benchmark-rsync.sh $DEST_IP /benchmark/data/small_100000_files"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo DEST_IP=$DEST_IP /benchmark/scripts/benchmark-tar-ssh.sh $DEST_IP /benchmark/data/small_100000_files"
    
    log "Running large file benchmarks..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo DEST_IP=$DEST_IP /benchmark/scripts/benchmark-rsync.sh $DEST_IP /benchmark/data/large_10gb"
    
    log "Running parallelization benchmarks..."
    for p in 1 2 4 8; do
        log "Testing parallelism=$p..."
        ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo DEST_IP=$DEST_IP /benchmark/scripts/benchmark-parallel.sh $DEST_IP /benchmark/data/small_100000_files $p"
    done
    
    log "Uploading results to S3..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo S3_BUCKET=$BUCKET /benchmark/scripts/upload-results.sh $BUCKET"
    
    log "Benchmarks complete!"
}

cmd_collect() {
    log "Collecting results from S3..."
    
    cd terraform
    BUCKET=$(terraform output -raw results_bucket)
    
    mkdir -p ../results
    
    log "Downloading results from s3://$BUCKET/..."
    aws s3 sync "s3://$BUCKET/" ../results/ --delete
    
    log "Results downloaded to ./results/"
    ls -la ../results/
}

cmd_analyze() {
    log "Analyzing benchmark results..."
    
    if [ ! -d results ] || [ -z "$(ls -A results 2>/dev/null)" ]; then
        error "No results found. Run 'collect' first or check the results/ directory."
    fi
    
    python3 scripts/analyze-results.py results/
}

cmd_destroy() {
    log "Destroying benchmark environment..."
    
    read -p "Are you sure? This will delete all AWS resources. [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Aborted."
        exit 0
    fi
    
    cd terraform
    terraform destroy -auto-approve
    
    log "Infrastructure destroyed."
}

cmd_full() {
    log "Running full benchmark workflow..."
    
    cmd_setup
    cmd_deploy
    cmd_run
    cmd_collect
    cmd_analyze
    
    log "Full workflow complete!"
}

main() {
    case "${1:-}" in
        setup)
            cmd_setup
            ;;
        deploy)
            cmd_deploy
            ;;
        run)
            cmd_run
            ;;
        collect)
            cmd_collect
            ;;
        analyze)
            cmd_analyze
            ;;
        destroy)
            cmd_destroy
            ;;
        full)
            cmd_full
            ;;
        -h|--help|help)
            show_usage
            exit 0
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
