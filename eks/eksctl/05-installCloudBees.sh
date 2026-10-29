#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 05-inatallCloudBees.sh — Install CloudBees CI on EKS via Helm.
# Teardown: 05-deleteCloudBees.sh
#
# The base install is always applied. Optional parts are switched on in .env
# (all default to false):
#   CASC_ENABLED=true              CasC bundle retriever for the operations center
#                                  (needs CASC_SCM_* and CJOC_* vars, see below)
#   S3_LOGS_ENABLED=true           Pluggable storage (build logs on S3); bucket/role
#                                  come from 07-createS3PlugableStorage-LogsBucket.sh
#   CHANNEL_PINGER_ENABLED=true    -Dhudson.slaves.ChannelPinger.pingIntervalSeconds
#                                  on the operations center and managed controllers;
#                                  CHANNEL_PINGER_INTERVAL_SECONDS (default 1200)
#   MCP_ENABLED=true               CloudBees CI MCP Router + OAuth authorization server
#                                  (McpRouter.enabled, OperationsCenter.OAuthServer.Enabled,
#                                  upstream mode AUTO). Needs the MCP Server plugin and the
#                                  OAuth Authorization/Resource Server plugins; see MCP.md.
#                                  Optional: MCP_RATE_LIMIT_ENABLED (+ _PERMITS, _WINDOW),
#                                  MCP_CONTROLLERS_CACHE_TTL
#   HELM_DEBUG=true                helm --debug
# Replaces 05a-installCloudBees-CasCBundleRetriever.sh and
# 05c-installCloudBees-PlugableStorage.sh.
# -----------------------------------------------------------------------------
set -eo pipefail

set -euo pipefail

# Load environment variables
source ./.env

# Helper logging functions
log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Optional: CasC bundle retriever (CASC_ENABLED=true) ---
CASC_ARGS=()
if [[ "${CASC_ENABLED:-false}" == "true" ]]; then
  log "Creating CasC secret and env var ConfigMap..."
  cat <<EOF | kubectl -n "${NAMESPACE_CLOUDBEES}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cjoc-secrets
type: Opaque
stringData:
  githubUser: ${CASC_SCM_USERNAME:?CASC_SCM_USERNAME is required when CASC_ENABLED=true}
  githubToken: ${CASC_SCM_PASSWORD:?CASC_SCM_PASSWORD is required when CASC_ENABLED=true}
  cjocLoginPassword: ${CJOC_ADMIN_PASSWORD:?CJOC_ADMIN_PASSWORD is required when CASC_ENABLED=true}
EOF

  # Env vars used for interpolation in the CasC bundle.
  cat <<EOF | kubectl -n "${NAMESPACE_CLOUDBEES}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cjoc-casc-envvars
data:
  ADMIN_ID: "${CJOC_ADMIN_USER}"
  ADMIN_NAME: "${CJOC_ADMIN_USER}"
  ADMIN_EMAIL: "${CJOC_ADMIN_EMAIL}"
  CJOC_VERSION: "latest"
  NAMESPACE: "${NAMESPACE_CLOUDBEES}"
  GATEWAY_NAME: "${GATEWAY_NAME}"
  GATEWAY_NAMESPACE: "${NAMESPACE_CLOUDBEES}"
  AGENT_VERSION: "latest"
  GATEWAY_DOMAIN: "${CJOC_HOST_NAME}"
  GATEWAY_PORT: "443"
  CASC_SCM_BRANCH: "${CASC_SCM_BRANCH}"
  CASC_SCM_REPO: "${CASC_SCM_REPO}"
  CONTROLLER_STORAGE_CLASS: "${CLOUDBEES_STORAGE_CLASS}"
EOF

  CASC_ARGS=(
    --set OperationsCenter.CasC.Enabled=true
    --set OperationsCenter.CasC.Retriever.Enabled=true
    --set OperationsCenter.CasC.Retriever.scmRepo="${CASC_SCM_REPO}"
    --set OperationsCenter.CasC.Retriever.scmBundlePath="${CASC_SCM_BUNDLE_PATH_CJOC}"
    --set OperationsCenter.CasC.Retriever.scmBranch="${CASC_SCM_BRANCH}"
    --set OperationsCenter.CasC.Retriever.scmPollingInterval="PT1M"
    --set OperationsCenter.CasC.Retriever.secrets.scmUsername="githubUser"
    --set OperationsCenter.CasC.Retriever.secrets.scmPassword="githubToken"
    --set OperationsCenter.ContainerEnvFrom[0].configMapRef.name="cjoc-casc-envvars"
    --set OperationsCenter.CasC.Retriever.secrets.secretName="cjoc-secrets"
    --set OperationsCenter.ExtraVolumes[0].name="cjoc-secrets"
    --set OperationsCenter.ExtraVolumes[0].secret.secretName="cjoc-secrets"
    --set OperationsCenter.ExtraVolumeMounts[0].name="cjoc-secrets"
    --set OperationsCenter.ExtraVolumeMounts[0].mountPath="/var/run/secrets/cjoc"
    --set OperationsCenter.ExtraVolumeMounts[0].readOnly=true
  )
  log "CasC bundle retriever enabled."
