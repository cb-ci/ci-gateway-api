#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install.sh — Install Envoy Gateway and CloudBees CI on GKE.
# -----------------------------------------------------------------------------
set -eo pipefail

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source common functions
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/_functions.sh"

# Load environment variables
load_env "${ROOT_DIR}/.env"

# --- Configuration ---
ENVOY_GATEWAY_VERSION=${ENVOY_GATEWAY_VERSION:-latest}
ENVOY_GW_NAMESPACE=envoy-gateway-system
CERT_DIR="${ROOT_DIR}/ssl"

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
log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION} via Helm..."
# GKE forbids installing Gateway API CRDs beyond the standard channel.
# We pull the chart locally and remove the bundled Gateway API CRDs to avoid admission webhook errors.
if [ ! -d "${SCRIPT_DIR}/gateway-helm" ]; then
    rm -rf "${SCRIPT_DIR}/gateway-helm" 2>/dev/null || true
    helm pull oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY_VERSION}" --untar --destination "${SCRIPT_DIR}"
    rm -f "${SCRIPT_DIR}/gateway-helm/crds/gatewayapi-crds.yaml"
fi

log "Applying Envoy Gateway Helm chart..."
#helm upgrade --install eg "${SCRIPT_DIR}/gateway-helm" -n "${ENVOY_GW_NAMESPACE}" --create-namespace

log "Waiting for Envoy Gateway controller to be ready..."
#kubectl rollout status deployment/envoy-gateway -n "${ENVOY_GW_NAMESPACE}" --timeout=120s

# --- Kubernetes Namespace ---
log "Configuring namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- TLS Secret ---
log "Updating TLS secret ${CERT_NAME}..."
"${ROOT_DIR}/scripts/generate-ssl-cert.sh" "${CJOC_HOST_NAME}"

kubectl delete secret "${CERT_NAME}" -n "${NAMESPACE}" --ignore-not-found
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

log "Applying HTTPRoutes (cjoc and ha)..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cjoc-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${NAMESPACE}
    sectionName: https
  hostnames:
  - "${CJOC_HOST_NAME}"
  rules:
  - filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
          - name: "X-Forwarded-Port"
            value: "443"
          - name: "X-Forwarded-Proto"
            value: "https"
  - matches:
    - path:
        type: PathPrefix
        value: /cjoc
    backendRefs:
    - name: cjoc
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ha-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${NAMESPACE}
    sectionName: https
  hostnames:
  - "${CJOC_HOST_NAME}"
  rules:
  - filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
          - name: "X-Forwarded-Port"
            value: "443"
          - name: "X-Forwarded-Proto"
            value: "https"
  - matches:
    - path:
        type: PathPrefix
        value: /${CONTROLLER_NAME}
    backendRefs:
    - name: ${CONTROLLER_NAME}
      port: 80
EOF

log "Applying BackendTrafficPolicy — active health checks for cjoc..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: cjoc-health-check-policy
  namespace: ${NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: cjoc-route
  healthCheck:
    active:
      type: HTTP
      http:
        path: /cjoc/health/
        method: GET
        expectedStatuses:
        - 200
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 1
EOF

log "Applying BackendTrafficPolicy — active health checks + sticky sessions for ${CONTROLLER_NAME}..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: ${CONTROLLER_NAME}-traffic-policy
  namespace: ${NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ha-route
  healthCheck:
    active:
      type: HTTP
      http:
        path: /${CONTROLLER_NAME}/health/
        method: GET
        expectedStatuses:
        - 200
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 1
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: Cookie
      cookie:
        name: CBCI_SESSION
        ttl: 3600s
        attributes:
          SameSite: Strict
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
  --set OperationsCenter.Gateway.Name="${GATEWAY_NAME}" \
  --set OperationsCenter.Gateway.SectionName=https \
  --set OperationsCenter.Gateway.Namespace="${NAMESPACE}" \
  --set OperationsCenter.HostName="${CJOC_HOST_NAME}" \
  --set OperationsCenter.Protocol=https \
  --set Agents.SeparateNamespace.Enabled=false \
  --set Persistence.StorageClass="${CLOUDBEES_STORAGE_CLASS}" \
  --set Common.image.tag='latest'

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
