# ============================================================
# OUTPUTS.TF
# ============================================================

# ---- Backend ----
output "s3_bucket_name" {
  description = "S3 bucket storing Terraform state"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "dynamodb_table_name" {
  description = "DynamoDB table for state locking"
  value       = aws_dynamodb_table.terraform_lock.name
}

# ---- VPC ----
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

# ---- ECR ----
output "ecr_repository_url" {
  description = "ECR URL — use this to push Docker images from Jenkins"
  value       = module.ecr.repository_url
}

# ---- EKS ----
output "eks_cluster_name" {
  description = "EKS cluster name — run: aws eks update-kubeconfig --name <this>"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

# ---- Jenkins ----
output "jenkins_public_ip" {
  description = "Jenkins IP — open http://<ip>:8080 in browser"
  value       = module.jenkins.public_ip
}

output "jenkins_ssh_command" {
  description = "SSH into Jenkins"
  value       = module.jenkins.ssh_command
}

# ---- CloudWatch ----
output "sns_topic_arn" {
  description = "SNS topic ARN"
  value       = module.cloudwatch.sns_topic_arn
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = module.cloudwatch.dashboard_url
}