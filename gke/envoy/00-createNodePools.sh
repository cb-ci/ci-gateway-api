#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-createNodePools.sh — Create the controllers / agents / system node pools
# on the existing GKE cluster (GKE equivalent of the managedNodeGroups in
# eks/eksctl/eksctl-config.yaml.tpl). Pool definitions: _nodepools-lib.sh.
#
# Idempotent: pools that already exist are skipped.
#
# Usage:
#   ./00-createNodePools.sh                      # create missing pools (asks first)
#   ./00-createNodePools.sh --dry-run            # print the gcloud commands only
#   ./00-createNodePools.sh --yes                # skip the confirmation prompt
#   ./00-createNodePools.sh --delete-default-pool  # afterwards remove `default-pool`
#                                                  so nothing runs outside the 3 pools
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

DRY_RUN=false
ASSUME_YES=false
DELETE_DEFAULT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)             DRY_RUN=true ;;
    --yes|-y)              ASSUME_YES=true ;;
    --delete-default-pool) DELETE_DEFAULT=true ;;
    -h|--help)             sed -n '2,15p' "$0"; exit 0 ;;
    *)                     error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

check_command gcloud

log "Cluster ${CLUSTER_NAME} (${PROJECT_ID}, ${ZONE}) — pools to ensure:"
printf '  %-12s %-16s %6s  %-24s %s\n' POOL MACHINE DISK LABEL TAINT
for def in "${NODEPOOLS[@]}"; do
  IFS='|' read -r name machine disk wl tainted <<< "$def"
  printf '  %-12s %-16s %5sG  %-24s %s\n' "$name" "$machine" "$disk" "workload=${wl}" \
    "$([[ $tainted == true ]] && echo "workload=${wl}:NoSchedule" || echo none)"
done
log "Size: ${NODEPOOL_DESIRED} node(s), autoscaling ${NODEPOOL_MIN}-${NODEPOOL_MAX} (per pool)."
confirm "Create missing node pools?"

for def in "${NODEPOOLS[@]}"; do
  IFS='|' read -r name machine disk wl tainted <<< "$def"

  if nodepool_exists "$name"; then
    warn "Node pool '${name}' already exists — skipping."
    continue
  fi

  args=(
    container node-pools create "$name"
    --project "${PROJECT_ID}" --cluster "${CLUSTER_NAME}" --zone "${ZONE}"
    --machine-type "$machine"
    --disk-type "${NODEPOOL_DISK_TYPE}" --disk-size "$disk"
    --num-nodes "${NODEPOOL_DESIRED}"
    --enable-autoscaling --min-nodes "${NODEPOOL_MIN}" --max-nodes "${NODEPOOL_MAX}"
    --node-labels "workload=${wl}"
  )
  [[ "$tainted" == true ]] && args+=(--node-taints "workload=${wl}:NoSchedule")

  log "Creating node pool '${name}'..."
  run gcloud "${args[@]}"
done

if [[ "$DELETE_DEFAULT" == true ]]; then
  if nodepool_exists default-pool; then
    confirm "Delete 'default-pool'? Pods running on it will be evicted."
    run gcloud container node-pools delete default-pool \
      --project "${PROJECT_ID}" --cluster "${CLUSTER_NAME}" --zone "${ZONE}" --quiet
  else
    log "No 'default-pool' present."
  fi
elif nodepool_exists default-pool; then
  warn "'default-pool' still exists. Re-run with --delete-default-pool to remove it once"
  warn "the system pool is Ready, or workloads may keep scheduling there."
fi

success "Node pools ready."
echo "Verify:  kubectl get nodes -L workload,cloud.google.com/gke-nodepool"
