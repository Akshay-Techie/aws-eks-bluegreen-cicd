# ============================================================
# MAIN.TF — Root Terraform Configuration
#
# HOW TO USE:
# Step 1: terraform apply -target (backend resources) → S3 + DynamoDB
# Step 2: Uncomment backend block → terraform init -migrate-state
# Step 3: terraform apply -target=module.vpc
# Step 4: terraform apply -target=module.ecr
# Step 5: terraform apply -target=module.eks
# Step 6: terraform apply -target=module.alb
# Step 7: terraform apply -target=module.jenkins
# Step 8: terraform apply -target=module.cloudwatch
# Step 9: terraform apply (final)
# ============================================================
# ============================================================
# MAIN.TF — Root Terraform Configuration
# ============================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }

  backend "s3" {
    bucket         = "bg-project-tfstate-793433927733"
    key            = "bg-project/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "bg-project-terraform-lock"
  }
}

# ============================================================
# AWS PROVIDER
# ============================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ============================================================
# DATA SOURCES — read EKS cluster info from AWS directly
#
# WHY DATA SOURCES instead of module.eks.xxx?
# Providers are initialized BEFORE modules run
# So provider "helm" cannot reference module outputs
# Data sources are resolved at runtime → safe to use
# ============================================================

data "aws_eks_cluster" "main" {
  name = "${var.project_name}-eks"
}

data "aws_eks_cluster_auth" "main" {
  name = "${var.project_name}-eks"
}

# ============================================================
# HELM PROVIDER
# Connects to EKS cluster to install K8s applications
# ============================================================

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

# ============================================================
# MODULE CALLS
# ============================================================

module "vpc" {
  source             = "./modules/vpc"
  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
  aws_region   = var.aws_region
}

module "eks" {
  source             = "./modules/eks"
  project_name       = var.project_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  node_instance_type = var.node_instance_type
  desired_nodes      = var.desired_nodes
  min_nodes          = var.min_nodes
  max_nodes          = var.max_nodes
}

module "alb" {
  source            = "./modules/alb"
  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  cluster_name      = module.eks.cluster_name
  aws_region        = var.aws_region
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
}

module "jenkins" {
  source                = "./modules/jenkins"
  project_name          = var.project_name
  vpc_id                = module.vpc.vpc_id
  public_subnet_id      = module.vpc.public_subnet_ids[0]
  jenkins_instance_type = var.jenkins_instance_type
  key_pair_name         = var.key_pair_name
  ecr_repo_url          = module.ecr.repository_url
  cluster_name          = module.eks.cluster_name
  aws_region            = var.aws_region
}

module "cloudwatch" {
  source       = "./modules/cloudwatch"
  project_name = var.project_name
  cluster_name = module.eks.cluster_name
  alert_email  = var.alert_email
  aws_region   = var.aws_region
}