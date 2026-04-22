#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# auth.sh — Authenticate to AKS and configure local tooling environment.
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
  MY_SUBSCRIPTION_ID \
  MY_RESOURCE_GROUP_NAME \
  MY_AKS_CLUSTER_NAME

# Prerequisite checks
check_command az
check_command kubectl

log "Authenticating to Azure..."
az login --output none

log "Setting subscription ${MY_SUBSCRIPTION_ID}..."
az account set --subscription "${MY_SUBSCRIPTION_ID}"

log "Fetching AKS credentials for ${MY_AKS_CLUSTER_NAME}..."
az aks get-credentials \
  --resource-group "${MY_RESOURCE_GROUP_NAME}" \
  --name "${MY_AKS_CLUSTER_NAME}" \
  --overwrite-existing

success "AKS environment configured"
echo "  CLUSTER_NAME  : ${MY_AKS_CLUSTER_NAME}"
echo "  RESOURCE_GROUP: ${MY_RESOURCE_GROUP_NAME}"
echo "  SUBSCRIPTION  : ${MY_SUBSCRIPTION_ID}"
