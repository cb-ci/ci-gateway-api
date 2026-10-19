#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-scaleUpNodePools.sh — Restore every managed node group to the size it had
# before 01-scaleDonwNodePools.sh parked it.
#
# WHERE THE SIZES COME FROM
#   .nodepool-scale-state.json, written by the scale-down script. Each node
#   group is restored to its own recorded minSize/desiredSize/maxSize, so pools
#   with different sizes come back correctly.
#
#   If the state file is missing (deleted, or the cluster was scaled down some
#   other way) the script falls back to --nodes-min/--nodes/--nodes-max, which
#   default to the values in eksctl-config.yaml: 1/1/2. It warns loudly when it
#   does this, because those defaults are a guess about your cluster.
#
# AFTER NODES ARE READY
#   Pods do not all recover instantly. CJOC is a StatefulSet with an
#   EBS-backed PVC pinned to a single AZ, so it can only schedule once a node
#   exists in that same AZ — which is why both pools pin us-east-1a. Watch with
#   `kubectl get pods -A -w`.
#
# Usage:
#   ./01-scaleUpNodePools.sh                       # restore from state file
#   ./01-scaleUpNodePools.sh --nodes 2             # override desired size
#   ./01-scaleUpNodePools.sh --nodes-min 1 --nodes-max 3
#   ./01-scaleUpNodePools.sh --no-wait             # don't block on readiness
#   ./01-scaleUpNodePools.sh --yes                 # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STATE_FILE="${NODEPOOL_STATE_FILE:-.nodepool-scale-state.json}"

# Fallbacks only, used when the state file is absent. Match eksctl-config.yaml.
FALLBACK_MIN=1
FALLBACK_DESIRED=1
FALLBACK_MAX=2

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
    -h|--help)    sed -n '2,28p' "$0"; exit 0 ;;
    *)            error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

# =============================================================================
# 1. LOAD TARGET SIZES
# =============================================================================
log "Listing managed node groups in cluster '${CLUSTER_NAME}' (${AWS_REGION})..."
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'nodegroups[]' --output text 2>/dev/null || true)

[[ -n "$NODEGROUPS" ]] || error "no managed node groups found for cluster '${CLUSTER_NAME}'"

STATE='{}'
if [[ -f "$STATE_FILE" ]]; then
  # Reject a corrupt file rather than silently falling back — a truncated state
  # file would otherwise quietly resize the cluster to the defaults.
  jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1 \
    || error "${STATE_FILE} is not valid JSON — delete it to use the fallback sizes"
  STATE=$(cat "$STATE_FILE")
  success "Loaded saved sizes from ${STATE_FILE}"
else
  warn "${STATE_FILE} not found — falling back to ${FALLBACK_MIN}/${FALLBACK_DESIRED}/${FALLBACK_MAX} (min/desired/max)."
  warn "Override with --nodes-min / --nodes / --nodes-max if that is wrong for this cluster."
fi

# Resolve the target for each node group: state file, then per-flag overrides.
declare -a PLAN=()
echo
printf '%-20s %24s %24s\n' "NODEGROUP" "CURRENT (min/des/max)" "TARGET (min/des/max)"
for ng in $NODEGROUPS; do
  CUR=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
    --region "$AWS_REGION" --query 'nodegroup.scalingConfig' --output json)
  CUR_MIN=$(jq -r '.minSize' <<< "$CUR")
  CUR_DES=$(jq -r '.desiredSize' <<< "$CUR")
  CUR_MAX=$(jq -r '.maxSize' <<< "$CUR")

  MIN=$(jq -r --arg n "$ng" --arg d "$FALLBACK_MIN"     '.[$n].minSize     // $d' <<< "$STATE")
  DES=$(jq -r --arg n "$ng" --arg d "$FALLBACK_DESIRED" '.[$n].desiredSize // $d' <<< "$STATE")
  MAX=$(jq -r --arg n "$ng" --arg d "$FALLBACK_MAX"     '.[$n].maxSize     // $d' <<< "$STATE")

  [[ -n "$OVERRIDE_MIN"     ]] && MIN="$OVERRIDE_MIN"
  [[ -n "$OVERRIDE_DESIRED" ]] && DES="$OVERRIDE_DESIRED"
  [[ -n "$OVERRIDE_MAX"     ]] && MAX="$OVERRIDE_MAX"

  # AWS rejects the update otherwise, with a less obvious message.
  (( MIN <= DES )) || error "${ng}: minSize (${MIN}) cannot exceed desiredSize (${DES})"
  (( DES <= MAX )) || error "${ng}: desiredSize (${DES}) cannot exceed maxSize (${MAX})"
  (( MAX >= 1 ))   || error "${ng}: maxSize must be at least 1"

  printf '%-20s %24s %24s\n' "$ng" "${CUR_MIN}/${CUR_DES}/${CUR_MAX}" "${MIN}/${DES}/${MAX}"
  PLAN+=("${ng} ${MIN} ${DES} ${MAX}")
done
echo

# =============================================================================
# 2. CONFIRM
# =============================================================================
if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Apply these sizes? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# =============================================================================
# 3. SCALE UP
# =============================================================================
for entry in "${PLAN[@]}"; do
  read -r ng MIN DES MAX <<< "$entry"
  log "Scaling '${ng}' to min=${MIN} desired=${DES} max=${MAX}..."
  aws eks update-nodegroup-config \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$ng" \
    --region "$AWS_REGION" \
    --scaling-config "minSize=${MIN},maxSize=${MAX},desiredSize=${DES}" \
    >/dev/null
done
success "Scale-up requested for all node groups."

# =============================================================================
# 4. WAIT
# =============================================================================
if [[ "$WAIT" == true ]]; then
  log "Waiting for node groups to become ACTIVE..."
  for entry in "${PLAN[@]}"; do
    read -r ng _ _ _ <<< "$entry"
    printf '  %s ' "$ng"
    for _ in $(seq 1 90); do
      STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$ng" --region "$AWS_REGION" \
        --query 'nodegroup.status' --output text 2>/dev/null || echo UNKNOWN)
      [[ "$STATUS" == "ACTIVE" ]] && break
      printf '.'
      sleep 10
    done
    echo " ${STATUS}"
  done

  if command -v kubectl >/dev/null 2>&1; then
    TOTAL=$(printf '%s\n' "${PLAN[@]}" | awk '{s+=$3} END {print s+0}')
    log "Waiting for ${TOTAL} node(s) to register and become Ready..."
    for _ in $(seq 1 60); do
      READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready || true)
      [[ "${READY:-0}" -ge "$TOTAL" ]] && break
      printf '.'
      sleep 10
    done
    echo
    kubectl get nodes 2>/dev/null || warn "could not list nodes — check your kubeconfig"
  fi
fi

echo
success "Node pools scaled up."
echo
echo "Pods recover on their own, but not instantly. Watch with:"
echo "  kubectl get pods -A -w"
echo
echo "If CJOC stays Pending, it is almost always the AZ constraint: its"
echo "EBS-backed PVC is pinned to one AZ and needs a node in that same AZ."
echo "  kubectl describe pod -n ${NAMESPACE_CLOUDBEES:-cloudbees-core} -l app.kubernetes.io/name=cloudbees-core | tail -20"
