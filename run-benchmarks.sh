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
    deploy-cross-az Deploy with instances in different AZs
    run             Run all benchmarks (requires deployed environment)
    collect         Collect and download results from S3
    analyze         Analyze results and generate report
    destroy         Tear down AWS infrastructure
    full            Run complete workflow: setup → deploy → run → collect → analyze
    latency-test    Deploy with simulated latency for testing high-RTT scenarios

Options:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose output

Examples:
    $0 setup                    # Initialize Terraform
    $0 deploy                   # Create AWS resources (same AZ)
    $0 deploy-cross-az          # Create AWS resources (cross-AZ)
    $0 latency-test 100         # Deploy with 100ms simulated latency
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
    log "Deploying benchmark environment (same AZ)..."
    cd terraform
    
    if [ ! -f .terraform/terraform.tfstate ]; then
        log "Running terraform init first..."
        terraform init
    fi
    
    log "Creating infrastructure (this may take 5-10 minutes)..."
    terraform apply -auto-approve \
        -var="deploy_cross_az=false" \
        -var="simulate_latency=false"
    
    log "Deployment complete!"
    terraform output
}

cmd_deploy_cross_az() {
    log "Deploying benchmark environment (CROSS-AZ)..."
    cd terraform
    
    if [ ! -f .terraform/terraform.tfstate ]; then
        log "Running terraform init first..."
        terraform init
    fi
    
    log "Creating infrastructure across availability zones..."
    terraform apply -auto-approve \
        -var="deploy_cross_az=true" \
        -var="simulate_latency=false"
    
    log "Cross-AZ deployment complete!"
    log ""
    log "Source and destination are in different AZs."
    log "This adds ~1-2ms latency between instances (realistic for cross-AZ)."
    terraform output
}

cmd_latency_test() {
    local latency_ms="${1:-100}"
    log "Deploying with simulated latency: ${latency_ms}ms..."
    cd terraform
    
    if [ ! -f .terraform/terraform.tfstate ]; then
        log "Running terraform init first..."
        terraform init
    fi
    
    log "Creating infrastructure with ${latency_ms}ms latency simulation..."
    terraform apply -auto-approve \
        -var="deploy_cross_az=false" \
        -var="simulate_latency=true" \
        -var="latency_ms=$latency_ms"
    
    log "Latency simulation deployment complete!"
    log ""
    log "Network latency of ${latency_ms}ms is simulated on the destination."
    log "This tests how tools perform under high-RTT conditions."
    terraform output
}

cmd_run() {
    log "Running benchmarks..."
    
    cd terraform
    SOURCE_IP=$(terraform output -raw source_public_ip)
    DEST_IP=$(terraform output -raw destination_public_ip)
    BUCKET=$(terraform output -raw results_bucket)
    KEY_PATH=$(terraform output -raw ssh_command_source | grep -o '\-i [^ ]*' | cut -d' ' -f2)
    CROSS_AZ=$(terraform output -raw cross_az_deployed)
    LATENCY_SIM=$(terraform output -raw latency_simulation_enabled)
    
    log "Source IP: $SOURCE_IP"
    log "Destination IP: $DEST_IP"
    log "Results bucket: $BUCKET"
    
    if [ "$CROSS_AZ" = "true" ]; then
        SOURCE_AZ=$(terraform output -raw source_az)
        DEST_AZ=$(terraform output -raw destination_az)
        log "Cross-AZ deployment: Source in $SOURCE_AZ, Destination in $DEST_AZ"
    fi
    
    if [ "$LATENCY_SIM" = "true" ]; then
        SIMULATED_LATENCY=$(terraform output -raw simulated_latency_ms)
        log "Latency simulation: ${SIMULATED_LATENCY}ms"
    fi
    
    log "Waiting for instances to be ready..."
    sleep 30
    
    log "Generating test data on source..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo /benchmark/scripts/generate-test-data.sh all"
    
    log "Running comprehensive benchmark suite..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@$SOURCE_IP "sudo DEST_IP=$DEST_IP S3_BUCKET=$BUCKET /benchmark/scripts/run-all-benchmarks.sh $DEST_IP"
    
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
        deploy-cross-az)
            cmd_deploy_cross_az
            ;;
        latency-test)
            cmd_latency_test "${2:-100}"
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
