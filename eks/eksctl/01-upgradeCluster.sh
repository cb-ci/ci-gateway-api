#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-upgradeCluster.sh — Upgrade the EKS cluster to the next Kubernetes
# minor version.
#
# EKS control-plane upgrades can only move ONE minor version at a time
# (e.g. 1.29 -> 1.30, never 1.29 -> 1.31), and none of the following happen
# automatically:
#   - EKS-managed add-ons (vpc-cni, coredns, kube-proxy, and anything declared
#     under `addons:` in eksctl-config.yaml.tpl) stay pinned to their old
#     version after the control plane moves.
#   - Managed node groups keep running their old AMI/kubelet version.
#
# So this script does all four steps, in the order AWS recommends:
#   1. Upgrade the control plane      (eksctl upgrade cluster)
#   2. Upgrade EKS-managed add-ons    (eksctl update addon, per add-on)
#   3. Upgrade managed node groups    (eksctl upgrade nodegroup, per group)
#   4. Refresh local kubeconfig
#
# It also updates the `version:` field in eksctl-config.yaml.tpl so future
# runs of 01-createCluster.sh / other scripts that render that template stay
# in sync with the cluster's real version.
#
# Usage:
#   ./01-upgradeCluster.sh                    # upgrade to current+1 minor version
#   ./01-upgradeCluster.sh --version 1.31     # upgrade to an explicit version
#   ./01-upgradeCluster.sh --skip-addons
#   ./01-upgradeCluster.sh --skip-nodegroups
#   ./01-upgradeCluster.sh --skip-template-update
#   ./01-upgradeCluster.sh --yes              # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CONFIG_TEMPLATE="eksctl-config.yaml.tpl"

# EKS-managed add-ons this environment cares about. vpc-cni/coredns/kube-proxy
# are installed by default on every eksctl-created cluster even though they
# aren't declared in eksctl-config.yaml.tpl; the rest come from that file's
# `addons:` block.
ADDONS=(vpc-cni coredns kube-proxy aws-ebs-csi-driver aws-efs-csi-driver eks-pod-identity-agent)

TARGET_VERSION=""
SKIP_ADDONS=false
SKIP_NODEGROUPS=false
SKIP_TEMPLATE_UPDATE=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)             TARGET_VERSION="${2:-}"; shift ;;
    --skip-addons)         SKIP_ADDONS=true ;;
    --skip-nodegroups)     SKIP_NODEGROUPS=true ;;
    --skip-template-update) SKIP_TEMPLATE_UPDATE=true ;;
    --yes|-y)              ASSUME_YES=true ;;
    -h|--help)             sed -n '2,32p' "$0"; exit 0 ;;
    *)                     error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

command -v eksctl >/dev/null || error "eksctl not found on PATH"
command -v aws    >/dev/null || error "aws CLI not found on PATH"

[[ -n "${CLUSTER_NAME:-}" ]] || error "CLUSTER_NAME is not set (check .env)"

log "Reading current control-plane version for cluster '${CLUSTER_NAME}' (${AWS_REGION})..."
CURRENT_VERSION=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.version' --output text) \
  || error "could not describe cluster '${CLUSTER_NAME}' — does it exist / are you logged in (00-login.sh)?"

log "Current control-plane version: ${CURRENT_VERSION}"

