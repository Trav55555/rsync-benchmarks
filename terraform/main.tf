terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "rsync-benchmarks"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

resource "aws_vpc" "benchmark_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "benchmark_igw" {
  vpc_id = aws_vpc.benchmark_vpc.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "benchmark_subnet" {
  vpc_id                  = aws_vpc.benchmark_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-subnet-az1"
    AZ   = data.aws_availability_zones.available.names[0]
  }
}

resource "aws_subnet" "benchmark_subnet_az2" {
  count                   = var.deploy_cross_az ? 1 : 0
  vpc_id                  = aws_vpc.benchmark_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-subnet-az2"
    AZ   = data.aws_availability_zones.available.names[1]
  }
}

resource "aws_route_table" "benchmark_rt" {
  vpc_id = aws_vpc.benchmark_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.benchmark_igw.id
  }

  tags = {
    Name = "${var.project_name}-rt"
  }
}

resource "aws_route_table_association" "benchmark_rta" {
  subnet_id      = aws_subnet.benchmark_subnet.id
  route_table_id = aws_route_table.benchmark_rt.id
}

resource "aws_route_table_association" "benchmark_rta_az2" {
  count          = var.deploy_cross_az ? 1 : 0
  subnet_id      = aws_subnet.benchmark_subnet_az2[0].id
  route_table_id = aws_route_table.benchmark_rt.id
}

resource "aws_security_group" "benchmark_sg" {
  name_prefix = "${var.project_name}-sg"
  vpc_id      = aws_vpc.benchmark_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Allow all traffic between benchmark instances
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

resource "aws_iam_role" "benchmark_role" {
  name = "${var.project_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "benchmark_policy" {
  name = "${var.project_name}-s3-policy"
  role = aws_iam_role.benchmark_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.results_bucket.arn,
          "${aws_s3_bucket.results_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "benchmark_profile" {
  name = "${var.project_name}-profile"
  role = aws_iam_role.benchmark_role.name
}

resource "aws_s3_bucket" "results_bucket" {
  bucket = "${var.project_name}-results-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_object" "setup_source_script" {
  bucket       = aws_s3_bucket.results_bucket.bucket
  key          = "scripts/setup-source.sh"
  source       = "${path.module}/scripts/setup-source.sh"
  content_type = "text/x-shellscript"
}

resource "aws_s3_object" "setup_destination_script" {
  bucket       = aws_s3_bucket.results_bucket.bucket
  key          = "scripts/setup-destination.sh"
  source       = "${path.module}/scripts/setup-destination.sh"
  content_type = "text/x-shellscript"
}

resource "aws_s3_bucket_versioning" "results_versioning" {
  bucket = aws_s3_bucket.results_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "results_block" {
  bucket = aws_s3_bucket.results_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_key_pair" "benchmark_key" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.public_key_path)
}

resource "aws_instance" "source" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.source_instance_type
  subnet_id              = aws_subnet.benchmark_subnet.id
  vpc_security_group_ids = [aws_security_group.benchmark_sg.id]
  key_name               = aws_key_pair.benchmark_key.key_name
  iam_instance_profile   = aws_iam_instance_profile.benchmark_profile.name

  root_block_device {
    volume_size = var.source_volume_size
    volume_type = "gp3"
    iops        = 3000
  }

  user_data = templatefile("${path.module}/templates/user_data_source.sh.tftpl", {
    bucket = aws_s3_bucket.results_bucket.bucket
  })

  tags = {
    Name = "${var.project_name}-source"
    Role = "source"
    AZ   = data.aws_availability_zones.available.names[0]
  }

  depends_on = [aws_instance.destination, aws_s3_object.setup_source_script]
}

resource "aws_instance" "destination" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.destination_instance_type
  subnet_id              = var.deploy_cross_az ? aws_subnet.benchmark_subnet_az2[0].id : aws_subnet.benchmark_subnet.id
  vpc_security_group_ids = [aws_security_group.benchmark_sg.id]
  key_name               = aws_key_pair.benchmark_key.key_name
  iam_instance_profile   = aws_iam_instance_profile.benchmark_profile.name

  root_block_device {
    volume_size = var.destination_volume_size
    volume_type = "gp3"
    iops        = 3000
  }

  user_data = templatefile("${path.module}/templates/user_data_destination.sh.tftpl", {
    bucket = aws_s3_bucket.results_bucket.bucket
  })

  tags = {
    Name = "${var.project_name}-destination"
    Role = "destination"
    AZ   = var.deploy_cross_az ? data.aws_availability_zones.available.names[1] : data.aws_availability_zones.available.names[0]
  }

  depends_on = [aws_s3_object.setup_destination_script]
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

output "source_public_ip" {
  description = "Public IP of the source instance"
  value       = aws_instance.source.public_ip
}

output "destination_public_ip" {
  description = "Public IP of the destination instance"
  value       = aws_instance.destination.public_ip
}

output "destination_private_ip" {
  description = "Private IP of the destination instance"
  value       = aws_instance.destination.private_ip
}

output "results_bucket" {
  description = "S3 bucket for benchmark results"
  value       = aws_s3_bucket.results_bucket.bucket
}

output "ssh_command_source" {
  description = "SSH command to connect to source"
  value       = "ssh -i ${var.private_key_path} ec2-user@${aws_instance.source.public_ip}"
}

output "ssh_command_destination" {
  description = "SSH command to connect to destination"
  value       = "ssh -i ${var.private_key_path} ec2-user@${aws_instance.destination.public_ip}"
}

output "cross_az_deployed" {
  description = "Whether instances are deployed in different AZs"
  value       = var.deploy_cross_az
}

output "source_az" {
  description = "Availability zone of source instance"
  value       = data.aws_availability_zones.available.names[0]
}

output "destination_az" {
  description = "Availability zone of destination instance"
  value       = var.deploy_cross_az ? data.aws_availability_zones.available.names[1] : data.aws_availability_zones.available.names[0]
}

output "latency_simulation_enabled" {
  description = "Whether latency simulation is enabled"
  value       = var.simulate_latency
}

output "simulated_latency_ms" {
  description = "Simulated latency in milliseconds"
  value       = var.simulate_latency ? var.latency_ms : 0
}
