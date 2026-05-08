#!/usr/bin/env bash

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../" && pwd)"

# Source common functions
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/_functions.sh"

# Load environment variables
load_env "${ROOT_DIR}/.env"


# --- Configuration ---
ENVOY_GATEWAY_VERSION=${ENVOY_GATEWAY_VERSION:-latest}
ENVOY_GW_NAMESPACE=envoy-gateway-system
GATEWAY_CLASS_NAME=eg
GATEWAY_NAME=test-gateway
GATEWAY_ROUTE_NAME=test-route
GATEWAY_POLICY_NAME=test-traffic-policy
CERT_DIR="${ROOT_DIR}/ssl"
NAMESPACE=test-ns
STORAGE_CLASS=premium-rwo
TEST_HOST_NAME=example.com




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
# GKE forbids installing Gateway API CRDs beyond the standard channel.
# We pull the chart locally and remove the bundled Gateway API CRDs to avoid admission webhook errors.
if ! helm status eg -n "${ENVOY_GW_NAMESPACE}" &>/dev/null; then
    log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION} via Helm..."
    if [ ! -d "${SCRIPT_DIR}/gateway-helm" ]; then
        rm -rf "${SCRIPT_DIR}/gateway-helm" 2>/dev/null || true
        helm pull oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY_VERSION}" --untar --destination "${SCRIPT_DIR}"
        rm -f "${SCRIPT_DIR}/gateway-helm/crds/gatewayapi-crds.yaml"
    fi
    log "Applying Envoy Gateway Helm chart..."
    helm upgrade --install eg "${SCRIPT_DIR}/gateway-helm" -n "${ENVOY_GW_NAMESPACE}" --create-namespace
    log "Waiting for Envoy Gateway controller to be ready..."
    kubectl rollout status deployment/envoy-gateway -n "${ENVOY_GW_NAMESPACE}" --timeout=120s
else
    log "Envoy Gateway is already installed in ${ENVOY_GW_NAMESPACE}. Skipping..."
fi

log "Creating namespace ${NAMESPACE}..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=${NAMESPACE}

# --- Create TLS Secret ---
log "Creating TLS secret ${CERT_NAME}..."
"${ROOT_DIR}/scripts/generate-ssl-cert.sh" "${TEST_HOST_NAME}"
kubectl delete secret "${CERT_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl create secret tls "${CERT_NAME}" \
  --cert="${CERT_DIR}/jenkins.pem" \
  --key="${CERT_DIR}/server.key" \
  -n "${NAMESPACE}"

# --- Configuration ---

# force re-creation of the resources
kubectl delete httproute --all --ignore-not-found -n ${NAMESPACE}
kubectl delete gateway --all --ignore-not-found -n ${NAMESPACE}
#kubectl delete gatewayclass --all


cat <<EOF | kubectl -n ${NAMESPACE} apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGE_CLASS}  # Replace with your dynamic provisioning StorageClass name
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  labels:
    app: test-app
spec:
  containers:
    - name: test-container
      image: nginx:latest
      ports:
        - containerPort: 80
      volumeMounts:
        - mountPath: /usr/share/nginx/html
          name: test-volume
  volumes:
    - name: test-volume
      persistentVolumeClaim:
        claimName: test-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: test-service
spec:
  selector:
    app: test-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
EOF

cat <<EOF | kubectl -n ${NAMESPACE} apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${GATEWAY_CLASS_NAME}
  namespace: ${ENVOY_GW_NAMESPACE}
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

log "Applying Gateway..."
cat <<EOF | kubectl -n ${NAMESPACE} apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: ${GATEWAY_CLASS_NAME}
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

cat <<EOF | kubectl -n ${NAMESPACE} apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${GATEWAY_ROUTE_NAME}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /test
    backendRefs:
    - name: test-service
      port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: ${GATEWAY_POLICY_NAME}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ${GATEWAY_ROUTE_NAME}
  healthCheck:
    active:
      type: HTTP
      http:
        path: /
        method: GET
        expectedStatuses:
        - 200
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 1
---
EOF

# --- Wait for Gateway IP ---
log "Waiting for Gateway External IP..."
ADDRESS=""
MAX_RETRIES=10
RETRY_COUNT=0

while [[ -z "$ADDRESS" && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    ADDRESS=$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    if [[ -z "$ADDRESS" ]]; then
        echo -n "."
        sleep 30
        ((RETRY_COUNT++))
    fi
done

if [[ -n "$ADDRESS" ]]; then
    echo ""
    success "Gateway IP assigned: ${ADDRESS}"
    log "Testing connection to https://${ADDRESS}/test"
    curl -Lvk "https://${ADDRESS}/test"
else
    echo ""
    error "Timed out waiting for Gateway IP."
    exit 1
fi
