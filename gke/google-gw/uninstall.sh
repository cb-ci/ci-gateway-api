#!/bin/bash
set -eo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory (safe for both direct execution and sourcing)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load environment variables
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
else
  echo "[ERROR] No .env file found at ${ENV_FILE}." >&2
  echo "        Please create one based on .env.template." >&2
  return 1 2>/dev/null || exit 1
fi

NAMESPACE=${NAMESPACE:-cloudbees-google-gw}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
echo "=========================================="
echo "CloudBees CI GKE Gateway Uninstall"
echo "=========================================="
echo ""
echo "This will remove the following resources:"
echo "  - Helm release: cloudbees-core-gwapi"
echo "  - Gateway: ${GATEWAY_NAME}"
echo "  - HealthCheckPolicies and GCPBackendPolicy"
echo "  - TLS Secret: ${CERT_NAME}"
echo "  - Namespace: ${NAMESPACE} (optional)"
echo ""
echo "Cluster: ${CLUSTER_NAME}"
echo "Zone: ${ZONE}"
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Remove Helm Deployment
# ---------------------------------------------------------------------------
log "Removing CloudBees CI Helm deployment..."
if helm list -n "${NAMESPACE}" | grep -q "cloudbees-core-gwapi"; then
    helm uninstall cloudbees-core-gwapi -n "${NAMESPACE}"
    success "Helm release removed."
else
    log "Helm release 'cloudbees-core-gwapi' not found, skipping."
fi

# ---------------------------------------------------------------------------
# Remove Gateway Resources
# ---------------------------------------------------------------------------
log "Removing Gateway resources..."

# Delete GCPBackendPolicy
if kubectl get gcpbackendpolicy cloudbees-sticky-policy -n "${NAMESPACE}" &>/dev/null; then
    kubectl delete gcpbackendpolicy cloudbees-sticky-policy -n "${NAMESPACE}"
    log "GCPBackendPolicy removed."
fi

# Delete HealthCheckPolicies
if kubectl get healthcheckpolicy cjoc-health-check-policy -n "${NAMESPACE}" &>/dev/null; then
    kubectl delete healthcheckpolicy cjoc-health-check-policy -n "${NAMESPACE}"
    log "CJOC HealthCheckPolicy removed."
fi

if kubectl get healthcheckpolicy "${CONTROLLER_NAME}-health-check-policy" -n "${NAMESPACE}" &>/dev/null; then
    kubectl delete healthcheckpolicy "${CONTROLLER_NAME}-health-check-policy" -n "${NAMESPACE}"
    log "Controller HealthCheckPolicy removed."
fi

# Delete Gateway
if kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    kubectl delete gateway "${GATEWAY_NAME}" -n "${NAMESPACE}"
    log "Gateway removed."
fi

# ---------------------------------------------------------------------------
# Remove TLS Secret
# ---------------------------------------------------------------------------
log "Removing TLS secret..."
kubectl delete secret "${CERT_NAME}" -n "${NAMESPACE}" --ignore-not-found
log "TLS secret removed."

# ---------------------------------------------------------------------------
# Optional: Remove Namespace
# ---------------------------------------------------------------------------
echo ""
read -p "Do you want to delete the namespace '${NAMESPACE}'? (yes/no): " -r
if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log "Deleting namespace ${NAMESPACE}..."
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found
    success "Namespace removed."
else
    log "Namespace '${NAMESPACE}' preserved."
fi

# ---------------------------------------------------------------------------
# Note about Gateway API
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Uninstall Complete"
echo "=========================================="
echo ""
echo "Note: Gateway API remains enabled on cluster ${CLUSTER_NAME}."
echo "To disable it manually, run:"
echo "  gcloud container clusters update ${CLUSTER_NAME} --gateway-api=disabled --zone ${ZONE}"
echo ""
echo "Remember to remove the DNS A record for ${CJOC_HOST_NAME:-gateway-google-gw.$DOMAIN}"
echo ""
