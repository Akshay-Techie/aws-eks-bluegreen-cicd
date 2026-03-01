# ============================================================
# VARIABLES.TF
# All input variables for the ENTIRE project
#
# UNDERSTANDING VARIABLES IN TERRAFORM:
# -----------------------------------------------------------
# Variables make your code reusable and configurable
# Instead of hardcoding values everywhere:
#   resource "aws_vpc" "main" {
#     cidr_block = "10.0.0.0/16"  ← hardcoded = bad
#   }
#
# We use variables:
#   resource "aws_vpc" "main" {
#     cidr_block = var.vpc_cidr   ← from variable = good
#   }
#
# Actual values come from terraform.tfvars file
# This file just DEFINES what variables exist and their types
# ============================================================


# ---- GENERAL SETTINGS ----------------------------------------

variable "aws_region" {
  description = "AWS region where all resources will be created"
  type        = string
  # ap-south-1 = Mumbai — closest to India, lowest latency for you
}

variable "aws_account_id" {
  description = "Your 12-digit AWS Account ID — used to make S3 bucket name unique"
  type        = string
  # Find it: aws sts get-caller-identity --query Account --output text
}

variable "project_name" {
  description = "Project name used as prefix in ALL resource names"
  type        = string
  # Example: bg-project → resources named bg-project-vpc, bg-project-eks etc
}

variable "environment" {
  description = "Environment name — used in tags"
  type        = string
  # Examples: prod, staging, dev
}


# ---- NETWORKING ----------------------------------------------

variable "vpc_cidr" {
  description = "IP address range for the entire VPC"
  type        = string
  # UNDERSTANDING CIDR:
  # 10.0.0.0/16 means:
  # → Network starts at 10.0.0.0
  # → /16 = first 16 bits fixed → last 16 bits free
  # → 2^16 = 65,536 total IP addresses in this VPC
  # We divide these into smaller subnets
}

variable "availability_zones" {
  description = "Two AZs for high availability"
  type        = list(string)
  # UNDERSTANDING AZs:
  # AZ = physical data center within a region
  # ap-south-1 has: ap-south-1a, ap-south-1b, ap-south-1c
  # Using 2 AZs = if one data center goes down → other serves traffic
  # This is why we create subnets in pairs
}

variable "public_subnets" {
  description = "IP ranges for public subnets — one per AZ"
  type        = list(string)
  # Public subnet = has route to internet via Internet Gateway
  # ALB and Jenkins live here
  # 10.0.1.0/24 = 256 IPs in AZ-a
  # 10.0.2.0/24 = 256 IPs in AZ-b
}

variable "private_subnets" {
  description = "IP ranges for private subnets — one per AZ"
  type        = list(string)
  # Private subnet = NO direct internet access
  # EKS worker nodes live here — more secure
  # Can reach internet via NAT Gateway (for pulling images etc)
  # 10.0.10.0/24 = 256 IPs in AZ-a
  # 10.0.11.0/24 = 256 IPs in AZ-b
}


# ---- EKS CLUSTER ---------------------------------------------

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  # UNDERSTANDING INSTANCE TYPES:
  # t3.medium = 2 vCPU, 4GB RAM
  # Good for learning/dev — not too expensive
  # Each node can run multiple pods
  # t3.micro (1vCPU/1GB) → too small for EKS
  # t3.medium (2vCPU/4GB) → minimum recommended
}

variable "desired_nodes" {
  description = "Number of worker nodes to run under normal load"
  type        = number
  # This is what EKS targets normally
  # Auto-scaler adjusts between min and max based on load
}

variable "min_nodes" {
  description = "Minimum number of worker nodes — never go below this"
  type        = number
  # Even at zero traffic, keep at least 1 node running
  # So there's always capacity to handle requests
}

variable "max_nodes" {
  description = "Maximum number of worker nodes — never go above this"
  type        = number
  # Cost protection — auto-scaler won't add unlimited nodes
  # Set this based on your budget
}


# ---- JENKINS -------------------------------------------------

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins CI/CD server"
  type        = string
  # Jenkins needs decent memory for builds
  # t3.small = good starting point
}

variable "key_pair_name" {
  description = "Name of EC2 Key Pair for SSH access to Jenkins"
  type        = string
  # UNDERSTANDING KEY PAIRS:
  # AWS uses key pairs (public/private key) for SSH
  # You keep the private key (.pem file) on your laptop
  # AWS stores the public key
  # To SSH: ssh -i your-key.pem ec2-user@jenkins-ip
  # We will create this key pair before terraform apply
}


# ---- MONITORING ----------------------------------------------

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
  # SNS will send emails to this address when:
  # → CPU usage too high
  # → Pod keeps crashing
  # → Memory running low
  # → Deployment succeeds or fails
}