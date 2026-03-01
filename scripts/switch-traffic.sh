#!/bin/bash
# ============================================================
# SWITCH-TRAFFIC.SH
# Switches ALB traffic between blue and green deployments
#
# USAGE:
#   ./scripts/switch-traffic.sh blue    ← switch to blue
#   ./scripts/switch-traffic.sh green   ← switch to green
#
# WHAT THIS SCRIPT DOES:
#   1. Validates input (must be blue or green)
#   2. Checks target deployment is healthy
#   3. Waits for all pods to be ready
#   4. Switches ALB ingress to target
#   5. Verifies switch was successful
#
# HOW BLUE-GREEN SWITCH WORKS:
#   Ingress has one line: backend.service.name
#   blue-service  → traffic goes to blue pods
#   green-service → traffic goes to green pods
#   We patch that one line → ALB updates → done
# ============================================================

set -e  # exit immediately if any command fails

# ── CONFIGURATION ──────────────────────────────────────────
ALB_URL="k8s-default-bgingres-2cbac6846c-907229940.ap-south-1.elb.amazonaws.com"
NAMESPACE="default"
INGRESS_NAME="bg-ingress"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ── FUNCTIONS ──────────────────────────────────────────────

# Print colored message
log() {
  echo -e "${2}[$(date '+%H:%M:%S')] $1${NC}"
}

# Check if deployment is healthy
check_deployment_health() {
  local deployment=$1
  local namespace=$2

  log "Checking health of $deployment..." "$YELLOW"

  # Get desired vs ready replicas
  DESIRED=$(kubectl get deployment "$deployment" -n "$namespace" \
    -o jsonpath='{.spec.replicas}')
  READY=$(kubectl get deployment "$deployment" -n "$namespace" \
    -o jsonpath='{.status.readyReplicas}')

  # Handle case where readyReplicas is empty (0 ready)
  READY=${READY:-0}

  log "Deployment $deployment: $READY/$DESIRED pods ready" "$YELLOW"

  if [ "$READY" -eq "$DESIRED" ] && [ "$DESIRED" -gt 0 ]; then
    log "✅ $deployment is healthy" "$GREEN"
    return 0
  else
    log "❌ $deployment is NOT healthy ($READY/$DESIRED ready)" "$RED"
    return 1
  fi
}

# Wait for deployment to be fully ready
wait_for_deployment() {
  local deployment=$1
  local namespace=$2
  local timeout=120  # 2 minutes timeout

  log "Waiting for $deployment to be ready..." "$YELLOW"

  kubectl rollout status deployment/"$deployment" \
    -n "$namespace" \
    --timeout="${timeout}s"

  if [ $? -eq 0 ]; then
    log "✅ $deployment rollout complete" "$GREEN"
    return 0
  else
    log "❌ $deployment rollout timed out" "$RED"
    return 1
  fi
}

# Get currently active service from ingress
get_active_service() {
  kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}'
}

# Perform the actual switch
switch_ingress() {
  local target_service=$1

  log "Patching ingress to point to $target_service..." "$YELLOW"

  kubectl patch ingress "$INGRESS_NAME" \
    -n "$NAMESPACE" \
    --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/rules/0/http/paths/0/backend/service/name\",\"value\":\"$target_service\"}]"

  log "✅ Ingress patched successfully" "$GREEN"
}

# Verify the switch worked
verify_switch() {
  local expected_color=$1
  local max_attempts=10
  local attempt=1

  log "Verifying switch to $expected_color..." "$YELLOW"

  # Wait for ALB to propagate (usually 10-30 seconds)
  sleep 15

  while [ $attempt -le $max_attempts ]; do
    log "Attempt $attempt/$max_attempts — testing ALB..." "$YELLOW"

    # Call the ALB and check color in response
    RESPONSE=$(curl -s --max-time 10 "http://$ALB_URL" 2>/dev/null || echo "")

    if echo "$RESPONSE" | grep -q "\"color\":\"$expected_color\""; then
      log "✅ VERIFIED! ALB is serving $expected_color traffic" "$GREEN"
      log "Response: $RESPONSE" "$GREEN"
      return 0
    else
      log "Not ready yet, waiting 10 seconds... Response: $RESPONSE" "$YELLOW"
      sleep 10
      attempt=$((attempt + 1))
    fi
  done

  log "❌ Could not verify switch after $max_attempts attempts" "$RED"
  return 1
}

# ── MAIN SCRIPT ────────────────────────────────────────────

# Step 1 — Validate input
if [ -z "$1" ]; then
  echo ""
  log "ERROR: No target specified" "$RED"
  echo ""
  echo "Usage: $0 <blue|green>"
  echo ""
  echo "Examples:"
  echo "  $0 blue    ← switch traffic to blue deployment"
  echo "  $0 green   ← switch traffic to green deployment"
  echo ""
  exit 1
fi

TARGET=$1

if [ "$TARGET" != "blue" ] && [ "$TARGET" != "green" ]; then
  log "ERROR: Target must be 'blue' or 'green', got: $TARGET" "$RED"
  exit 1
fi

echo ""
log "════════════════════════════════════════" "$BLUE"
log "  BLUE-GREEN TRAFFIC SWITCH" "$BLUE"
log "  Target: $TARGET" "$BLUE"
log "════════════════════════════════════════" "$BLUE"
echo ""

# Step 2 — Show current state
CURRENT_SERVICE=$(get_active_service)
log "Current active service: $CURRENT_SERVICE" "$YELLOW"

TARGET_SERVICE="${TARGET}-service"
TARGET_DEPLOYMENT="${TARGET}-deployment"

# Step 3 — Check if already on target
if [ "$CURRENT_SERVICE" = "$TARGET_SERVICE" ]; then
  log "Already on $TARGET! No switch needed." "$GREEN"
  exit 0
fi

# Step 4 — Check target deployment health
log "Step 1/4: Checking $TARGET deployment health..." "$YELLOW"
if ! check_deployment_health "$TARGET_DEPLOYMENT" "$NAMESPACE"; then
  log "❌ Cannot switch — $TARGET deployment is not healthy!" "$RED"
  log "Fix the deployment first, then retry." "$RED"
  exit 1
fi

# Step 5 — Wait for all pods ready
log "Step 2/4: Waiting for all $TARGET pods to be ready..." "$YELLOW"
if ! wait_for_deployment "$TARGET_DEPLOYMENT" "$NAMESPACE"; then
  log "❌ Cannot switch — $TARGET pods not ready!" "$RED"
  exit 1
fi

# Step 6 — Perform the switch
log "Step 3/4: Switching traffic to $TARGET..." "$YELLOW"
switch_ingress "$TARGET_SERVICE"

# Step 7 — Verify
log "Step 4/4: Verifying switch..." "$YELLOW"
if verify_switch "$TARGET"; then
  echo ""
  log "════════════════════════════════════════" "$GREEN"
  log "  ✅ SWITCH COMPLETE!" "$GREEN"
  log "  Traffic is now going to: $TARGET" "$GREEN"
  log "  ALB URL: http://$ALB_URL" "$GREEN"
  log "════════════════════════════════════════" "$GREEN"
  echo ""
else
  log "⚠️  Switch may have worked but verification failed" "$YELLOW"
  log "Check manually: curl http://$ALB_URL" "$YELLOW"
fi