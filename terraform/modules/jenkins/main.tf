# ============================================================
# JENKINS MODULE — modules/jenkins/main.tf
# Creates Jenkins CI/CD server on EC2
#
# WHAT THIS MODULE CREATES:
# ─────────────────────────────────────────────────────────────
#
#  Internet
#     │
#     ▼
#  [Security Group]         ← controls inbound/outbound traffic
#     │
#     ▼
#  [EC2: t3.small]          ← Jenkins server
#     │  Ubuntu 22.04
#     │  Public subnet
#     │  Public IP
#     │
#     ├── port 8080         ← Jenkins web UI
#     ├── port 22           ← SSH access
#     │
#     └── IAM Role          ← permissions to:
#            ├── push/pull ECR images
#            ├── update kubeconfig for EKS
#            └── read SSM parameters
#
# HOW JENKINS FITS IN THE PIPELINE:
#   Git push → GitHub Webhook → Jenkins triggered
#   Jenkins:
#     1. Pulls code from GitHub
#     2. Runs tests
#     3. Builds Docker image
#     4. Pushes to ECR
#     5. Deploys to EKS (kubectl apply)
#     6. Switches traffic (blue→green)
# ============================================================


# ---- Module Input Variables --------------------------------

variable "project_name"          { type = string }
variable "vpc_id"                { type = string }
variable "public_subnet_id"      { type = string }
variable "jenkins_instance_type" { type = string }
variable "key_pair_name"         { type = string }
variable "ecr_repo_url"          { type = string }
variable "cluster_name"          { type = string }
variable "aws_region"            { type = string }


# ============================================================
# DATA SOURCE — get latest Ubuntu 22.04 AMI
#
# UNDERSTANDING AMI:
# AMI = Amazon Machine Image = OS template for EC2
# Instead of hardcoding AMI ID (changes per region):
# → We query AWS to find latest Ubuntu 22.04 LTS
# → Works in any region automatically
#
# filter by:
# → name pattern: ubuntu/images/*/ubuntu-jammy-22.04-amd64*
# → virtualization: hvm (hardware virtual machine)
# → root device: ebs (elastic block store)
#
# owners = ["099720109477"] = Canonical (Ubuntu's official AWS account)
# Always use official owner ID → never use random AMIs
# ============================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}


# ============================================================
# IAM ROLE — Jenkins EC2 Instance Role
#
# UNDERSTANDING EC2 INSTANCE ROLES:
# Instead of putting AWS credentials on Jenkins server:
# → Create IAM role with needed permissions
# → Attach role to EC2 instance
# → Jenkins automatically gets temporary credentials
# → Credentials rotate automatically → more secure
#
# Permissions Jenkins needs:
# → ECR: push/pull Docker images
# → EKS: describe cluster for kubeconfig
# → SSM: read parameters (optional, for secrets)
# ============================================================

resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-jenkins-role"

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

  tags = { Name = "${var.project_name}-jenkins-role" }
}

# Policy 1 — ECR full access (push + pull images)
resource "aws_iam_role_policy" "jenkins_ecr" {
  name = "${var.project_name}-jenkins-ecr-policy"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:ListImages",
          "ecr:DescribeRepositories"
        ]
        Resource = "*"
      }
    ]
  })
}

# Policy 2 — EKS access (update kubeconfig + deploy)
resource "aws_iam_role_policy" "jenkins_eks" {
  name = "${var.project_name}-jenkins-eks-policy"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi"
        ]
        Resource = "*"
      }
    ]
  })
}

# Instance profile — attaches IAM role to EC2
# EC2 doesn't use roles directly — needs instance profile wrapper
resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}


# ============================================================
# SECURITY GROUP — Jenkins firewall rules
#
# UNDERSTANDING SECURITY GROUPS:
# Security group = virtual firewall for EC2
# Controls which traffic is allowed IN and OUT
#
# Inbound rules (what can reach Jenkins):
# → port 8080: Jenkins web UI (from internet)
# → port 22:   SSH access (from your IP only — more secure)
#              0.0.0.0/0 = from anywhere (ok for learning)
#              In production: restrict to your IP
#
# Outbound rules:
# → all traffic allowed out (Jenkins needs internet to:
#   download plugins, push to ECR, call AWS APIs)
# ============================================================

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Security group for Jenkins CI/CD server"
  vpc_id      = var.vpc_id

  # Jenkins Web UI
  ingress {
    description = "Jenkins Web UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH access
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound traffic allowed
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-jenkins-sg" }
}


# ============================================================
# EC2 INSTANCE — Jenkins Server
#
# UNDERSTANDING EC2 SETTINGS:
#
# ami = Ubuntu 22.04 (from data source above)
#
# instance_type = t3.small
# → 2 vCPU, 2GB RAM
# → enough for Jenkins builds in learning environment
#
# subnet_id = public subnet
# → Jenkins needs public IP so you can access web UI
# → And so GitHub webhooks can reach it
#
# associate_public_ip_address = true
# → Assigns public IP automatically
#
# iam_instance_profile
# → Gives Jenkins EC2 role permissions (ECR, EKS)
#
# user_data = userdata.sh
# → Runs on first boot → installs Jenkins, Docker, kubectl
# → templatefile() replaces ${ecr_repo_url_domain} variable
#
# root_block_device
# → 20GB storage for Jenkins workspace, Docker images, logs
# ============================================================

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = true
  key_name                    = var.key_pair_name

  # Run bootstrap script on first boot
  user_data = templatefile("${path.module}/userdata.sh", {
    ecr_repo_url_domain = split("/", var.ecr_repo_url)[0]
    cluster_name        = var.cluster_name
    aws_region          = var.aws_region
  })

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = { Name = "${var.project_name}-jenkins" }
}


# ============================================================
# MODULE OUTPUT
# Jenkins public IP — open in browser: http://<ip>:8080
# ============================================================

output "public_ip" {
  description = "Jenkins public IP — access at http://<ip>:8080"
  value       = aws_instance.jenkins.public_ip
}

output "public_dns" {
  description = "Jenkins public DNS"
  value       = aws_instance.jenkins.public_dns
}

output "ssh_command" {
  description = "Command to SSH into Jenkins server"
  value       = "ssh -i ~/Genexis-Key-Pair.pem ubuntu@${aws_instance.jenkins.public_ip}"
}