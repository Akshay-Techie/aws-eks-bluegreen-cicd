# ============================================================
# EKS MODULE — modules/eks/main.tf
# Creates the Kubernetes cluster on AWS
#
# UNDERSTANDING EKS ARCHITECTURE:
# ─────────────────────────────────────────────────────────────
#
#  EKS = Elastic Kubernetes Service
#      = AWS managed Kubernetes control plane
#
#  TWO PARTS:
#
#  1. CONTROL PLANE (managed by AWS — you don't pay per node)
#     ┌─────────────────────────────────────────┐
#     │  API Server  │  etcd  │  Scheduler      │
#     │  Controller Manager   │  Cloud Manager  │
#     └─────────────────────────────────────────┘
#     → AWS runs this, patches it, backs it up
#     → You interact via kubectl → hits API Server
#
#  2. DATA PLANE / NODE GROUP (you manage — you pay per EC2)
#     ┌──────────────┐  ┌──────────────┐
#     │  t3.small    │  │  t3.small    │
#     │  Worker Node │  │  Worker Node │
#     │  (private-1) │  │  (private-2) │
#     │  ┌────────┐  │  │  ┌────────┐  │
#     │  │ Pod    │  │  │  │ Pod    │  │
#     │  │ blue   │  │  │  │ Pod    │  │
#     │  └────────┘  │  │  │ green  │  │
#     └──────────────┘  │  └────────┘  │
#                       └──────────────┘
# ============================================================


# ---- Module Input Variables --------------------------------

variable "project_name"       { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "node_instance_type" { type = string }
variable "desired_nodes"      { type = number }
variable "min_nodes"          { type = number }
variable "max_nodes"          { type = number }


# ============================================================
# DATA SOURCE — current AWS account details
# Used to build ARNs and reference account ID
# ============================================================

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}


# ============================================================
# IAM ROLE — EKS CONTROL PLANE
#
# UNDERSTANDING IAM ROLES FOR EKS:
#   EKS control plane needs permission to:
#   → Create/manage ENIs (network interfaces) in your VPC
#   → Create load balancers when you create K8s services
#   → Describe EC2 resources to manage nodes
#
#   We create a Role and attach AWS managed policies to it
#   Then tell EKS cluster to use this role
#
# assume_role_policy:
#   "Who is allowed to assume this role?"
#   Answer: eks.amazonaws.com (the EKS service itself)
# ============================================================

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = { Name = "${var.project_name}-eks-cluster-role" }
}

# Attach AWS managed policy — gives EKS all permissions it needs
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}


# ============================================================
# EKS CLUSTER — the control plane
#
# UNDERSTANDING CLUSTER SETTINGS:
#
#   version = "1.29"
#   → Kubernetes version running on control plane
#   → AWS supports last 3 versions, older ones get deprecated
#
#   vpc_config:
#   → subnet_ids = private subnets where nodes will run
#   → endpoint_public_access = true → you can run kubectl from laptop
#   → endpoint_private_access = true → nodes talk to API privately
#
#   enabled_cluster_log_types:
#   → Sends control plane logs to CloudWatch
#   → api = all kubectl commands
#   → audit = who did what (security)
#   → authenticator = auth attempts
# ============================================================

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-eks"
  version  = "1.29"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true

    # Security group handled by EKS automatically
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  # Control plane must exist before node group
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = { Name = "${var.project_name}-eks" }
}


# ============================================================
# IAM ROLE — EKS WORKER NODES
#
# UNDERSTANDING NODE ROLE:
#   EC2 worker nodes need permission to:
#   → Join the EKS cluster (AmazonEKSWorkerNodePolicy)
#   → Configure pod networking (AmazonEKS_CNI_Policy)
#   → Pull images from ECR (AmazonEC2ContainerRegistryReadOnly)
#   → Send metrics/logs to CloudWatch (CloudWatchAgentServerPolicy)
#
#   Principal: ec2.amazonaws.com → EC2 instances assume this role
# ============================================================

resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = { Name = "${var.project_name}-eks-node-role" }
}

# Policy 1: Basic worker node permissions
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# Policy 2: Pod networking (CNI = Container Network Interface)
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Policy 3: Pull images from ECR
resource "aws_iam_role_policy_attachment" "eks_ecr_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Policy 4: Send metrics to CloudWatch
resource "aws_iam_role_policy_attachment" "eks_cloudwatch_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}


# ============================================================
# EKS NODE GROUP — the actual EC2 worker nodes
#
# UNDERSTANDING NODE GROUP:
#
#   node_group_name:
#   → Logical name for this group of nodes
#
#   subnet_ids = private subnets:
#   → Nodes launch in private subnets
#   → Not directly reachable from internet
#   → More secure
#
#   scaling_config:
#   → desired_size = how many nodes right now
#   → min_size     = never go below this
#   → max_size     = never go above this
#   → Auto-scaler adjusts between min and max
#
#   instance_types = ["t3.small"]:
#   → 2 vCPU, 2GB RAM per node
#   → Each node can run ~4-6 small pods
#
#   ami_type = "AL2_x86_64":
#   → Amazon Linux 2 optimized for EKS
#   → Has Docker, kubelet pre-installed
#
#   disk_size = 20:
#   → 20GB storage per node
#   → Stores container images, logs
# ============================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = var.desired_nodes
    min_size     = var.min_nodes
    max_size     = var.max_nodes
  }

  instance_types = [var.node_instance_type]
  ami_type       = "AL2_x86_64"
  disk_size      = 20

  # Rolling update — replace one node at a time
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy,
  ]

  tags = { Name = "${var.project_name}-node-group" }
}


# ============================================================
# OIDC PROVIDER — enables IAM Roles for Service Accounts
#
# UNDERSTANDING OIDC / IRSA:
#   Problem without OIDC:
#   → ALB controller pod needs AWS permissions to create ALBs
#   → Without OIDC: give ALL nodes permission (too broad, insecure)
#
#   With OIDC / IRSA (IAM Roles for Service Accounts):
#   → Create IAM role with specific permissions
#   → Bind role to specific K8s service account
#   → Only THAT pod gets those permissions
#   → Other pods get nothing
#   → Much more secure — principle of least privilege
#
#   ALB controller needs this to create/manage load balancers
# ============================================================

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = { Name = "${var.project_name}-eks-oidc" }
}


# ============================================================
# MODULE OUTPUTS
# These values are used by ALB, Jenkins, CloudWatch modules
# ============================================================

output "cluster_name" {
  description = "EKS cluster name — used by kubectl and other modules"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint — used by kubectl"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  description = "Cluster CA certificate for kubectl authentication"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used by ALB module for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL — used by ALB module for IRSA"
  value       = aws_iam_openid_connect_provider.eks.url
}