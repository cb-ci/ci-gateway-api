#!/bin/bash
set -eo pipefail

# --- Configuration ---
NAMESPACE=${NAMESPACE:-cloudbees-appgw}
INGRESS_NAME=${INGRESS_NAME:-cloudbees-ingress}
CJOC_HOST_NAME=${CJOC_HOST_NAME:-gateway-appgw.acaternberg.flow-training.beescloud.com}
CLOUDBEES_STORAGE_CLASS=${CLOUDBEES_STORAGE_CLASS:-managed-csi}
SERVICE_NAME=${SERVICE_NAME:-ha}
CONTROLLER_NAME=${CONTROLLER_NAME:-ha}

RESOURCE_GROUP=${RESOURCE_GROUP:-cloudbees-rg}
CLUSTER_NAME=${CLUSTER_NAME:-cb-ci}
CERT_NAME=acaternberg-cert-selfsigned

# --- Colors for Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%Y-%m-%dT%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { echo -e "${RED}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Prerequisite Checks ---
log "Checking prerequisites..."
[[ -f "./jenkins.pem" ]] || error "jenkins.pem not found in current directory."
[[ -f "./server.key" ]]  || error "server.key not found in current directory."
command -v helm    &>/dev/null || error "helm CLI not found."
command -v kubectl &>/dev/null || error "kubectl CLI not found."
command -v az      &>/dev/null || error "az CLI not found."

# --- AKS Configuration ---
log "Verifying cluster ${CLUSTER_NAME} is reachable..."
if ! az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" &>/dev/null; then
    error "Cluster ${CLUSTER_NAME} not found in resource group ${RESOURCE_GROUP}."
fi

log "Getting AKS credentials..."
az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --overwrite-existing

# --- Verify AGIC is installed ---
log "Checking if AGIC is installed..."
if ! kubectl get deployment -n kube-system | grep -q "ingress-appgw"; then
    warn "AGIC not detected. Ensure AGIC addon is enabled or AGIC is installed via Helm."
    warn "To enable AGIC addon: az aks enable-addons -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} -a ingress-appgw --appgw-name <appgw-name> --appgw-subnet-cidr <cidr>"
fi

# --- Kubernetes Namespace ---
log "Configuring namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- TLS Secret ---
log "Updating TLS secret ${CERT_NAME}..."
kubectl delete secret "${CERT_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl create secret tls "${CERT_NAME}" \
  --cert="./jenkins.pem" \
  --key="./server.key" \
  -n "${NAMESPACE}"

# --- Ingress Resources ---
log "Applying Ingress resources with Azure AGIC annotations..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
    appgw.ingress.kubernetes.io/connection-draining-timeout: "60"
    appgw.ingress.kubernetes.io/request-timeout: "300"
    # Health probe for cjoc backend
    appgw.ingress.kubernetes.io/backend-path-prefix: ""
    appgw.ingress.kubernetes.io/health-probe-path: "/cjoc/health/"
    appgw.ingress.kubernetes.io/health-probe-status-codes: "200-399"
    appgw.ingress.kubernetes.io/health-probe-interval: "10"
    appgw.ingress.kubernetes.io/health-probe-timeout: "5"
    appgw.ingress.kubernetes.io/health-probe-unhealthy-threshold: "3"
spec:
  tls:
  - hosts:
    - ${CJOC_HOST_NAME}
    secretName: ${CERT_NAME}
  rules:
  - host: ${CJOC_HOST_NAME}
    http:
      paths:
      - path: /cjoc
        pathType: Prefix
        backend:
          service:
            name: cjoc
            port:
              number: 80
      - path: /${CONTROLLER_NAME}
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: 80
---
# Separate health check configuration for HA controller
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${CONTROLLER_NAME}-ingress
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/cookie-based-affinity: "Enabled"
    appgw.ingress.kubernetes.io/connection-draining-timeout: "60"
    appgw.ingress.kubernetes.io/health-probe-path: "/${CONTROLLER_NAME}/health/"
    appgw.ingress.kubernetes.io/health-probe-status-codes: "200-399"
    appgw.ingress.kubernetes.io/health-probe-interval: "10"
    appgw.ingress.kubernetes.io/health-probe-timeout: "5"
    appgw.ingress.kubernetes.io/health-probe-unhealthy-threshold: "3"
spec:
  tls:
  - hosts:
    - ${CJOC_HOST_NAME}
    secretName: ${CERT_NAME}
  rules:
  - host: ${CJOC_HOST_NAME}
    http:
      paths:
      - path: /${CONTROLLER_NAME}
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: 80
EOF

# --- Helm Deployment ---
log "Updating Helm repositories..."
helm repo add cloudbees https://charts.cloudbees.com/public/cloudbees || true
helm repo update

log "Deploying CloudBees CI via Helm..."
helm upgrade --install cloudbees-core-appgw cloudbees/cloudbees-core \
  --namespace "${NAMESPACE}" \
  --set Ingress.Enabled=true \
  --set OperationsCenter.Ingress.Class=azure/application-gateway \
  --set OperationsCenter.HostName="${CJOC_HOST_NAME}" \
  --set OperationsCenter.Protocol=https \
  --set Agents.SeparateNamespace.Enabled=false \
  --set Persistence.StorageClass="${CLOUDBEES_STORAGE_CLASS}" \
  --set Common.image.tag='latest'

# --- Wait for Ingress External IP ---
log "Waiting for Ingress External IP (this may take several minutes)..."
INGRESS_IP=""
MAX_RETRIES=40
RETRY_COUNT=0

while [[ -z "$INGRESS_IP" && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    INGRESS_IP=$(kubectl get ingress "${INGRESS_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -z "$INGRESS_IP" ]]; then
        echo -n "."
        sleep 10
        ((RETRY_COUNT++))
    fi
done

if [[ -n "$INGRESS_IP" ]]; then
    echo ""
    success "Ingress is ready!"
    log "External IP: ${INGRESS_IP}"
    log "Operations Center URL: https://${CJOC_HOST_NAME}/cjoc/"
    log "Post-install: Update your DNS A record for ${CJOC_HOST_NAME} to ${INGRESS_IP}"
else
    echo ""
    warn "Timed out waiting for Ingress External IP. Check 'kubectl get ingress -n ${NAMESPACE}' and Azure Application Gateway status."
fi

success "Installation completed successfully."
