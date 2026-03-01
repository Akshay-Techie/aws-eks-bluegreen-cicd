#!/bin/bash
# ============================================================
# JENKINS SERVER BOOTSTRAP SCRIPT
# This runs automatically when EC2 instance starts
# Installs: Java, Jenkins, Docker, AWS CLI, kubectl, Helm
# ============================================================

set -e  # exit on any error
exec > /var/log/userdata.log 2>&1  # log everything

echo "============================================"
echo "Starting Jenkins bootstrap - $(date)"
echo "============================================"

# ============================================================
# STEP 1 — System Update
# ============================================================
apt-get update -y
apt-get upgrade -y

# ============================================================
# STEP 2 — Install Java 17
# Jenkins requires Java to run
# Java 17 = LTS version, supported by Jenkins
# ============================================================
echo "Installing Java 17..."
apt-get install -y openjdk-17-jdk

# Verify
java -version

# ============================================================
# STEP 3 — Install Jenkins
# Add Jenkins official repo → install latest stable
# ============================================================
echo "Installing Jenkins..."

# Add Jenkins GPG key
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | \
  gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg

# Add Jenkins repo
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] \
  https://pkg.jenkins.io/debian-stable binary/" | \
  tee /etc/apt/sources.list.d/jenkins.list > /dev/null

# Install Jenkins
apt-get update -y
apt-get install -y jenkins

# Start and enable Jenkins
systemctl start jenkins
systemctl enable jenkins

echo "Jenkins installed and started"

# ============================================================
# STEP 4 — Install Docker
# Jenkins will use Docker to build images
# ============================================================
echo "Installing Docker..."

apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repo
echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io

# Start Docker
systemctl start docker
systemctl enable docker

# Add jenkins user to docker group
# So Jenkins can run docker commands without sudo
usermod -aG docker jenkins
usermod -aG docker ubuntu

echo "Docker installed"

# ============================================================
# STEP 5 — Install AWS CLI v2
# Jenkins uses this to:
# → Push images to ECR (aws ecr get-login-password)
# → Update kubeconfig (aws eks update-kubeconfig)
# → Interact with AWS services
# ============================================================
echo "Installing AWS CLI..."

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  -o "awscliv2.zip"
apt-get install -y unzip
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# Verify
aws --version

# ============================================================
# STEP 6 — Install kubectl
# Jenkins uses this to deploy to EKS
# kubectl apply -f k8s/blue/deployment.yaml
# ============================================================
echo "Installing kubectl..."

curl -LO "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/kubectl

# Verify
kubectl version --client

# ============================================================
# STEP 7 — Install Helm
# Jenkins uses Helm to manage K8s applications
# ============================================================
echo "Installing Helm..."

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

# ============================================================
# STEP 8 — Configure ECR credential helper
# Allows Docker to authenticate with ECR automatically
# Without this: must run aws ecr get-login-password every time
# With this: Docker handles auth automatically
# ============================================================
echo "Installing ECR credential helper..."

apt-get install -y amazon-ecr-credential-helper

# Configure Docker to use ECR credential helper
mkdir -p /home/ubuntu/.docker
cat > /home/ubuntu/.docker/config.json << 'EOF'
{
  "credHelpers": {
    "public.ecr.aws": "ecr-login",
    "${ecr_repo_url_domain}": "ecr-login"
  }
}
EOF

# Same for Jenkins user
mkdir -p /var/lib/jenkins/.docker
cp /home/ubuntu/.docker/config.json /var/lib/jenkins/.docker/config.json
chown -R jenkins:jenkins /var/lib/jenkins/.docker

# ============================================================
# STEP 9 — Restart Jenkins to apply group changes
# Jenkins needs restart to pick up docker group membership
# ============================================================
systemctl restart jenkins

echo "============================================"
echo "Bootstrap complete - $(date)"
echo "Jenkins URL: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080"
echo "Initial Admin Password:"
cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || \
  echo "Password not ready yet - check in 2 minutes"
echo "============================================"