variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "benchmark"
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "rsync-benchmarks"
}

variable "source_instance_type" {
  description = "EC2 instance type for source server (c6i.2xlarge = 8 vCPU, 16 GB, good network performance)"
  type        = string
  default     = "c6i.2xlarge"
}

variable "destination_instance_type" {
  description = "EC2 instance type for destination server"
  type        = string
  default     = "c6i.2xlarge"
}

variable "source_volume_size" {
  description = "Root volume size for source (GB)"
  type        = number
  default     = 100
}

variable "destination_volume_size" {
  description = "Root volume size for destination (GB)"
  type        = number
  default     = 100
}

variable "public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "private_key_path" {
  description = "Path to SSH private key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access (e.g. \"203.0.113.5/32\" for your IP)"
  type        = string

  validation {
    condition     = var.allowed_ssh_cidr != "0.0.0.0/0"
    error_message = "allowed_ssh_cidr must not be 0.0.0.0/0. Set it to your IP, e.g. \"$(curl -s ifconfig.me)/32\"."
  }
}

variable "deploy_cross_az" {
  description = "Deploy source and destination in different availability zones"
  type        = bool
  default     = false
}

variable "simulate_latency" {
  description = "Enable network latency simulation on destination (requires tc/netem)"
  type        = bool
  default     = false
}

variable "latency_ms" {
  description = "Simulated latency in milliseconds (e.g., 100 for 100ms RTT)"
  type        = number
  default     = 100
}

variable "bandwidth_limit_mbps" {
  description = "Bandwidth limit in Mbps for simulation (0 = unlimited)"
  type        = number
  default     = 0
}
