#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 05-inatallCloudBees.sh — Install CloudBees CI on EKS via Helm.
# Teardown: 05-deleteCloudBees.sh
# -----------------------------------------------------------------------------
set -eo pipefail

set -euo pipefail

# Load environment variables
source ./.env

# Helper logging functions
log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }


# --- Helm Deployment ---
log "Updating Helm repositories..."
helm repo add cloudbees https://charts.cloudbees.com/public/cloudbees || true
helm repo update

log "Deploying CloudBees CI via Helm..."
helm upgrade --install cloudbees-core-envoy cloudbees/cloudbees-core \
  --namespace "${NAMESPACE_CLOUDBEES}" \
  --set Gateway.Enabled=true \
  --set Gateway.Name="${GATEWAY_NAME}" \
  --set Gateway.SectionName=https \
  --set Gateway.Namespace="${NAMESPACE_CLOUDBEES}" \
  --set OperationsCenter.HostName="${CJOC_HOST_NAME}" \
  --set OperationsCenter.Protocol=https \
  --set OperationsCenter.NodeSelector.workload=controller \
  --set-json 'OperationsCenter.Tolerations=[{"key":"workload","operator":"Equal","value":"controller","effect":"NoSchedule"}]' \
  --set Agents.SeparateNamespace.Enabled=true \
  --set Agents.SeparateNamespace.Create=true \
  --set Persistence.StorageClass="${CLOUDBEES_STORAGE_CLASS}" \
  --set Common.image.tag='latest'

 # --set Agents.ImagePullSecrets=<secret> \
 # --set OperationsCenter.ImagePullSecrets=<secret> 



# --- Wait for Gateway External IP ---
log "Waiting for Gateway External IP (this may take a few minutes)..."
GATEWAY_IP=""
MAX_RETRIES=30
RETRY_COUNT=0

while [[ -z "$GATEWAY_IP" && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    GATEWAY_IP=$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE_CLOUDBEES}" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    if [[ -z "$GATEWAY_IP" ]]; then
        echo -n "."
        sleep 10
        ((RETRY_COUNT++))
    fi
done

if [[ -n "$GATEWAY_IP" ]]; then
    echo ""
    success "Gateway is ready!"
    log "External IP: ${GATEWAY_IP}"
    log "Operations Center URL: https://${CJOC_HOST_NAME}/cjoc/"
    log "Post-install: Update your DNS A record for ${CJOC_HOST_NAME} to ${GATEWAY_IP}"
else
    echo ""
    error "Timed out waiting for Gateway External IP. Check 'kubectl get gateway -n ${NAMESPACE_CLOUDBEES}' and ensure a LoadBalancer IP is assigned."
fi

success "Installation completed successfully."