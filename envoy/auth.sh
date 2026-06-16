#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# auth.sh — Authenticate to GKE and configure local tooling environment.
# Usage: source ./auth.sh
# -----------------------------------------------------------------------------
set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common functions
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/_functions.sh"

# Load environment variables
load_env "${ROOT_DIR}/.env"

# Validate required variables
validate_vars \
  PROJECT_ID \
  CLUSTER_NAME \
  ZONE \
  REGION \
  NAMESPACE \
  DOMAIN \
  ZONE_NAME

# Prerequisite checks
check_command gcloud
check_command kubectl

# Derive authenticated account details
ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
if [[ -z "${ACCOUNT}" ]]; then
  error "No active gcloud account found. Run: gcloud auth login"
fi

log "Configuring GKE environment for ${CLUSTER_NAME}..."

# Apply gcloud defaults
gcloud config set project "${PROJECT_ID}"
gcloud config set compute/zone "${ZONE}"
gcloud config set compute/region "${REGION}"

# Update SDK components only when not running in a non-interactive CI context
if [[ -t 1 ]]; then
  gcloud components update --quiet
fi

# Fetch cluster credentials
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone "${ZONE}" \
  --project "${PROJECT_ID}"

# Set default namespace
kubectl config set-context "$(kubectl config current-context)" \
  --namespace="${NAMESPACE}"

success "GKE environment configured"
echo "  CLUSTER_NAME  : ${CLUSTER_NAME}"
echo "  PROJECT_ID    : ${PROJECT_ID}"
echo "  ZONE          : ${ZONE}"
echo "  REGION        : ${REGION}"
echo "  ACCOUNT       : ${ACCOUNT}"
echo "  NAMESPACE     : ${NAMESPACE}"
echo "  DOMAIN        : ${DOMAIN}"
echo "  KUBECONFIG    : ${KUBECONFIG:-~/.kube/config}"
