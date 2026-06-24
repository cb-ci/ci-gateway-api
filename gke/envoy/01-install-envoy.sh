#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install.sh — Install Envoy Gateway and CloudBees CI on GKE.
# -----------------------------------------------------------------------------
set -eo pipefail

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common functions
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/_functions.sh"

# Load environment variables
load_env "${ROOT_DIR}/.env"

# --- Configuration ---
ENVOY_GATEWAY_VERSION=${ENVOY_GATEWAY_VERSION:-latest}
ENVOY_GW_NAMESPACE=envoy-gateway-system

CERT_DIR="${ROOT_DIR}/ssl"
#CERT_DIR="${ROOT_DIR}"
# --- Prerequisite Checks ---
log "Checking prerequisites..."
check_command helm
check_command kubectl
check_command gcloud

[[ -f "${CERT_DIR}/jenkins.pem" ]] || warn "jenkins.pem not found in ${CERT_DIR}. Running cert generation..."
[[ -f "${CERT_DIR}/server.key" ]]  || warn "server.key not found in ${CERT_DIR}. Running cert generation..."

# --- GKE Configuration ---
log "Verifying cluster ${CLUSTER_NAME} is reachable..."
if ! gcloud container clusters describe "${CLUSTER_NAME}" --zone "${ZONE}" --format="value(status)" &>/dev/null; then
    error "Cluster ${CLUSTER_NAME} not found in zone ${ZONE}."
fi

# --- Install Envoy Gateway ---
log "Uninstalling Envoy Gateway ${ENVOY_GATEWAY_VERSION} via Helm..."
# Remove finalizers from gateway classes or gateways to prevent deletion from hanging
kubectl patch gatewayclass eg -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null || true
kubectl patch gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null || true

helm uninstall eg -n "${ENVOY_GW_NAMESPACE}" || true
kubectl delete ns "${ENVOY_GW_NAMESPACE}" --ignore-not-found
kubectl create ns "${ENVOY_GW_NAMESPACE}" 

# log "Uninstalling existing Envoy Gateway CRDs..."
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true \
  | kubectl delete --ignore-not-found=true -f - || true

log "Applying Envoy Gateway CRDs..."
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
--version "${ENVOY_GATEWAY_VERSION}" \
--set crds.gatewayAPI.enabled=true \
--set crds.gatewayAPI.channel=standard \
--set crds.envoyGateway.enabled=true \
| kubectl apply --server-side --force-conflicts -f -

log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION} via Helm..."


helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
--version "${ENVOY_GATEWAY_VERSION}" \
--namespace "${ENVOY_GW_NAMESPACE}" \
--create-namespace \
--skip-crds

log "Waiting for Envoy Gateway controller to be ready..."
kubectl rollout status deployment/envoy-gateway -n "${ENVOY_GW_NAMESPACE}" --timeout=120s

# --- Create Kubernetes Namespace for CJOC---
log "Configuring namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace ${NAMESPACE} cloudbees.com/gateway-routes=enabled

# --- TLS Secret ---
log "Updating TLS secret ${CERT_NAME}..."
"${ROOT_DIR}/scripts/generate-ssl-cert.sh" "${CJOC_HOST_NAME}"

kubectl delete secret "${CERT_NAME}" -n "${NAMESPACE}" --ignore-not-found
#kubectl create secret tls "${CERT_NAME}" --key $CERT_DIR/privkey.pem --cert $CERT_DIR/fullchain.pem --namespace=$NAMESPACE
kubectl create secret tls "${CERT_NAME}" \
  --cert="${CERT_DIR}/jenkins.pem" \
  --key="${CERT_DIR}/server.key" \
  -n "${NAMESPACE}"

# --- Envoy Gateway Resources ---
log "Applying GatewayClass..."
#kubectl delete gatewayclass eg --ignore-not-found
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
 

log "Applying Gateway..."
kubectl delete gateway ${GATEWAY_NAME} -n ${NAMESPACE} --ignore-not-found
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: eg
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: ${CERT_NAME}
        namespace: ${NAMESPACE}
    allowedRoutes:
      namespaces:
        from: All
EOF

# Fix reverse proxy broken 
# See more info at : https://gateway.envoyproxy.io/latest/api/extension_types/#pathsettings
# and https://gateway.envoyproxy.io/latest/api/extension_types/#pathescapedslashaction
#Jenkins’ reverse proxy monitor requests an encoded callback URL:
#  /cjoc/administrativeMonitor/hudson.diagnosis.ReverseProxySetupMonitor/testForReverseProxySetup/...
# This URL contains encoded slashes like %2F. When Envoy sees these encoded slashes, it attempts to "UnescapeAndRedirect", but fails with path_normalization_failed (in Envoy access logs). The solution is to change this default behaviour from  "UnescapeAndRedirect" to "KeepUnchanged". This is done with creating a new policy and attaching to the gateway:
cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: keep-escaped-slashes
  namespace: ${NAMESPACE}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY_NAME}
  path:
    escapedSlashesAction: KeepUnchanged
EOF

# --- Helm Deployment ---
log "Updating Helm repositories..."
helm repo add cloudbees https://charts.cloudbees.com/public/cloudbees || true
helm repo update

log "Deploying CloudBees CI via Helm..."
helm upgrade --install cloudbees-core-envoy cloudbees/cloudbees-core \
  --namespace "${NAMESPACE}" \
  --set Gateway.Enabled=true \
  --set Gateway.Name="${GATEWAY_NAME}" \
  --set Gateway.SectionName=https \
  --set Gateway.Namespace="${NAMESPACE}" \
  --set OperationsCenter.HostName="${CJOC_HOST_NAME}" \
  --set OperationsCenter.Protocol=https \
  --set Agents.SeparateNamespace.Enabled=false \
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
    GATEWAY_IP=$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" \
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
    error "Timed out waiting for Gateway External IP. Check 'kubectl get gateway -n ${NAMESPACE}' and ensure a LoadBalancer IP is assigned."
fi

success "Installation completed successfully."
