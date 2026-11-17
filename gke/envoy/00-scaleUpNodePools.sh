#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-scaleUpNodePools.sh — Restore every node pool to the size it had before
# 00-scaleDownNodePools.sh parked it. GKE counterpart of
# eks/eksctl/01-scaleUpNodePools.sh.
#
# WHERE THE SIZES COME FROM
#   .nodepool-scale-state.json, written by the scale-down script. Each pool is
#   restored to its own recorded node count and autoscaling setting.
#
#   If the state file is missing the script falls back to NODEPOOL_MIN /
#   NODEPOOL_DESIRED / NODEPOOL_MAX (defaults 1/1/2, autoscaling on) and warns,
#   because that is a guess about your cluster.
#
# AFTER NODES ARE READY
#   CJOC is a StatefulSet with a PD-backed PVC pinned to one zone, so it can
#   only schedule once a node exists in that zone. The cluster is zonal
#   (${ZONE}), so the pools already satisfy this. Watch: kubectl get pods -A -w
#
# Usage:
#   ./00-scaleUpNodePools.sh                       # restore from state file
#   ./00-scaleUpNodePools.sh --nodes 2             # override desired size
#   ./00-scaleUpNodePools.sh --nodes-min 1 --nodes-max 3
#   ./00-scaleUpNodePools.sh --no-wait             # don't block on readiness
#   ./00-scaleUpNodePools.sh --yes                 # skip the confirmation prompt
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

OVERRIDE_MIN=""
OVERRIDE_DESIRED=""
OVERRIDE_MAX=""
WAIT=true
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes)      OVERRIDE_DESIRED="${2:-}"; shift ;;
    --nodes-min)  OVERRIDE_MIN="${2:-}";     shift ;;
    --nodes-max)  OVERRIDE_MAX="${2:-}";     shift ;;
    --no-wait)    WAIT=false ;;
    --yes|-y)     ASSUME_YES=true ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    *)            error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

check_command gcloud
check_command jq

# =============================================================================
# 1. LOAD TARGET SIZES
# =============================================================================
log "Listing node pools in cluster '${CLUSTER_NAME}' (${ZONE})..."
POOLS=$(gcloud container node-pools list --project "${PROJECT_ID}" --cluster "${CLUSTER_NAME}" \
  --zone "${ZONE}" --format='value(name)')
[[ -n "$POOLS" ]] || error "no node pools found for cluster '${CLUSTER_NAME}'"

STATE='{}'
if [[ -f "$STATE_FILE" ]]; then
  # Reject a corrupt file rather than silently resizing the cluster to defaults.
  jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1 \
    || error "${STATE_FILE} is not valid JSON — delete it to use the fallback sizes"
  STATE=$(cat "$STATE_FILE")
  success "Loaded saved sizes from ${STATE_FILE}"
else
  warn "${STATE_FILE} not found — falling back to ${NODEPOOL_MIN}/${NODEPOOL_DESIRED}/${NODEPOOL_MAX} (min/desired/max), autoscaling on."
  warn "Override with --nodes-min / --nodes / --nodes-max if that is wrong for this cluster."
fi

declare -a PLAN=()
echo
printf '%-20s %26s\n' "NODEPOOL" "TARGET (min/des/max) AUTOSCALE"
for pool in $POOLS; do
  MIN=$(jq -r --arg n "$pool" --argjson d "$NODEPOOL_MIN"     '.[$n].minNodes     // $d' <<< "$STATE")
  DES=$(jq -r --arg n "$pool" --argjson d "$NODEPOOL_DESIRED" '.[$n].desiredNodes // $d' <<< "$STATE")
  MAX=$(jq -r --arg n "$pool" --argjson d "$NODEPOOL_MAX"     '.[$n].maxNodes     // $d' <<< "$STATE")
  AS=$(jq -r --arg n "$pool" '.[$n].autoscaling // true' <<< "$STATE")

  [[ -n "$OVERRIDE_MIN"     ]] && MIN="$OVERRIDE_MIN"
  [[ -n "$OVERRIDE_DESIRED" ]] && DES="$OVERRIDE_DESIRED"
  [[ -n "$OVERRIDE_MAX"     ]] && MAX="$OVERRIDE_MAX"

  if [[ "$AS" == true ]]; then
    (( MIN <= DES )) || error "${pool}: min (${MIN}) cannot exceed desired (${DES})"
    (( DES <= MAX )) || error "${pool}: desired (${DES}) cannot exceed max (${MAX})"
    (( MAX >= 1 ))   || error "${pool}: max must be at least 1"
  fi

  printf '%-20s %26s\n' "$pool" "${MIN}/${DES}/${MAX} ${AS}"
  PLAN+=("${pool} ${MIN} ${DES} ${MAX} ${AS}")
done
echo

# =============================================================================
# 2. CONFIRM
# =============================================================================
confirm "Apply these sizes?"

# =============================================================================
# 3. SCALE UP, THEN RE-ENABLE AUTOSCALING
# =============================================================================
for entry in "${PLAN[@]}"; do
  read -r pool MIN DES MAX AS <<< "$entry"
  log "Resizing '${pool}' to ${DES}..."
  gcloud container clusters resize "${CLUSTER_NAME}" --project "${PROJECT_ID}" \
    --zone "${ZONE}" --node-pool "$pool" --num-nodes "$DES" --quiet
  if [[ "$AS" == true ]]; then
    log "Re-enabling autoscaling on '${pool}' (${MIN}-${MAX})..."
    gcloud container node-pools update "$pool" --project "${PROJECT_ID}" \
      --cluster "${CLUSTER_NAME}" --zone "${ZONE}" \
      --enable-autoscaling --min-nodes "$MIN" --max-nodes "$MAX" --quiet
  fi
done
success "Scale-up requested for all node pools."

# =============================================================================
# 4. WAIT
# =============================================================================
if [[ "$WAIT" == true ]] && command -v kubectl >/dev/null 2>&1; then
  TOTAL=$(printf '%s\n' "${PLAN[@]}" | awk '{s+=$3} END {print s+0}')
  log "Waiting for ${TOTAL} node(s) to register and become Ready..."
  for _ in $(seq 1 60); do
    READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready || true)
    [[ "${READY:-0}" -ge "$TOTAL" ]] && break
    printf '.'
    sleep 10
  done
  echo
  kubectl get nodes -L workload,cloud.google.com/gke-nodepool 2>/dev/null || warn "could not list nodes — check your kubeconfig"
fi

echo
success "Node pools scaled up."
echo "Pods recover on their own, but not instantly. Watch with: kubectl get pods -A -w"
