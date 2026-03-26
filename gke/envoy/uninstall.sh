#!/bin/bash
set -eo pipefail

# --- Configuration ---
NAMESPACE=${NAMESPACE:-cloudbees-envoy}
ENVOY_GW_NAMESPACE=envoy-gateway-system
GATEWAY_CLASS_NAME=eg

# --- Colors for Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%Y-%m-%dT%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { echo -e "${RED}[WARNING]${NC} $1"; }

log "Starting complete cleanup of Envoy Gateway and CloudBees CI resources..."

# 1. Force removal of finalizers from Gateway API resources
# This is necessary if the controller or CRDs are deleted before the resources.
log "Removing finalizers from Gateways and HTTPRoutes to prevent hanging..."
kubectl get gateway -n "${NAMESPACE}" -o name 2>/dev/null | xargs -L1 -I{} kubectl patch {} -n "${NAMESPACE}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl get httproute -n "${NAMESPACE}" -o name 2>/dev/null | xargs -L1 -I{} kubectl patch {} -n "${NAMESPACE}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl patch gatewayclass "${GATEWAY_CLASS_NAME}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true

# 2. Uninstall CloudBees CI
if helm status cloudbees-core-envoy -n "${NAMESPACE}" &>/dev/null; then
    log "Uninstalling CloudBees CI Helm release..."
    helm uninstall cloudbees-core-envoy -n "${NAMESPACE}"
else
    log "CloudBees CI Helm release not found or already deleted."
fi

# 3. Uninstall Envoy Gateway
if helm status eg -n "${ENVOY_GW_NAMESPACE}" &>/dev/null; then
    log "Uninstalling Envoy Gateway Helm release..."
    helm uninstall eg -n "${ENVOY_GW_NAMESPACE}"
else
    log "Envoy Gateway Helm release not found or already deleted."
fi

# 4. Delete GatewayClass (Cluster-scoped)
log "Deleting GatewayClass: ${GATEWAY_CLASS_NAME}..."
kubectl delete gatewayclass "${GATEWAY_CLASS_NAME}" --ignore-not-found --timeout=10s || \
kubectl patch gatewayclass "${GATEWAY_CLASS_NAME}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null

# 5. Delete Namespaces
log "Deleting namespaces (cloudbees-envoy and envoy-gateway-system)..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=20s || \
kubectl patch namespace "${NAMESPACE}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null

kubectl delete namespace "${ENVOY_GW_NAMESPACE}" --ignore-not-found --timeout=20s || \
kubectl patch namespace "${ENVOY_GW_NAMESPACE}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null

success "Cleanup completed successfully."

warn "To delete all Gateway API and Envoy Gateway CRDs, run:"
warn "kubectl get crd -o name | grep -E 'envoyproxy.io|gateway.networking.k8s.io' | xargs kubectl delete"