fi


# --- Optional: Pluggable Storage, build logs on S3 (S3_LOGS_ENABLED=true) ---
# Bucket/role come from 07-createS3PlugableStorage-LogsBucket.sh.
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

# --- Optional: MCP Router with OAuth (MCP_ENABLED=true) ---
# Chart serves the router through the Gateway at https://<CJOC_HOST_NAME>/mcp-router/mcp.
# AUTO accepts OAuth bearer tokens and existing Basic/API-token headers; move to
# OAUTH_ONLY (MCP_UPSTREAM_MODE) once every controller has the OAuth Resource Server plugin.
MCP_ARGS=()
if [[ "${MCP_ENABLED:-false}" == "true" ]]; then
  MCP_ARGS=(
    --set OperationsCenter.OAuthServer.Enabled=true
    --set McpRouter.enabled=true
    --set McpRouter.upstreamMode="${MCP_UPSTREAM_MODE:-AUTO}"
    --set McpRouter.resources.requests.cpu=500m 
    --set McpRouter.resources.requests.memory=1Gi
  )

  # Router tuning goes in as env vars via McpRouter.extraEnv. --set-string keeps
  # values such as "true" from being turned into booleans.
  MCP_ENV_INDEX=0
  add_mcp_env() {
    MCP_ARGS+=(
      --set "McpRouter.extraEnv[${MCP_ENV_INDEX}].name=$1"
      --set-string "McpRouter.extraEnv[${MCP_ENV_INDEX}].value=$2"
    )
    MCP_ENV_INDEX=$((MCP_ENV_INDEX + 1))
  }

  if [[ "${MCP_RATE_LIMIT_ENABLED:-false}" == "true" ]]; then
    add_mcp_env MCP_RATE_LIMIT_ENABLED true
    [[ -n "${MCP_RATE_LIMIT_PERMITS:-}" ]] && add_mcp_env MCP_RATE_LIMIT_PERMITS "${MCP_RATE_LIMIT_PERMITS}"
    [[ -n "${MCP_RATE_LIMIT_WINDOW:-}" ]]  && add_mcp_env MCP_RATE_LIMIT_WINDOW "${MCP_RATE_LIMIT_WINDOW}"
  fi
  [[ -n "${MCP_CONTROLLERS_CACHE_TTL:-}" ]] && add_mcp_env MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL "${MCP_CONTROLLERS_CACHE_TTL}"

  log "MCP Router enabled (upstream mode ${MCP_UPSTREAM_MODE:-AUTO})."
fi

HELM_DEBUG_ARGS=()
[[ "${HELM_DEBUG:-false}" == "true" ]] && HELM_DEBUG_ARGS=(--debug)

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
  --set Master.HighAvailabilitySupport=true \
  --set Agents.SeparateNamespace.Enabled=true \
  --set Agents.SeparateNamespace.Create=true \
  --set Persistence.StorageClass="${CLOUDBEES_STORAGE_CLASS}" \
  --set Common.image.tag='latest' \
  ${CASC_ARGS[@]+"${CASC_ARGS[@]}"} \
  ${PLUGGABLE_STORAGE_ARGS[@]+"${PLUGGABLE_STORAGE_ARGS[@]}"} \
  ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} \
  ${HELM_DEBUG_ARGS[@]+"${HELM_DEBUG_ARGS[@]}"}

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
    if [[ "${MCP_ENABLED:-false}" == "true" ]]; then
      log "MCP Router endpoint: https://${CJOC_HOST_NAME}/mcp-router/mcp"
      log "MCP requires the MCP Server and OAuth plugins on CJOC/controllers (see MCP.md)."
    fi
else
    echo ""
    error "Timed out waiting for Gateway External IP. Check 'kubectl get gateway -n ${NAMESPACE_CLOUDBEES}' and ensure a LoadBalancer IP is assigned."
fi

success "Installation completed successfully."