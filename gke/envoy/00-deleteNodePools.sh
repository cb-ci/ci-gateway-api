#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-deleteNodePools.sh — Delete the controllers / agents / system node pools
# created by 00-createNodePools.sh. Only those three pools are touched; the
# cluster and any other pool are left alone.
#
# Every pod on these pools is evicted, including CJOC. PVCs (and their PDs)
# survive; run uninstall.sh first if you want the workloads removed cleanly.
#
# Usage:
#   ./00-deleteNodePools.sh             # asks first
#   ./00-deleteNodePools.sh --dry-run   # print the gcloud commands only
#   ./00-deleteNodePools.sh --yes       # skip the confirmation prompt
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *)         error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

check_command gcloud

TO_DELETE=()
for def in "${NODEPOOLS[@]}"; do
  name="${def%%|*}"
  if nodepool_exists "$name"; then TO_DELETE+=("$name"); else warn "Node pool '${name}' not found — skipping."; fi
done

[[ ${#TO_DELETE[@]} -gt 0 ]] || { log "Nothing to delete."; exit 0; }

warn "This deletes node pool(s): ${TO_DELETE[*]} on cluster ${CLUSTER_NAME} (${ZONE})."
warn "All pods on them are evicted, including CJOC."
confirm "Proceed?"

for name in "${TO_DELETE[@]}"; do
  log "Deleting node pool '${name}'..."
  run gcloud container node-pools delete "$name" \
    --project "${PROJECT_ID}" --cluster "${CLUSTER_NAME}" --zone "${ZONE}" --quiet
done

[[ "$DRY_RUN" == true ]] || rm -f "${STATE_FILE}"
success "Node pools deleted."
