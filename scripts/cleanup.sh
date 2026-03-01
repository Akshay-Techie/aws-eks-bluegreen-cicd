#!/bin/bash
# ============================================================
# CLEANUP.SH
# Scales down the inactive deployment after traffic switch
#
# USAGE:
#   ./scripts/cleanup.sh blue    ← scale down blue (green is live)
#   ./scripts/cleanup.sh green   ← scale down green (blue is live)
#
# WHEN TO USE:
#   After successful blue-green switch:
#   1. Switch traffic: blue → green (green is now live)
#   2. Monitor green for 5-10 minutes
#   3. If stable → run: ./scripts/cleanup.sh blue
#   4. Blue scaled to 0 → saves money
#   5. Blue deployment stays (config preserved for rollback)
#
# IMPORTANT:
#   This does NOT delete the deployment
#   Just scales replicas to 0 → no pods running → no cost
#   To rollback: ./scripts/switch-traffic.sh blue
#   → switch.sh will scale blue back up automatically
# ============================================================

set -e

# ── CONFIGURATION ──────────────────────────────────────────
NAMESPACE="default"
INGRESS_NAME="bg-ingress"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
  echo -e "${2}[$(date '+%H:%M:%S')] $1${NC}"
}

# ── MAIN ───────────────────────────────────────────────────

# Validate input
if [ -z "$1" ]; then
  echo ""
  log "ERROR: No target specified" "$RED"
  echo ""
  echo "Usage: $0 <blue|green>"
  echo ""
  echo "Examples:"
  echo "  $0 blue    ← scale down blue  (after switching to green)"
  echo "  $0 green   ← scale down green (after switching to blue)"
  echo ""
  exit 1
fi

TARGET=$1

if [ "$TARGET" != "blue" ] && [ "$TARGET" != "green" ]; then
  log "ERROR: Must be 'blue' or 'green'" "$RED"
  exit 1
fi

TARGET_DEPLOYMENT="${TARGET}-deployment"

# Safety check — make sure we're not scaling down the ACTIVE deployment
ACTIVE_SERVICE=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}')
ACTIVE_COLOR=$(echo "$ACTIVE_SERVICE" | cut -d'-' -f1)

echo ""
log "════════════════════════════════════════" "$BLUE"
log "  CLEANUP — Scale Down Inactive" "$BLUE"
log "  Target to scale down: $TARGET" "$BLUE"
log "  Currently active:     $ACTIVE_COLOR" "$BLUE"
log "════════════════════════════════════════" "$BLUE"
echo ""

# Safety — never scale down the active deployment
if [ "$TARGET" = "$ACTIVE_COLOR" ]; then
  log "❌ SAFETY CHECK FAILED!" "$RED"
  log "Cannot scale down $TARGET — it is currently ACTIVE!" "$RED"
  log "Active deployment: $ACTIVE_COLOR-service is receiving traffic" "$RED"
  echo ""
  log "To scale down the inactive deployment:" "$YELLOW"
  if [ "$TARGET" = "blue" ]; then
    log "First switch to blue: ./scripts/switch-traffic.sh blue" "$YELLOW"
    log "Then cleanup green:   ./scripts/cleanup.sh green" "$YELLOW"
  else
    log "First switch to green: ./scripts/switch-traffic.sh green" "$YELLOW"
    log "Then cleanup blue:     ./scripts/cleanup.sh blue" "$YELLOW"
  fi
  exit 1
fi

# Show current state
CURRENT_REPLICAS=$(kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
log "Current replicas: $CURRENT_REPLICAS" "$YELLOW"

# Scale down to 0
log "Scaling down $TARGET_DEPLOYMENT to 0 replicas..." "$YELLOW"
kubectl scale deployment "$TARGET_DEPLOYMENT" \
  --replicas=0 \
  -n "$NAMESPACE"

# Wait for pods to terminate
log "Waiting for $TARGET pods to terminate..." "$YELLOW"
kubectl wait --for=delete pod \
  -l "app=bg-app,version=$TARGET" \
  -n "$NAMESPACE" \
  --timeout=60s 2>/dev/null || true

# Verify
REMAINING=$(kubectl get pods -n "$NAMESPACE" \
  -l "app=bg-app,version=$TARGET" \
  --no-headers 2>/dev/null | wc -l)

echo ""
log "════════════════════════════════════════" "$GREEN"
log "  ✅ CLEANUP COMPLETE!" "$GREEN"
log "  $TARGET scaled to 0 replicas" "$GREEN"
log "  $REMAINING $TARGET pods remaining" "$GREEN"
log "" "$GREEN"
log "  Active deployment: $ACTIVE_COLOR (still running)" "$GREEN"
log "" "$GREEN"
log "  To scale $TARGET back up (rollback):" "$GREEN"
log "  ./scripts/switch-traffic.sh $TARGET" "$GREEN"
log "════════════════════════════════════════" "$GREEN"
echo ""