# ============================================================
# ECR MODULE — modules/ecr/main.tf
# Creates a private Docker image registry on AWS
#
# WHAT THIS MODULE CREATES:
# ─────────────────────────────────────────────────────────────
#
#  Jenkins                ECR Repository              EKS
#  ────────               ──────────────              ───
#  docker build    →      bg-project-app        →     pods pull
#  docker push     →      ├── image:abc123            image from
#                         ├── image:def456            ECR
#                         └── image:latest
#
# LIFECYCLE POLICY:
#   ECR stores every image you push
#   Without cleanup → storage fills up → costs money
#   Policy: keep only last 10 images → older ones auto-deleted
#
# IMAGE SCANNING:
#   Every image pushed → ECR scans for known CVE vulnerabilities
#   Free feature → always enable it
#   Results visible in AWS Console → ECR → Repository → Images
# ============================================================


# ---- Module Input Variables --------------------------------

variable "project_name" {
  description = "Project name used as prefix for ECR repo name"
  type        = string
}

variable "aws_region" {
  description = "AWS region where ECR repository is created"
  type        = string
}


# ============================================================
# ECR REPOSITORY
#
# UNDERSTANDING force_delete:
#   false = cannot delete repo if it has images inside
#   true  = delete repo even if images exist
#   We set true for easy cleanup during learning
#   In production → set false to protect images
#
# UNDERSTANDING image_tag_mutability:
#   MUTABLE   = can overwrite existing tags (e.g. push :latest again)
#   IMMUTABLE = once tag is pushed, cannot overwrite it
#   MUTABLE is fine for development/learning
#   IMMUTABLE is better for production (full traceability)
# ============================================================

resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  # Enable vulnerability scanning on every push
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-ecr"
  }
}


# ============================================================
# ECR LIFECYCLE POLICY
#
# UNDERSTANDING LIFECYCLE POLICY:
#   Every docker push creates a new image in ECR
#   Example after 3 months:
#   → 200+ images stored → you pay for all that storage
#
#   This policy says:
#   "Keep only the 10 most recent images
#    Auto-delete anything older"
#
#   tagStatus = "any" → applies to ALL images regardless of tag
#   countType = "imageCountMoreThan" → trigger when count > 10
#   countNumber = 10 → keep 10, delete the rest
#   action type = "expire" → delete the old images
# ============================================================

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images, delete older ones"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}


# ============================================================
# MODULE OUTPUT
#
# repository_url is the full URL to push/pull images
# Format: <account_id>.dkr.ecr.<region>.amazonaws.com/<repo_name>
# Example: 793433927733.dkr.ecr.ap-south-1.amazonaws.com/bg-project-app
#
# Jenkins uses this URL to:
#   docker tag  myimage:latest <repository_url>:latest
#   docker push <repository_url>:latest
#
# EKS uses this URL in pod spec:
#   image: <repository_url>:abc123
# ============================================================

output "repository_url" {
  description = "Full ECR repository URL for docker push and kubectl image reference"
  value       = aws_ecr_repository.app.repository_url
}

output "repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.app.name
}