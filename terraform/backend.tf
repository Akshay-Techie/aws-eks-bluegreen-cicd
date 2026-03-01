# ============================================================
# BACKEND.TF
# Creates S3 bucket and DynamoDB table for Terraform state
#
# WHY DO WE NEED THIS?
# -----------------------------------------------------------
# When Terraform creates resources on AWS, it saves a record
# of everything it created in a file called "terraform.tfstate"
#
# By default this file sits on your laptop — which is risky:
#   ❌ Laptop crashes → state lost → Terraform loses track
#   ❌ You work from another machine → no state file there
#   ❌ Team member runs terraform → they have different state
#
# Solution → store state in S3 (remote, safe, shared)
# + DynamoDB for locking (prevents two runs at same time)
#
# HOW TO USE THIS FILE:
# -----------------------------------------------------------
# PHASE 1 — Run this FIRST (before backend block in main.tf)
#   terraform init
#   terraform apply -target=aws_s3_bucket.terraform_state \
#                   -target=aws_s3_bucket_versioning.terraform_state \
#                   -target=aws_s3_bucket_server_side_encryption_configuration.terraform_state \
#                   -target=aws_s3_bucket_public_access_block.terraform_state \
#                   -target=aws_dynamodb_table.terraform_lock
#
# PHASE 2 — After S3 exists, uncomment backend block in main.tf
#   terraform init -migrate-state
#   → Terraform moves local state → S3
# ============================================================


# ============================================================
# S3 BUCKET — stores the terraform.tfstate file
#
# UNDERSTANDING S3 BUCKET NAME:
#   Must be globally unique across ALL AWS accounts worldwide
#   We use: projectname + your account ID = guaranteed unique
#   Example: bg-project-tfstate-XXXXXXXXXXXX
#
# UNDERSTANDING lifecycle prevent_destroy:
#   Even if you run "terraform destroy" this bucket won't delete
#   This is a SAFETY NET — state file must never be lost
#   To actually delete: remove this block first, then destroy
# ============================================================

resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project_name}-tfstate-${var.aws_account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "${var.project_name}-tfstate"
    Purpose = "Stores Terraform remote state"
  }
}


# ============================================================
# S3 VERSIONING — keeps history of every state file change
#
# UNDERSTANDING VERSIONING:
#   Every time terraform apply runs → state file changes
#   S3 versioning keeps ALL previous versions
#
#   Example:
#   Version 1 → after VPC created
#   Version 2 → after EKS created
#   Version 3 → after Jenkins created (corrupted somehow)
#   → You can restore Version 2 from S3 version history
#
#   Think of it like Git commits for your state file
# ============================================================

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}


# ============================================================
# S3 ENCRYPTION — encrypts state file data at rest
#
# UNDERSTANDING ENCRYPTION:
#   State file contains sensitive info:
#   → Resource IDs, ARNs, IP addresses, sometimes passwords
#
#   AES256 = industry standard encryption
#   AWS manages the keys automatically
#   Free of charge — no reason NOT to enable this
#
#   "at rest" = data is encrypted when stored on disk
#   When Terraform reads it → decrypted automatically
# ============================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# ============================================================
# S3 PUBLIC ACCESS BLOCK — keeps bucket 100% private
#
# UNDERSTANDING PUBLIC ACCESS BLOCK:
#   By default S3 buckets CAN be made public
#   State file must NEVER be public — it has sensitive data
#
#   This resource blocks ALL forms of public access:
#   block_public_acls       → blocks public ACL settings
#   block_public_policy     → blocks public bucket policies
#   ignore_public_acls      → ignores existing public ACLs
#   restrict_public_buckets → restricts public bucket access
#
#   Even if someone accidentally adds a public policy later
#   → this block overrides and keeps it private
# ============================================================

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# ============================================================
# DYNAMODB TABLE — handles state locking
#
# UNDERSTANDING STATE LOCKING:
#   Problem without locking:
#   ┌─────────────────────────────────────────────┐
#   │ You run: terraform apply  (creating EKS)    │
#   │ CI/CD also runs: terraform apply (same time)│
#   │ Both read same state file                   │
#   │ Both make changes                           │
#   │ Both write back → STATE CORRUPTED ❌        │
#   └─────────────────────────────────────────────┘
#
#   With DynamoDB locking:
#   ┌─────────────────────────────────────────────┐
#   │ You run: terraform apply                    │
#   │ → writes lock entry to DynamoDB             │
#   │ CI/CD runs: terraform apply                 │
#   │ → sees lock in DynamoDB → waits/errors      │
#   │ Your apply finishes → deletes lock entry    │
#   │ CI/CD can now proceed safely ✅             │
#   └─────────────────────────────────────────────┘
#
# UNDERSTANDING THE TABLE:
#   hash_key = "LockID" → THIS NAME IS REQUIRED BY TERRAFORM
#   Do not change it — Terraform looks for exactly "LockID"
#   type = "S" → String data type
#
#   PAY_PER_REQUEST billing:
#   → We don't know how often Terraform will run
#   → Pay only when lock is acquired/released
#   → Costs almost nothing (fractions of a cent per run)
# ============================================================

resource "aws_dynamodb_table" "terraform_lock" {
  name         = "${var.project_name}-terraform-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "${var.project_name}-terraform-lock"
    Purpose = "Terraform state locking"
  }
}