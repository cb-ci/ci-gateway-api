#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-scaleDownNodePools.sh — Scale every node pool in the GKE cluster to zero
# nodes, to park the environment without destroying it. GKE counterpart of
# eks/eksctl/01-scaleDownNodePools.sh.
#
# HOW
#   GKE's node autoscaler would immediately undo a manual resize, so for each
#   pool this script (1) disables autoscaling, then (2) resizes the pool to 0.
#   00-scaleUpNodePools.sh resizes back and re-enables autoscaling.
#
# STATE
#   Per pool, the autoscaling setting (enabled/min/max) and the current node
#   count are written to .nodepool-scale-state.json before anything changes.
#   Current node count comes from `kubectl get nodes`; if that is unavailable
#   it falls back to the pool's min (or 1). Keep that file — without it,
#   scale-up falls back to NODEPOOL_MIN/DESIRED/MAX.
#
# WHAT THIS DOES NOT SAVE YOU
#   Scaling to zero stops Compute Engine VM charges only. You still pay for the
#   GKE cluster management fee (if not covered by the free tier), persistent
#   disks (PVCs), the load balancer / forwarding rule, and static IPs.
#
# GRACEFUL SHUTDOWN
#   Without --drain, VMs are deleted and pods get whatever grace the kubelet
#   manages. For CloudBees CI this means CJOC is killed rather than shut down
#   cleanly. Pass --drain to cordon and evict first.
#
# Usage:
#   ./00-scaleDownNodePools.sh              # scale all pools to 0
#   ./00-scaleDownNodePools.sh --drain      # cordon + drain nodes first
#   ./00-scaleDownNodePools.sh --yes        # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/_functions.sh"
load_env "${SCRIPT_DIR}/../.env"
validate_vars PROJECT_ID CLUSTER_NAME ZONE
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_nodepools-lib.sh"

DRAIN=false
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --drain)   DRAIN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *)         error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

check_command gcloud
check_command jq

# =============================================================================
# 1. DISCOVER POOLS + CURRENT SIZES
# =============================================================================
log "Listing node pools in cluster '${CLUSTER_NAME}' (${ZONE})..."
POOLS=$(gcloud container node-pools list --project "${PROJECT_ID}" --cluster "${CLUSTER_NAME}" \
  --zone "${ZONE}" --format='value(name)')
[[ -n "$POOLS" ]] || error "no node pools found for cluster '${CLUSTER_NAME}'"

# Build the state document first so nothing is mutated before it is recorded.
STATE='{}'
echo
printf '%-20s %12s %6s %6s %8s\n' "NODEPOOL" "AUTOSCALING" "MIN" "MAX" "NODES"
for pool in $POOLS; do
  CFG=$(gcloud container node-pools describe "$pool" --project "${PROJECT_ID}" \
    --cluster "${CLUSTER_NAME}" --zone "${ZONE}" --format=json)

  AS=$(jq -r '.autoscaling.enabled // false' <<< "$CFG")
  MIN=$(jq -r '.autoscaling.minNodeCount // 0' <<< "$CFG")
  MAX=$(jq -r '.autoscaling.maxNodeCount // 0' <<< "$CFG")

  NODES=""
  if command -v kubectl >/dev/null 2>&1; then
    NODES=$(kubectl get nodes -l "cloud.google.com/gke-nodepool=${pool}" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
  fi
  # No kubectl / no registered nodes: assume the pool's min (at least 1) so scale-up restores something usable.
  if [[ -z "$NODES" || "$NODES" == 0 ]]; then
    NODES=$(( MIN > 0 ? MIN : 1 ))
  fi
  # Static pools carry their size in initialNodeCount only; max stays >= desired for scale-up validation.
  (( MAX >= NODES )) || MAX="$NODES"

  printf '%-20s %12s %6s %6s %8s\n' "$pool" "$AS" "$MIN" "$MAX" "$NODES"
  STATE=$(jq --arg n "$pool" --argjson a "$AS" --argjson mn "$MIN" --argjson mx "$MAX" --argjson d "$NODES" \
    '.[$n] = {autoscaling: $a, minNodes: $mn, maxNodes: $mx, desiredNodes: $d}' <<< "$STATE")
done
echo

if [[ -f "$STATE_FILE" ]] && [[ -z "$(kubectl get nodes --no-headers 2>/dev/null || true)" ]]; then
  warn "No nodes are registered and ${STATE_FILE} already exists — the cluster looks already scaled down."
  warn "Not overwriting it; it holds the sizes to scale back up to."
  exit 0
fi

# =============================================================================
# 2. CONFIRM
# =============================================================================
echo "Cluster: $(kubectl config current-context 2>/dev/null || echo "${CLUSTER_NAME}")"
echo "This disables autoscaling and resizes every node pool above to 0."
echo "Every pod in the cluster will stop running, including CJOC."
$DRAIN && echo "Nodes will be cordoned and drained first."
echo "Prior sizes are saved to ${STATE_FILE} for 00-scaleUpNodePools.sh."
echo
confirm "Proceed?"

# Written before any mutation: if a call fails halfway, the state file still
# describes what to restore.
printf '%s\n' "$STATE" | jq '.' > "$STATE_FILE"
success "Saved current sizes to ${STATE_FILE}"

# =============================================================================
# 3. OPTIONAL DRAIN
# =============================================================================
if [[ "$DRAIN" == true ]]; then
  check_command kubectl
  log "Cordoning and draining nodes..."
  # --force / --disable-eviction: with every node going away there is nowhere to
  # reschedule, and PodDisruptionBudgets (kube-dns, metrics-server) can never be
  # satisfied while every node is cordoned.
  for node in $(kubectl get nodes -o name 2>/dev/null || true); do
    log "  ${node}"
    kubectl drain "$node" \
      --ignore-daemonsets --delete-emptydir-data --force --disable-eviction \
      --grace-period=60 --timeout=180s || warn "  drain of ${node} did not complete"
  done
  success "Nodes drained."
fi

# =============================================================================
# 4. DISABLE AUTOSCALING, THEN SCALE TO ZERO
# =============================================================================
for pool in $POOLS; do
  if [[ "$(jq -r --arg n "$pool" '.[$n].autoscaling' <<< "$STATE")" == true ]]; then
    log "Disabling autoscaling on '${pool}'..."
    gcloud container node-pools update "$pool" --project "${PROJECT_ID}" \
      --cluster "${CLUSTER_NAME}" --zone "${ZONE}" --no-enable-autoscaling --quiet
  fi
  log "Resizing '${pool}' to 0..."
  gcloud container clusters resize "${CLUSTER_NAME}" --project "${PROJECT_ID}" \
    --zone "${ZONE}" --node-pool "$pool" --num-nodes 0 --quiet
done
success "All node pools scaled to 0."

echo
echo "Verify:"
echo "  gcloud container node-pools list --cluster ${CLUSTER_NAME} --zone ${ZONE} --project ${PROJECT_ID}"
echo "  kubectl get nodes            # expect: No resources found"
echo
echo "Scale back up with:"
echo "  ./00-scaleUpNodePools.sh"
echo
warn "Still billing: persistent disks (PVCs), load balancer / forwarding rule, static IPs, cluster fee."
