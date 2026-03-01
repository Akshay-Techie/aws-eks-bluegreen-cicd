# 🚀 AWS EKS Blue-Green CI/CD Pipeline

[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws&logoColor=white)](https://aws.amazon.com/eks/)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Jenkins](https://img.shields.io/badge/CI%2FCD-Jenkins-D24939?logo=jenkins&logoColor=white)](https://www.jenkins.io/)
[![Kubernetes](https://img.shields.io/badge/Orchestration-Kubernetes-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Docker](https://img.shields.io/badge/Container-Docker-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Python](https://img.shields.io/badge/App-Python%20Flask-3776AB?logo=python&logoColor=white)](https://flask.palletsprojects.com/)

> **Production-grade Blue-Green deployment on AWS EKS using Terraform, Jenkins CI/CD, Docker, and Kubernetes. Features zero-downtime deployments, automated traffic switching via ALB, CloudWatch monitoring, and ECR image registry.**

---

## 📋 Table of Contents

- [What is Blue-Green Deployment?](#what-is-blue-green-deployment)
- [Architecture Overview](#architecture-overview)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Step-by-Step Setup](#step-by-step-setup)
  - [1. Terraform Infrastructure](#1-terraform-infrastructure)
  - [2. Kubernetes Manifests](#2-kubernetes-manifests)
  - [3. Jenkins CI/CD](#3-jenkins-cicd)
  - [4. GitHub Webhook](#4-github-webhook)
- [Pipeline Flow](#pipeline-flow)
- [Scripts Reference](#scripts-reference)
- [Monitoring](#monitoring)
- [Cost Estimate](#cost-estimate)
- [Cleanup](#cleanup)

---

## 🔵🟢 What is Blue-Green Deployment?

Blue-Green deployment maintains **two identical production environments**. Only one is live at a time. When deploying a new version:

1. Deploy new version to the **inactive** environment
2. Run health checks on the new version
3. **Switch traffic** from old to new (instantaneous via ALB)
4. Old version stays running as instant rollback option

```
BEFORE:   Internet → ALB → blue-service  → Blue Pods (v1.0) ← LIVE
                            green-service → Green Pods (v1.0) ← idle

DEPLOY:   New image deployed to Green Pods (v1.1)
          Health checks pass ✅

AFTER:    Internet → ALB → green-service → Green Pods (v1.1) ← LIVE
                            blue-service  → Blue Pods (v1.0)  ← standby (rollback)
```

**Benefits:**
- ✅ Zero downtime — traffic switch is instantaneous
- ✅ Instant rollback — one command switches back
- ✅ Safe testing — new version tested on real infra before getting traffic
- ✅ No risk — old version stays running until new is verified

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS CLOUD (ap-south-1)                   │
│                                                                 │
│  Developer ──git push──► GitHub ──webhook──► Jenkins EC2        │
│                                               │                 │
│                                    ┌──────────▼──────────┐     │
│                                    │   Jenkins Pipeline   │     │
│                                    │  Test → Build → Push │     │
│                                    └──────────┬──────────┘     │
│                                               │                 │
│                                    ┌──────────▼──────────┐     │
│                                    │    Amazon ECR        │     │
│                                    │  (Container Images)  │     │
│                                    └──────────┬──────────┘     │
│                                               │                 │
│  ┌────────────────────────────────────────────▼──────────────┐ │
│  │                    Amazon EKS Cluster                      │ │
│  │                                                            │ │
│  │   ┌─────────────────┐      ┌─────────────────┐           │ │
│  │   │ Blue Deployment │      │ Green Deployment│           │ │
│  │   │   2 x Pods      │      │   2 x Pods      │           │ │
│  │   │  (current live) │      │  (next version) │           │ │
│  │   └────────┬────────┘      └────────┬────────┘           │ │
│  │            │                        │                      │ │
│  │   ┌────────▼────────┐      ┌────────▼────────┐           │ │
│  │   │  blue-service   │      │  green-service  │           │ │
│  │   └────────┬────────┘      └────────┬────────┘           │ │
│  │            └──────────┬────────────┘                      │ │
│  │                       │                                    │ │
│  │            ┌──────────▼──────────┐                       │ │
│  │            │   Ingress (ALB)     │ ◄── one-line switch   │ │
│  │            └──────────┬──────────┘                       │ │
│  └───────────────────────┼───────────────────────────────────┘ │
│                           │                                     │
│              ┌────────────▼────────────┐                       │
│              │   AWS ALB               │                       │
│              │  (internet-facing)      │                       │
│              └────────────┬────────────┘                       │
└───────────────────────────┼─────────────────────────────────────┘
                            │
                       End Users 🌍
```

### Network Architecture
```
VPC (10.0.0.0/16)
├── Public Subnets  (10.0.1.0/24, 10.0.2.0/24)   → ALB + Jenkins
│       └── NAT Gateway → allows private → internet
└── Private Subnets (10.0.10.0/24, 10.0.11.0/24) → EKS worker nodes
```

---

## 🛠️ Tech Stack

| Category | Technology | Version | Purpose |
|----------|-----------|---------|---------|
| Cloud | AWS | - | Infrastructure provider |
| IaC | Terraform | >= 1.5 | Infrastructure as Code |
| App | Python Flask | 3.x | Web application |
| Container | Docker | >= 24 | Application containerization |
| Registry | Amazon ECR | - | Private Docker image storage |
| Orchestration | Amazon EKS | 1.29 | Managed Kubernetes |
| Load Balancer | AWS ALB | - | Traffic routing & switching |
| CI/CD | Jenkins | 2.x | Automated pipeline |
| Source Control | GitHub | - | Code repo + webhooks |
| Monitoring | CloudWatch | - | Logs, metrics, alarms |
| Alerting | Amazon SNS | - | Email notifications |

---

## 📁 Project Structure

```
aws-eks-bluegreen-cicd/
│
├── app/                          # Flask web application
│   ├── app.py                    # Main app — returns color/version JSON
│   ├── requirements.txt          # Python dependencies
│   └── tests/                   # Unit tests
│       └── test_app.py
│
├── docker/                       # Docker configuration
│   └── Dockerfile                # Multi-stage build (Alpine base)
│
├── jenkins/                      # CI/CD pipeline
│   └── Jenkinsfile               # 10-stage declarative pipeline
│
├── k8s/                          # Kubernetes manifests
│   ├── blue/
│   │   ├── deployment.yaml       # Blue: 2 replicas, liveness/readiness probes
│   │   └── service.yaml          # ClusterIP service for blue pods
│   ├── green/
│   │   ├── deployment.yaml       # Green: identical to blue
│   │   └── service.yaml          # ClusterIP service for green pods
│   └── ingress/
│       └── ingress.yaml          # ALB ingress — THIS controls which color is live
│
├── scripts/                      # Automation scripts
│   ├── switch-traffic.sh         # Safe blue-green traffic switch with verification
│   └── cleanup.sh                # Scale down inactive deployment (save costs)
│
├── terraform/                    # Infrastructure as Code
│   ├── backend.tf                # S3 remote state + DynamoDB locking
│   ├── main.tf                   # Root module — calls all sub-modules
│   ├── variables.tf              # Input variable declarations
│   ├── outputs.tf                # Useful output values
│   ├── terraform.tfvars          # Your actual values (gitignored!)
│   └── modules/
│       ├── vpc/                  # VPC, subnets, IGW, NAT Gateway, route tables
│       ├── ecr/                  # ECR repository + lifecycle policy
│       ├── eks/                  # EKS cluster + node group + IAM roles + OIDC
│       ├── alb/                  # ALB controller via Helm + IRSA
│       ├── jenkins/              # Jenkins EC2 + IAM role + security group
│       └── cloudwatch/           # Log groups + alarms + dashboard + SNS
│
├── .gitignore                    # Excludes: *.tfstate, *.pem, .env, .terraform/
├── .dockerignore                 # Excludes: terraform/, .git/, *.pem, venv/
└── README.md                     # This file
```

---

## ✅ Prerequisites

### Tools Required (on your laptop)

```bash
aws --version        # AWS CLI v2+
terraform --version  # Terraform 1.5+
kubectl version      # kubectl 1.29+
docker --version     # Docker 24+
helm version         # Helm 3+
git --version        # Git 2+
```

### AWS Setup

```bash
# Configure AWS CLI
aws configure
# Enter: Access Key ID, Secret Access Key, Region (ap-south-1), Output (json)

# Verify
aws sts get-caller-identity
```

### Create terraform.tfvars

```hcl
# terraform/terraform.tfvars  (NEVER commit this file!)
aws_region            = "ap-south-1"
project_name          = "bg-project"
environment           = "dev"
vpc_cidr              = "10.0.0.0/16"
availability_zones    = ["ap-south-1a", "ap-south-1b"]
public_subnets        = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnets       = ["10.0.10.0/24", "10.0.11.0/24"]
node_instance_type    = "t3.small"
desired_nodes         = 2
min_nodes             = 1
max_nodes             = 3
jenkins_instance_type = "t3.small"
key_pair_name         = "your-key-pair-name"
alert_email           = "your-email@example.com"
```

---

## 📖 Step-by-Step Setup

### 1. Terraform Infrastructure

#### Phase 1 — Bootstrap Remote State

```bash
cd terraform/

# Apply only the backend resources first
terraform apply \
  -target=aws_s3_bucket.terraform_state \
  -target=aws_s3_bucket_versioning.terraform_state \
  -target=aws_s3_bucket_server_side_encryption_configuration.terraform_state \
  -target=aws_s3_bucket_public_access_block.terraform_state \
  -target=aws_dynamodb_table.terraform_lock

# Uncomment the backend block in backend.tf, then migrate state
terraform init -migrate-state
```

#### Phase 2 — Deploy Infrastructure Modules

```bash
# Networking
terraform apply -target=module.vpc

# Container registry
terraform apply -target=module.ecr

# Kubernetes cluster (takes ~15 min)
terraform apply -target=module.eks

# Configure kubectl
aws eks update-kubeconfig --name bg-project-eks --region ap-south-1
kubectl get nodes  # verify

# ALB controller (Helm)
helm repo add eks https://aws.github.io/eks-charts
helm repo update
terraform apply -target=module.alb

# Jenkins CI/CD server
terraform apply -target=module.jenkins

# CloudWatch monitoring
terraform apply -target=module.cloudwatch

# Final sync
terraform apply
```

#### Infrastructure Summary

| Module | Resources Created |
|--------|-----------------|
| VPC | VPC, 4 subnets (2 public, 2 private), IGW, NAT GW, route tables |
| ECR | Repository with lifecycle policy (keep 10 images) |
| EKS | Cluster v1.29, node group (2x t3.small), IAM roles, OIDC provider |
| ALB | Load Balancer Controller via Helm, IRSA service account |
| Jenkins | EC2 t3.small, IAM role, security group (8080, 22) |
| CloudWatch | 2 log groups, 3 alarms, dashboard, SNS topic |

---

### 2. Kubernetes Manifests

#### Apply All Manifests

```bash
# Deploy blue and green
kubectl apply -f k8s/blue/deployment.yaml
kubectl apply -f k8s/blue/service.yaml
kubectl apply -f k8s/green/deployment.yaml
kubectl apply -f k8s/green/service.yaml

# Create ALB via ingress
kubectl apply -f k8s/ingress/ingress.yaml

# Verify (wait ~2 min for ALB to provision)
kubectl get pods
kubectl get ingress bg-ingress
```

#### Test Application

```bash
ALB=$(kubectl get ingress bg-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl http://$ALB
# {"app":"AWS DevOps Blue-Green Demo","color":"blue","message":"Hello from BLUE deployment!"}
```

#### Manual Traffic Switch

```bash
# Switch to green
kubectl patch ingress bg-ingress --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"green-service"}]'

# Switch back to blue
kubectl patch ingress bg-ingress --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"blue-service"}]'
```

---

### 3. Jenkins CI/CD

#### Configure kubectl on Jenkins Server

```bash
# SSH into Jenkins
ssh -i ~/your-key.pem ubuntu@<jenkins-public-ip>

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Install kubectl
curl -LO "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl"
sudo chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Configure for Jenkins user
sudo -u jenkins aws eks update-kubeconfig \
  --name bg-project-eks \
  --region ap-south-1 \
  --kubeconfig /var/lib/jenkins/.kube/config
```

#### Authorize Jenkins IAM Role in EKS

```bash
# On your LAPTOP — edit aws-auth ConfigMap
kubectl edit configmap aws-auth -n kube-system

# Add under mapRoles:
#   - rolearn: arn:aws:iam::<account-id>:role/bg-project-jenkins-role
#     username: jenkins
#     groups:
#       - system:masters
```

#### Add Jenkins user to Docker group

```bash
# On Jenkins server
sudo usermod -aG docker jenkins
sudo chmod 666 /var/run/docker.sock
sudo systemctl restart jenkins
```

#### Create Jenkins Pipeline Job

```
1. Open http://<jenkins-ip>:8080
2. New Item → aws-eks-bluegreen-cicd → Pipeline → OK
3. Configure:
   - General: ✅ GitHub project → URL of your repo
   - Triggers: ✅ GitHub hook trigger for GITScm polling
   - Pipeline: Definition = Pipeline script from SCM
               SCM = Git
               Repo URL = https://github.com/<you>/aws-eks-bluegreen-cicd.git
               Branch = */main
               Script Path = jenkins/Jenkinsfile
4. Save
```

---

### 4. GitHub Webhook

```
GitHub Repo → Settings → Webhooks → Add webhook

Payload URL:   http://<jenkins-ip>:8080/github-webhook/
Content type:  application/json
Events:        ✅ Just the push event
→ Add webhook
```

Now every `git push` to main automatically triggers the Jenkins pipeline! 🎉

---

## ⚙️ Pipeline Flow

```
git push origin main
        │
        ▼
GitHub Webhook fires → Jenkins triggered (Build #N)
        │
        ├── Stage 1: Checkout SCM (1s)
        │   └── Pull latest code from GitHub
        │
        ├── Stage 2: Determine Deploy Target (3s)
        │   └── Read ingress → find inactive color
        │       blue active? → deploy to green
        │       green active? → deploy to blue
        │
        ├── Stage 3: Run Tests (9s)
        │   └── python pytest — catch bugs early
        │
        ├── Stage 4: Build Docker Image (6s)
        │   └── docker build -t image:v1.0-{BUILD_NUMBER}
        │
        ├── Stage 5: Push to ECR (3s)
        │   └── authenticate + docker push
        │
        ├── Stage 6: Deploy to Inactive (20s)
        │   └── kubectl set image on inactive deployment
        │       K8s rolling update — pods replaced one by one
        │
        ├── Stage 7: Health Check (4s)
        │   └── kubectl wait --for=condition=Ready
        │       ALL pods must be Ready before switching
        │
        ├── Stage 8: Switch Traffic (24s)
        │   └── ./scripts/switch-traffic.sh <color>
        │       Patches ingress backend → ALB updates
        │
        ├── Stage 9: Verify Live (10s)
        │   └── curl ALB → check color in response
        │       Confirms new version is actually serving
        │
        └── Stage 10: Cleanup Old (7s)
            └── ./scripts/cleanup.sh <old-color>
                Scale down old deployment to 0 replicas
                (saves compute costs)

Total: ~1 min 33 seconds | Downtime: 0 seconds ✅
```

---

## 📜 Scripts Reference

### switch-traffic.sh

Safely switches ALB traffic between blue and green with health checks and verification.

```bash
./scripts/switch-traffic.sh green   # switch to green
./scripts/switch-traffic.sh blue    # switch to blue (or rollback)
```

**What it does:**
1. Validates input (must be `blue` or `green`)
2. Checks if already on target — exits early if yes
3. Verifies target deployment has all pods Ready
4. Patches the Kubernetes Ingress backend service
5. Waits 15 seconds for ALB to propagate change
6. Curls ALB up to 10 times to confirm new color is serving

### cleanup.sh

Scales down the inactive (non-live) deployment to zero replicas to save costs.

```bash
./scripts/cleanup.sh blue    # after switching to green
./scripts/cleanup.sh green   # after switching to blue
```

**Safety:** Will refuse to scale down the ACTIVE deployment. Always reads the ingress first to confirm which color is live before touching anything.

**Rollback:** If you need to rollback, `switch-traffic.sh` will automatically scale the deployment back up before switching traffic.

---

## 📊 Monitoring

### CloudWatch Dashboard

```
https://ap-south-1.console.aws.amazon.com/cloudwatch/home
  → Dashboards → bg-project-dashboard
```

Widgets: Node CPU %, Node Memory %, Pod Restart Count, Active Alarms

### Alarms

| Alarm | Metric | Threshold | Period |
|-------|--------|-----------|--------|
| node_cpu_high | ContainerInsights CPU | > 80% | 10 min |
| node_memory_high | ContainerInsights Memory | > 80% | 10 min |
| pod_restarts | ContainerInsights Restarts | > 5 | 5 min |

All alarms → SNS → Email notification

### Log Groups

| Group | Contents | Retention |
|-------|---------|-----------|
| /aws/eks/bg-project-eks/cluster | Control plane logs | 7 days |
| /aws/eks/bg-project-eks/app | Application logs | 7 days |

---

## 💰 Cost Estimate (ap-south-1)

| Resource | $/hour | $/day |
|---------|--------|-------|
| EKS Control Plane | $0.100 | $2.40 |
| 2x t3.small (nodes) | $0.042 | $1.01 |
| 1x t3.small (Jenkins) | $0.021 | $0.50 |
| NAT Gateway | $0.045 | $1.08 |
| ALB | $0.008 | $0.19 |
| **Total** | **~$0.22** | **~$5.18** |

> ⚠️ Always destroy resources when not in use to avoid ongoing charges!

---

## 🗑️ Cleanup

```bash
# Step 1: Delete Kubernetes resources (this deletes the ALB too)
kubectl delete -f k8s/ingress/ingress.yaml
kubectl delete -f k8s/blue/
kubectl delete -f k8s/green/

# Step 2: Wait for ALB deletion (~2 min)
aws elbv2 describe-load-balancers --region ap-south-1

# Step 3: Destroy all Terraform resources
cd terraform/
terraform destroy
# Type 'yes' — takes 10-15 min
```

> ⚠️ Always delete the Ingress BEFORE running `terraform destroy`. Otherwise the ALB may block VPC deletion.

---

## 🔒 Security Highlights

- EKS nodes in **private subnets** — no direct internet exposure
- **IRSA** (IAM Roles for Service Accounts) — ALB controller gets minimal permissions
- **IAM Roles** for Jenkins (no access keys stored anywhere)
- **aws-auth ConfigMap** — explicit authorization of Jenkins role in EKS
- **Security Groups** — Jenkins only exposes ports 8080 and 22
- **No credentials in code** — all secrets via IAM roles and instance profiles
- ECR images can be **scanned on push** for vulnerabilities

---

## 👤 Author

**Akshay Kumar**
- GitHub: [@Akshay-Techie](https://github.com/Akshay-Techie)

---

## 📄 License

MIT License — free to use, modify, and distribute.