#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-scaleDonwNodePools.sh — Scale every managed node group in the cluster to
# zero nodes, to park the environment without destroying it.
#
# WHY minSize HAS TO CHANGE TOO
#   desiredSize can never be below minSize, and eksctl-config.yaml sets
#   minSize: 1 on both pools. So "scale to zero" means minSize=0 AND
#   desiredSize=0. maxSize is left alone (AWS requires it to be >= 1).
#   01-scaleUpNodePools.sh restores the original values.
#
# STATE
#   The current scalingConfig of every node group is written to
#   .nodepool-scale-state.json before anything changes. The scale-up script
#   reads it back, so the pools return to exactly what they were rather than
#   to a hardcoded guess. Keep that file — without it, scaling up falls back
#   to defaults.
#
# WHAT THIS DOES NOT SAVE YOU
#   Scaling nodes to zero stops EC2 charges only. You still pay for:
#     - the EKS control plane (billed per cluster-hour regardless of nodes)
#     - the NAT gateway
#     - the ALB
#     - every EBS volume and the EFS file system
#   To stop those, tear down properly (01-deleteCluster.sh and friends).
#
# GRACEFUL SHUTDOWN
#   Without --drain, instances are terminated by the ASG and pods get whatever
#   grace the kubelet manages on the way down. For CloudBees CI this means CJOC
#   is killed rather than shut down cleanly, which can leave JENKINS_HOME
#   dirty. Pass --drain to cordon and evict first.
#
# Usage:
#   ./01-scaleDonwNodePools.sh              # scale all pools to 0
#   ./01-scaleDonwNodePools.sh --drain      # cordon + drain nodes first
#   ./01-scaleDonwNodePools.sh --no-wait    # don't block until nodes are gone
#   ./01-scaleDonwNodePools.sh --yes        # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STATE_FILE="${NODEPOOL_STATE_FILE:-.nodepool-scale-state.json}"

DRAIN=false
WAIT=true
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drain)    DRAIN=true ;;
    --no-wait)  WAIT=false ;;
    --yes|-y)   ASSUME_YES=true ;;
    -h|--help)  sed -n '2,38p' "$0"; exit 0 ;;
    *)          error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

# =============================================================================
# 1. DISCOVER NODE GROUPS + CURRENT SIZES
# =============================================================================
log "Listing managed node groups in cluster '${CLUSTER_NAME}' (${AWS_REGION})..."
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'nodegroups[]' --output text 2>/dev/null || true)

[[ -n "$NODEGROUPS" ]] || error "no managed node groups found for cluster '${CLUSTER_NAME}'"

# Build the state document first so nothing is mutated before it is recorded.
STATE='{}'
echo
printf '%-20s %8s %8s %8s\n' "NODEGROUP" "MIN" "DESIRED" "MAX"
for ng in $NODEGROUPS; do
  CFG=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
    --region "$AWS_REGION" --query 'nodegroup.scalingConfig' --output json)

  MIN=$(jq -r '.minSize'     <<< "$CFG")
  DES=$(jq -r '.desiredSize' <<< "$CFG")
  MAX=$(jq -r '.maxSize'     <<< "$CFG")

  printf '%-20s %8s %8s %8s\n' "$ng" "$MIN" "$DES" "$MAX"
  STATE=$(jq --arg n "$ng" --argjson c "$CFG" '.[$n] = $c' <<< "$STATE")
done
echo

ALREADY_ZERO=$(jq -r '[to_entries[] | select(.value.desiredSize > 0)] | length' <<< "$STATE")
if [[ "$ALREADY_ZERO" == "0" ]]; then
  warn "Every node group is already at desiredSize 0. Nothing to do."
  warn "Not overwriting ${STATE_FILE} — it holds the sizes to scale back up to."
  exit 0
fi

# =============================================================================
# 2. CONFIRM
# =============================================================================
echo "Cluster: $(kubectl config current-context 2>/dev/null || echo "$CLUSTER_NAME")"
echo "This sets minSize=0 and desiredSize=0 on every node group above."
echo "Every pod in the cluster will stop running, including CJOC."
$DRAIN && echo "Nodes will be cordoned and drained first."
echo "Prior sizes are saved to ${STATE_FILE} for 01-scaleUpNodePools.sh."
echo

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# Written before any mutation: if the scaling calls fail halfway, the state
# file still describes what to restore.
printf '%s\n' "$STATE" | jq '.' > "$STATE_FILE"
success "Saved current sizes to ${STATE_FILE}"

# =============================================================================
# 3. OPTIONAL DRAIN
# =============================================================================
if [[ "$DRAIN" == true ]]; then
  command -v kubectl >/dev/null 2>&1 || error "--drain needs kubectl on PATH"
  log "Cordoning and draining nodes..."
  # --force is required: with every node going away there is nowhere to
  # reschedule, so eviction would otherwise block indefinitely.
  for node in $(kubectl get nodes -o name 2>/dev/null || true); do
    log "  ${node}"
    kubectl drain "$node" \
      --ignore-daemonsets --delete-emptydir-data --force \
      --grace-period=60 --timeout=180s || warn "  drain of ${node} did not complete"
  done
  success "Nodes drained."
fi

# =============================================================================
# 4. SCALE TO ZERO
# =============================================================================
for ng in $NODEGROUPS; do
  MAX=$(jq -r --arg n "$ng" '.[$n].maxSize' <<< "$STATE")
  log "Scaling '${ng}' to min=0 desired=0 (max stays ${MAX})..."
  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$ng" \
    --region "$AWS_REGION" \
    --scaling-config "minSize=0,maxSize=${MAX},desiredSize=0" \
    >/dev/null
done
success "Scale-down requested for all node groups."

# =============================================================================
# 5. WAIT
# =============================================================================
if [[ "$WAIT" == true ]]; then
  log "Waiting for node groups to finish updating..."
  for ng in $NODEGROUPS; do
    printf '  %s ' "$ng"
    for _ in $(seq 1 60); do
      STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$ng" --region "$AWS_REGION" \
        --query 'nodegroup.status' --output text 2>/dev/null || echo UNKNOWN)
      [[ "$STATUS" == "ACTIVE" ]] && break
      printf '.'
      sleep 10
    done
    echo " ${STATUS}"
  done
fi

echo
success "All node groups scaled to zero."
echo
echo "Verify:"
echo "  aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}"
echo "  kubectl get nodes            # expect: No resources found"
echo "  kubectl get pods -A          # expect: everything Pending"
echo
echo "Scale back up with:"
echo "  ./01-scaleUpNodePools.sh"
echo
warn "Still billing: EKS control plane, NAT gateway, ALB, EBS volumes, EFS."
