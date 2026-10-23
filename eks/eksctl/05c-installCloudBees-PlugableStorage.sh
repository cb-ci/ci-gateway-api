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

export NAMESPACE=$NAMESPACE_CLOUDBEES

cat <<EOF | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cjoc-secrets
type: Opaque
stringData:
  githubUser: ${CASC_SCM_USERNAME}
  githubToken: ${CASC_SCM_PASSWORD}
  cjocLoginPassword: ${CJOC_ADMIN_PASSWORD}
EOF


# Deploy env vars used for interpolation in CasC bundle.
cat << EOF | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cjoc-casc-envvars
data:
  ADMIN_ID: "${CJOC_ADMIN_USER}"
  ADMIN_NAME: "${CJOC_ADMIN_USER}"
  ADMIN_EMAIL: "${CJOC_ADMIN_EMAIL}"
  CJOC_VERSION: "latest"
  NAMESPACE: "${NAMESPACE}"
  GATEWAY_NAME: "${GATEWAY_NAME}"
  GATEWAY_NAMESPACE: "${NAMESPACE}"
  AGENT_VERSION: "latest"
  GATEWAY_DOMAIN: "${CJOC_HOST_NAME}"
  GATEWAY_PORT: "443"
  CASC_SCM_BRANCH: "${CASC_SCM_BRANCH}"
  CASC_SCM_REPO: "${CASC_SCM_REPO}"
  CONTROLLER_STORAGE_CLASS: "${CLOUDBEES_STORAGE_CLASS}"  
EOF

# --- Helm Deployment ---
log "Updating Helm repositories..."
helm repo add cloudbees https://charts.cloudbees.com/public/cloudbees || true
helm repo update

# Pluggable Storage (Pipeline build logs on S3). Bucket/role come from
# 07-createS3PlugableStorage-LogsBucket.sh. Opt in with S3_LOGS_ENABLED=true.
PLUGGABLE_STORAGE_ARGS=()
if [[ "${S3_LOGS_ENABLED:-false}" == "true" ]]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  PLUGGABLE_STORAGE_ARGS=(
    --set PluggableStorageService.enabled=true
    --set PluggableStorageService.storageBackend=AMAZON_S3
    --set PluggableStorageService.storageBucket="${S3_LOGS_BUCKET:-${CLUSTER_NAME}-cbci-logs-${AWS_ACCOUNT_ID}}"
    --set PluggableStorageService.storageObjectNamePrefix="${S3_LOGS_PREFIX-logs/builds/}"
    --set PluggableStorageService.storageOptionsS3.region="${AWS_DEFAULT_REGION:-us-east-1}"
    --set rbac.pluggableStorageServiceServiceAccountName="${S3_LOGS_SA_NAME:-pluggable-storage-service}"
  )
  log "Pluggable storage enabled (S3)."
fi

log "Deploying CloudBees CI via Helm..."
helm upgrade --install cloudbees-core-envoy cloudbees/cloudbees-core \
  --namespace "${NAMESPACE}" \
  --set Gateway.Enabled=true \
  --set Gateway.Name="${GATEWAY_NAME}" \
  --set Gateway.SectionName=https \
  --set Gateway.Namespace="${NAMESPACE}" \
  --set OperationsCenter.HostName="${CJOC_HOST_NAME}" \
  --set OperationsCenter.Protocol=https \
  --set OperationsCenter.NodeSelector.workload=controller \
  --set-json 'OperationsCenter.Tolerations=[{"key":"workload","operator":"Equal","value":"controller","effect":"NoSchedule"}]' \
  --set Master.HighAvailabilitySupport=true \
  --set Agents.SeparateNamespace.Enabled=true \
  --set Agents.SeparateNamespace.Create=true \
  --set Persistence.StorageClass="${CLOUDBEES_STORAGE_CLASS}" \
  --set Common.image.tag='latest' \
  --set Master.HighAvailabilitySupport=true \
  --set OperationsCenter.CasC.Enabled=true \
  --set OperationsCenter.CasC.Retriever.Enabled=true \
  --set OperationsCenter.CasC.Retriever.scmRepo="${CASC_SCM_REPO}" \
  --set OperationsCenter.CasC.Retriever.scmBundlePath="${CASC_SCM_BUNDLE_PATH_CJOC}" \
  --set OperationsCenter.CasC.Retriever.scmBranch="${CASC_SCM_BRANCH}" \
  --set OperationsCenter.CasC.Retriever.scmPollingInterval="PT1M" \
  --set OperationsCenter.CasC.Retriever.secrets.scmUsername="githubUser" \
  --set OperationsCenter.CasC.Retriever.secrets.scmPassword="githubToken" \
  --set OperationsCenter.ContainerEnvFrom[0].configMapRef.name="cjoc-casc-envvars" \
  --set OperationsCenter.CasC.Retriever.secrets.secretName="cjoc-secrets" \
  --set OperationsCenter.ExtraVolumes[0].name="cjoc-secrets" \
  --set OperationsCenter.ExtraVolumes[0].secret.secretName="cjoc-secrets" \
  --set OperationsCenter.ExtraVolumeMounts[0].name="cjoc-secrets" \
  --set OperationsCenter.ExtraVolumeMounts[0].mountPath="/var/run/secrets/cjoc" \
  --set OperationsCenter.ExtraVolumeMounts[0].readOnly=true \
    ${PLUGGABLE_STORAGE_ARGS[@]+"${PLUGGABLE_STORAGE_ARGS[@]}"} \
  --debug

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