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
CJOC_HOST_NAME=${CJOC_HOST_NAME:-gateway-google-gw.$DOMAIN}
 
# --- GKE Configuration ---
log "Ensuring Gateway API is enabled on cluster ${CLUSTER_NAME}..."
if ! gcloud container clusters describe "${CLUSTER_NAME}" --zone "${ZONE}" --format="value(status)" &>/dev/null; then
    error "Cluster ${CLUSTER_NAME} not found in zone ${ZONE}."
fi

# Check if Gateway API is already standard
GW_API_STATUS=$(gcloud container clusters describe "${CLUSTER_NAME}" --zone "${ZONE}" --format="value(gatewayConfig.enabled)" 2>/dev/null || echo "false")
if [[ "$GW_API_STATUS" != "true" ]]; then
    log "Enabling Gateway API (standard)..."
    gcloud container clusters update "${CLUSTER_NAME}" --gateway-api=standard --zone "${ZONE}"
else
    log "Gateway API already enabled."
fi

# --- Network Configuration ---
log "Checking for proxy-only subnet in ${REGION}..."
if ! gcloud compute networks subnets describe proxy-only-subnet --region="${REGION}" &>/dev/null; then
    log "Creating proxy-only subnet..."
    gcloud compute networks subnets create proxy-only-subnet \
      --purpose=REGIONAL_MANAGED_PROXY \
      --role=ACTIVE \
      --region="${REGION}" \
      --network=default \
      --range=10.10.0.0/23
else
    warn "Proxy-only subnet already exists."
fi

# --- Kubernetes Resources ---
log "Configuring Kubernetes resources in namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- TLS Secret ---
log "Updating TLS secret ${CERT_NAME}..."
kubectl delete secret "${CERT_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl create secret tls "${CERT_NAME}" \
  --cert="${CERT_DIR}/jenkins.pem" \
  --key="${CERT_DIR}/server.key" \
  -n "${NAMESPACE}"

log "Applying GKE Gateway resources..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE}
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
spec: 
  gatewayClassName: gke-l7-regional-external-managed
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: ${CERT_NAME}
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: cjoc-health-check-policy
  namespace: ${NAMESPACE}
spec:
  default:
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: HTTP
      httpHealthCheck:
        requestPath: /cjoc/health/
    logConfig:
      enabled: true
  targetRef:
    group: ""
    kind: Service
    name: cjoc
---
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: ${CONTROLLER_NAME}-health-check-policy
  namespace: ${NAMESPACE}
spec:
  default:
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: HTTP
      httpHealthCheck:
        requestPath: /${CONTROLLER_NAME}/health/
    logConfig:
      enabled: true
  targetRef:
    group: ""
    kind: Service
    name: ${CONTROLLER_NAME}
---
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: cloudbees-sticky-policy
  namespace: ${NAMESPACE}
spec:
  default:
    sessionAffinity:
      type: GENERATED_COOKIE
      cookieTtlSec: 3600
    connectionDraining:
      drainingTimeoutSec: 60
  targetRef:
    group: ""
    kind: Service
    name: ${CONTROLLER_NAME}
EOF

# --- Helm Deployment ---
log "Updating Helm repositories..."
helm repo add cloudbees https://charts.cloudbees.com/public/cloudbees || true
helm repo update

log "Deploying CloudBees CI via Helm..."
helm upgrade --install cloudbees-core-gwapi cloudbees/cloudbees-core \
  --namespace "${NAMESPACE}" \
  --set Gateway.Enabled=true \
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
