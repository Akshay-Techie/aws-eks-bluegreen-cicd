# ============================================================
# VPC MODULE — modules/vpc/main.tf
# Creates the entire networking layer
#
# WHAT THIS MODULE CREATES:
# -----------------------------------------------------------
#
#         Internet
#            │
#     [Internet Gateway]        ← entry/exit door for VPC
#            │
#     ┌──────┴──────────────────────────────────┐
#     │           VPC 10.0.0.0/16               │
#     │                                         │
#     │  ┌─────────────┐  ┌─────────────┐       │
#     │  │Public Subnet│  │Public Subnet│       │
#     │  │ 10.0.1.0/24 │  │ 10.0.2.0/24│       │
#     │  │   AZ: 1a    │  │   AZ: 1b   │       │
#     │  │  (ALB here) │  │            │       │
#     │  │  (Jenkins)  │  │            │       │
#     │  └──────┬──────┘  └────────────┘       │
#     │         │                               │
#     │    [NAT Gateway]   ← private → internet │
#     │         │                               │
#     │  ┌──────┴──────┐  ┌─────────────┐       │
#     │  │Private Sub  │  │Private Sub  │       │
#     │  │10.0.10.0/24 │  │10.0.11.0/24│       │
#     │  │   AZ: 1a    │  │   AZ: 1b   │       │
#     │  │ (EKS nodes) │  │ (EKS nodes)│       │
#     │  └─────────────┘  └────────────┘       │
#     └─────────────────────────────────────────┘
# ============================================================


# ============================================================
# MODULE INPUT VARIABLES
# Root main.tf passes these values when calling this module
# ============================================================

variable "project_name"       { type = string }
variable "vpc_cidr"           { type = string }
variable "availability_zones" { type = list(string) }
variable "public_subnets"     { type = list(string) }
variable "private_subnets"    { type = list(string) }


# ============================================================
# VPC — the private network that contains everything
#
# UNDERSTANDING VPC:
# VPC = Virtual Private Cloud = your own private section of AWS
# Like having your own private office building inside AWS
# Nothing gets in or out unless YOU configure it
#
# enable_dns_hostnames = true → EC2 instances get DNS names
# enable_dns_support   = true → DNS resolution works inside VPC
# Both required for EKS to function properly
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
    # EKS needs this tag to find the VPC
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
}


# ============================================================
# INTERNET GATEWAY — connects VPC to the internet
#
# UNDERSTANDING IGW:
# Without IGW → VPC is completely isolated (no internet at all)
# IGW is attached to VPC and allows:
# → Inbound: internet traffic → public subnet resources
# → Outbound: public subnet resources → internet
#
# IGW is NOT used by private subnets directly
# Private subnets use NAT Gateway instead
# ============================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-igw" }
}


# ============================================================
# PUBLIC SUBNETS — one per Availability Zone
#
# UNDERSTANDING count:
# count = length(var.public_subnets) = 2 (we defined 2 subnets)
# Terraform creates 2 subnets: public[0] and public[1]
# count.index = 0 for first, 1 for second
#
# UNDERSTANDING map_public_ip_on_launch:
# true → any EC2 launched in this subnet gets a public IP
# This is how Jenkins and ALB get their public IPs
#
# UNDERSTANDING kubernetes tags:
# ALB Ingress Controller scans subnets for these tags
# "kubernetes.io/role/elb" = "1" → use this subnet for ALB
# ============================================================

resource "aws_subnet" "public" {
  count             = length(var.public_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                              = "1"
    "kubernetes.io/cluster/${var.project_name}-eks"       = "shared"
  }
}


# ============================================================
# PRIVATE SUBNETS — one per Availability Zone
#
# UNDERSTANDING private subnets:
# map_public_ip_on_launch = false (default) → no public IP
# EKS worker nodes launch here → not directly reachable
# More secure — attackers can't directly reach your app pods
#
# "kubernetes.io/role/internal-elb" = "1"
# → tells ALB controller to use these for internal load balancers
# ============================================================

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
}


# ============================================================
# ELASTIC IP — static public IP address for NAT Gateway
#
# UNDERSTANDING EIP:
# NAT Gateway needs a fixed public IP to send traffic out
# Regular IPs change → EIP stays the same forever
# Costs ~$0.005/hr when attached to running NAT Gateway
# ============================================================

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.project_name}-nat-eip" }
}


# ============================================================
# NAT GATEWAY — allows private subnets to reach internet
#
# UNDERSTANDING NAT GATEWAY:
# NAT = Network Address Translation
#
# EKS nodes (private subnet) need internet to:
# → Pull Docker images from ECR
# → Download updates
# → Call AWS APIs
#
# NAT Gateway sits in PUBLIC subnet (has internet access)
# Private subnet traffic → NAT Gateway → Internet
# Return traffic → NAT Gateway → Private subnet
# Internet CANNOT initiate connections to private subnet
# This is the security benefit of private subnets
#
# subnet_id = public subnet → NAT Gateway itself needs internet
# allocation_id = the Elastic IP it uses to talk to internet
# ============================================================

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.project_name}-nat" }
}


# ============================================================
# ROUTE TABLE: PUBLIC
# Rule: send ALL traffic (0.0.0.0/0) → Internet Gateway
#
# UNDERSTANDING ROUTE TABLES:
# Route table = GPS directions for network traffic
# Every subnet must be associated with a route table
#
# 0.0.0.0/0 = "any destination not in VPC"
# → send to Internet Gateway
# This is what makes a subnet "public"
# ============================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}


# ============================================================
# ROUTE TABLE: PRIVATE
# Rule: send ALL traffic (0.0.0.0/0) → NAT Gateway
#
# Private subnets route outbound traffic to NAT Gateway
# NOT to Internet Gateway → internet can't reach them directly
# This is what makes a subnet "private"
# ============================================================

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project_name}-private-rt" }
}


# ============================================================
# ROUTE TABLE ASSOCIATIONS
# Links each subnet to its route table
#
# Without association → subnet uses VPC default route table
# With association → subnet uses the specific route table
#
# public[0] + public[1] → public route table (→ IGW)
# private[0] + private[1] → private route table (→ NAT)
# ============================================================

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# ============================================================
# MODULE OUTPUTS
# These values are returned to root main.tf
# Root then passes them to other modules that need them
# ============================================================

output "vpc_id" {
  description = "VPC ID — passed to EKS, ALB, Jenkins modules"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs — for ALB and Jenkins"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs — for EKS worker nodes"
  value       = aws_subnet.private[*].id
}