if [[ -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION=$(awk -F. -v v="$CURRENT_VERSION" 'BEGIN{split(v,p,"."); printf "%d.%d", p[1], p[2]+1}')
  log "No --version given, defaulting to next minor version: ${TARGET_VERSION}"
fi

[[ "$TARGET_VERSION" != "$CURRENT_VERSION" ]] || error "cluster is already on version ${CURRENT_VERSION}"

if ! $ASSUME_YES; then
  warn "About to upgrade cluster '${CLUSTER_NAME}' (${AWS_REGION}): ${CURRENT_VERSION} -> ${TARGET_VERSION}"
  warn "This upgrades the control plane, EKS-managed add-ons, and all managed node groups."
  warn "Node groups will roll worker nodes one at a time (drain + replace)."
  read -r -p "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || error "aborted by user"
fi

# -----------------------------------------------------------------------------
# 1. Control plane
# -----------------------------------------------------------------------------
log "[1/4] Upgrading control plane to ${TARGET_VERSION}..."
eksctl upgrade cluster \
  --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --version "$TARGET_VERSION" --approve
success "Control plane upgrade to ${TARGET_VERSION} complete."

# -----------------------------------------------------------------------------
# 2. EKS-managed add-ons
# -----------------------------------------------------------------------------
if $SKIP_ADDONS; then
  warn "[2/4] Skipping add-on updates (--skip-addons)."
else
  log "[2/4] Updating EKS-managed add-ons to versions compatible with ${TARGET_VERSION}..."
  INSTALLED_ADDONS=$(eksctl get addon --cluster "$CLUSTER_NAME" --region "$AWS_REGION" -o json \
    | grep -o '"Name":[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/') || INSTALLED_ADDONS=""

  for addon in "${ADDONS[@]}"; do
    if ! grep -qx "$addon" <<<"$INSTALLED_ADDONS"; then
      log "  - ${addon}: not installed on this cluster, skipping."
      continue
    fi

    # eksctl 0.229.0's `update addon` has no --resolve-conflicts flag (that
    # only exists on `eksctl create addon`, and on the raw AWS API). Without
    # it, any live field that has drifted from the add-on's own manifest —
    # e.g. a toleration patched onto coredns by hand before the `system`
    # node pool existed to make that unnecessary — blocks the upgrade with a
    # ConfigurationConflict instead of losing to the declared state. Call
    # the AWS API directly so we can pass --resolve-conflicts OVERWRITE, and
    # re-supply each add-on's current configurationValues explicitly (e.g.
    # aws-ebs-csi-driver / aws-efs-csi-driver's tolerations from
    # eksctl-config.yaml.tpl) so overwriting doesn't also wipe those out.
    ADDON_VERSION=$(aws eks describe-addon-versions --region "$AWS_REGION" \
      --addon-name "$addon" --kubernetes-version "$TARGET_VERSION" \
      --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion | [0]' \
      --output text)
    [[ -n "$ADDON_VERSION" && "$ADDON_VERSION" != "None" ]] \
      || error "no addon version found for '${addon}' compatible with Kubernetes ${TARGET_VERSION}"

    CONFIG_VALUES=$(aws eks describe-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
      --addon-name "$addon" --query 'addon.configurationValues' --output text)

    log "  - ${addon}: updating to ${ADDON_VERSION}..."
    UPDATE_ARGS=(eks update-addon --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME"
      --addon-name "$addon" --addon-version "$ADDON_VERSION" --resolve-conflicts OVERWRITE)
    [[ -n "$CONFIG_VALUES" && "$CONFIG_VALUES" != "None" ]] \
      && UPDATE_ARGS+=(--configuration-values "$CONFIG_VALUES")
    aws "${UPDATE_ARGS[@]}" >/dev/null

    aws eks wait addon-active --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --addon-name "$addon"
  done
  success "Add-on updates complete."
fi

# -----------------------------------------------------------------------------
# 3. Managed node groups
# -----------------------------------------------------------------------------
if $SKIP_NODEGROUPS; then
  warn "[3/4] Skipping node group upgrades (--skip-nodegroups)."
else
  log "[3/4] Upgrading managed node groups to ${TARGET_VERSION}..."
  NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'nodegroups[]' --output text)
  [[ -n "$NODEGROUPS" ]] || warn "no managed node groups found for cluster '${CLUSTER_NAME}'"

  for ng in $NODEGROUPS; do
    log "  - ${ng}: upgrading (this drains and replaces nodes one at a time)..."
    eksctl upgrade nodegroup \
      --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
      --name "$ng" --kubernetes-version "$TARGET_VERSION"
    success "  - ${ng}: upgraded."
  done
  success "Node group upgrades complete."
fi

# -----------------------------------------------------------------------------
# 4. Local kubeconfig + template sync
# -----------------------------------------------------------------------------
log "[4/4] Refreshing local kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

if $SKIP_TEMPLATE_UPDATE; then
  warn "Skipping ${CONFIG_TEMPLATE} version bump (--skip-template-update)."
elif [[ -f "$CONFIG_TEMPLATE" ]]; then
  sed -i.bak -E "s/^(  version:)[[:space:]]*\"[0-9]+\.[0-9]+\"/\1 \"${TARGET_VERSION}\"/" "$CONFIG_TEMPLATE"
  rm -f "${CONFIG_TEMPLATE}.bak"
  success "Updated ${CONFIG_TEMPLATE} to version \"${TARGET_VERSION}\"."
else
  warn "${CONFIG_TEMPLATE} not found, skipping template version bump."
fi

success "Cluster '${CLUSTER_NAME}' is now on Kubernetes ${TARGET_VERSION}."
kubectl get nodes
